import Foundation
import SwiftUI
import UIKit
import GotItDomain
import GotItPersistence
#if canImport(LiteRTLM)
@preconcurrency import LiteRTLM
#endif

/// The assistant's model: Google's Gemma 4 E2B (instruction-tuned, Apache 2.0) in LiteRT-LM
/// format, downloaded once on request (2.6 GB) and run on the device.
enum AssistantModel {
    static let model = ModelFile(repository: "litert-community/gemma-4-E2B-it-litert-lm",
                                 revision: "2d74ac41a33d7da82f39f7d5720a04c68514a103",
                                 fileName: "gemma-4-E2B-it.litertlm", byteCount: 2_588_147_712,
                                 sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c")
    /// Context window: instructions + note (or sources) + answer.
    static let contextTokens = 4096
    static let answerTokens = 700
}

/// Writes text from a prompt, a piece at a time.
protocol TextGenerator: Sendable {
    func generate(system: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
    /// Frees the model's memory; the next `generate` loads it again.
    func close() async
    /// Where it runs once loaded ("GPU", "CPU"), nil before.
    func backend() async -> String?
}

#if canImport(LiteRTLM)
/// Gemma through LiteRT-LM. Tries the GPU first (Google measured 56 tokens/s on an iPhone 17 Pro,
/// against 25 on the CPU); falls back to the CPU when the GPU fails to load, or when the app was
/// closed by the system while using it last time (most likely for lack of memory).
actor LiteRTGenerator: TextGenerator {
    private let path: String
    private let allowGPU: @Sendable () -> Bool
    private let cacheDirectory: URL?
    private let retry: Bool
    private var engine: Engine?
    private var running: String?
    /// Times the model was loaded again after a failure (for the diagnostics).
    private(set) var reloads = 0

    /// Set while the GPU is in use; still set at launch means the app died using it.
    static let gpuInUseKey = "assistantGPUInUse"
    static let gpuFailedKey = "assistantGPUFailed"

    init(path: String, allowGPU: @escaping @Sendable () -> Bool, cacheDirectory: URL?, retry: Bool = true) {
        self.path = path; self.allowGPU = allowGPU; self.cacheDirectory = cacheDirectory; self.retry = retry
    }

    func backend() -> String? { running }

    nonisolated func generate(system: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(system: system, prompt: prompt, maxTokens: maxTokens, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(system: String, prompt: String, maxTokens: Int, into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        var attempt = 0
        while true {
            var wrote = false
            do {
                let engine = try await ready()
                let config = try ConversationConfig(systemMessage: Message(system, role: .system),
                                                    samplerConfig: SamplerConfig(topK: 64, topP: 0.95, temperature: 0.3),
                                                    thinkingConfig: ThinkingConfig(enableThinking: false))
                let conversation = try await engine.createConversation(with: config)
                for try await chunk in conversation.sendMessageStream(Message(prompt), maxOutputTokens: maxTokens) {
                    if Task.isCancelled { try? conversation.cancel(); break }
                    wrote = true
                    continuation.yield(chunk.toString)
                }
                continuation.finish()
                return
            } catch {
                // A failure before any word: load the model afresh once and try again.
                guard retry, attempt == 0, !wrote, !Task.isCancelled else { continuation.finish(throwing: error); return }
                attempt += 1
                reloads += 1
                close()
            }
        }
    }

    private func config(_ backend: Backend) throws -> EngineConfig {
        try EngineConfig(modelPath: path, backend: backend, maxNumTokens: AssistantModel.contextTokens, cacheDir: cacheDirectory?.path)
    }

    private func ready() async throws -> Engine {
        if let engine { return engine }
        if let cacheDirectory { try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true) }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.gpuInUseKey) { defaults.set(true, forKey: Self.gpuFailedKey) }
        if allowGPU() && !defaults.bool(forKey: Self.gpuFailedKey) {
            defaults.set(true, forKey: Self.gpuInUseKey)
            let gpu = try Engine(engineConfig: config(.gpu))
            do {
                try await gpu.initialize()
                engine = gpu; running = "GPU"
                return gpu
            } catch {
                defaults.set(false, forKey: Self.gpuInUseKey)
                defaults.set(true, forKey: Self.gpuFailedKey)
            }
        }
        let cpu = try Engine(engineConfig: config(.cpu()))
        try await cpu.initialize()
        engine = cpu; running = "CPU"
        return cpu
    }

    func close() {
        engine = nil
        running = nil
        UserDefaults.standard.set(false, forKey: Self.gpuInUseKey)
    }
}
#endif

/// A message of the conversation with the assistant (kept while the app is open).
struct AssistantMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// What it is doing before the first words ("Procurando nas notas…").
    var status: String?
    var failure: String?
    /// Passages the answer was written from, numbered as in the answer.
    var sources: [AssistantPrompts.Source] = []
    var noteWasCut = false
    /// The note a summary or questions are about (the answer can be inserted there).
    var documentID: UUID?

    /// Sources the answer cites, in the order cited (all of them when it cites none).
    var cited: [(number: Int, source: AssistantPrompts.Source)] {
        let numbers = AssistantPrompts.citations(in: text, count: sources.count)
        return (numbers.isEmpty ? Array(sources.indices.map { $0 + 1 }) : numbers).map { ($0, sources[$0 - 1]) }
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.status == rhs.status && lhs.failure == rhs.failure && lhs.sources == rhs.sources
    }
}

/// The assistant: the model download, and the conversation (summaries and questions of the open
/// note, questions answered from the notes).
@Observable @MainActor
final class Assistant {
    enum Install: Equatable { case absent, downloading(Double), checking, installed, failed(String) }
    enum Action: String, CaseIterable, Identifiable {
        case summary, questions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .summary: "Resumir esta nota"
            case .questions: "Perguntas para revisar"
            }
        }
        var symbol: String { self == .summary ? "text.badge.star" : "questionmark.bubble" }
    }

    private(set) var install: Install = .absent
    private(set) var messages: [AssistantMessage] = []
    private(set) var isWorking = false
    /// Notes chosen with "+" to look in (empty: all notes).
    var scope: Set<UUID> = []
    private(set) var backend: String?
    let isAvailable: Bool
    nonisolated static let gpuKey = "assistantUseGPU"
    /// Off by default: the processor gives the same text everywhere; on the GPU LiteRT-LM 0.19.1
    /// has an open report of Gemma 4 corrupting digits on iOS (issue 2814).
    var useGPU: Bool {
        get { _ = gpuVersion; return UserDefaults.standard.object(forKey: Self.gpuKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.gpuKey)
            if newValue { UserDefaults.standard.set(false, forKey: LiteRTGeneratorKeys.gpuFailed) }
            gpuVersion += 1
            let current = generator; generator = nil; backend = nil
            Task { await current?.close() }
        }
    }
    private var gpuVersion = 0
    /// The GPU could not be used (failed to load, or the app was closed while using it).
    var gpuFailed: Bool { _ = gpuVersion; return UserDefaults.standard.bool(forKey: LiteRTGeneratorKeys.gpuFailed) }

    private let modelFile: ModelFile
    private let installed: () -> Bool
    private let makeGenerator: () -> (any TextGenerator)?
    private var generator: (any TextGenerator)?
    private var download: Task<Void, Never>?
    private var work: Task<Void, Never>?

    init(modelFile: ModelFile = AssistantModel.model, installed: (() -> Bool)? = nil,
         makeGenerator: (() -> (any TextGenerator)?)? = nil) {
        self.modelFile = modelFile
        self.installed = installed ?? { modelFile.isInstalled }
        self.makeGenerator = makeGenerator ?? { Assistant.liteRT(path: modelFile.location.path) }
        isAvailable = self.makeGenerator() != nil
        install = self.installed() ? .installed : .absent
    }

    nonisolated static func liteRT(path: String,
                                   allowGPU: @escaping @Sendable () -> Bool = { UserDefaults.standard.object(forKey: Assistant.gpuKey) as? Bool ?? false },
                                   cacheDirectory: URL? = ModelFile.cacheDirectory, retry: Bool = true) -> (any TextGenerator)? {
        #if canImport(LiteRTLM)
        LiteRTGenerator(path: path, allowGPU: allowGPU, cacheDirectory: cacheDirectory, retry: retry)
        #else
        nil
        #endif
    }

    var sizeText: String { String(format: "%.1f GB", Double(modelFile.byteCount) / 1_000_000_000).replacingOccurrences(of: ".", with: ",") }
    var canResume: Bool { modelFile.canResume }
    var last: AssistantMessage? { messages.last }

    // MARK: Model

    func startDownload() {
        guard download == nil else { return }
        install = .downloading(0)
        // The screen stays on: iOS pauses downloads of apps that go to the background.
        UIApplication.shared.isIdleTimerDisabled = true
        let owner = self, file = modelFile
        download = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await file.download { fraction in Task { @MainActor in owner.downloaded(fraction) } }
                owner.download = nil
                owner.install = .installed
            } catch {
                owner.download = nil
                owner.install = error is CancellationError || (error as? URLError)?.code == .cancelled ? .absent
                    : .failed("Não foi possível baixar o modelo. \(error.localizedDescription)")
            }
        }
    }

    private func downloaded(_ fraction: Double) {
        guard case .downloading = install else { return }
        install = fraction >= 1 ? .checking : .downloading(fraction)
    }

    func cancelDownload() { download?.cancel() }

    func removeModel() async {
        cancel()
        download?.cancel(); download = nil
        await generator?.close(); generator = nil
        modelFile.remove()
        try? FileManager.default.removeItem(at: ModelFile.cacheDirectory)
        install = .absent
        backend = nil
    }

    /// The app left the front: the model's memory is given back (an answer being written stops).
    func setActive(_ active: Bool) {
        guard !active else { return }
        cancel()
        let current = generator; generator = nil; backend = nil
        Task { await current?.close() }
    }

    // MARK: The conversation

    /// Summary or review questions of `document`.
    func run(_ action: Action, on document: CanvasDocument) {
        guard !isWorking else { return }
        messages.append(AssistantMessage(role: .user, text: action.title))
        let note = AssistantPrompts.noteText(document)
        guard !note.text.isEmpty else {
            messages.append(AssistantMessage(role: .assistant, text: "", failure: "Esta nota ainda não tem texto para o assistente ler."))
            return
        }
        let prompt = action == .questions
            ? AssistantPrompts.studyQuestions(title: document.title, text: note.text, truncated: note.truncated)
            : AssistantPrompts.summary(title: document.title, text: note.text, truncated: note.truncated)
        var answer = AssistantMessage(role: .assistant, text: "")
        answer.noteWasCut = note.truncated
        answer.documentID = document.id
        start(answer) { (prompt, []) }
    }

    /// A question answered from passages of the notes, found by `find` (in the chosen notes, or
    /// in all of them by meaning).
    func ask(_ question: String, find: @escaping @MainActor () async -> [AssistantPrompts.Source]) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, !text.isEmpty else { return }
        messages.append(AssistantMessage(role: .user, text: text))
        start(AssistantMessage(role: .assistant, text: "", status: "Procurando nas notas…")) {
            let sources = await find()
            return sources.isEmpty ? nil : (AssistantPrompts.question(text, sources: sources), sources)
        }
    }

    func cancel() {
        work?.cancel(); work = nil
        guard isWorking else { return }
        isWorking = false
        update(messages.last?.id) { message in
            message.status = nil
            if message.text.isEmpty && message.failure == nil { message.failure = "Interrompido." }
        }
    }

    /// Starts a new conversation.
    func clear() { cancel(); messages = [] }

    private func update(_ id: UUID?, _ change: (inout AssistantMessage) -> Void) {
        guard let id, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// Adds `answer` and writes it from the prompt `prepare` gives (nil: nothing found).
    private func start(_ answer: AssistantMessage,
                       prepare: @escaping @MainActor () async -> (prompt: String, sources: [AssistantPrompts.Source])?) {
        messages.append(answer)
        let id = answer.id
        guard install == .installed, let generator = generator ?? makeGenerator() else {
            update(id) { $0.status = nil; $0.failure = "O modelo do assistente não está no aparelho. Baixe-o em Ajustes › Assistente." }
            return
        }
        self.generator = generator
        isWorking = true
        work = Task { [weak self] in
            guard let prepared = await prepare() else {
                guard let self, !Task.isCancelled else { return }
                self.isWorking = false
                self.update(id) {
                    $0.status = nil
                    $0.failure = "Não encontrei trechos das notas sobre isso. Ligue a busca por significado em Ajustes, ou toque em + e escolha as notas onde procurar."
                }
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.update(id) { $0.sources = prepared.sources; $0.status = "Preparando o modelo…" }
            do {
                for try await piece in generator.generate(system: AssistantPrompts.system, prompt: prepared.prompt, maxTokens: AssistantModel.answerTokens) {
                    guard !Task.isCancelled else { return }
                    if self.messages.last?.status != nil { self.backend = await generator.backend() }
                    self.update(id) { $0.status = nil; $0.text += piece }
                }
                guard !Task.isCancelled else { return }
                self.isWorking = false
                self.update(id) {
                    $0.status = nil
                    $0.text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if $0.text.isEmpty { $0.failure = "O modelo não escreveu nada. Tente de novo." }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isWorking = false
                self.update(id) { $0.status = nil; $0.failure = "O assistente parou: \(error.localizedDescription)" }
            }
        }
    }
}

/// UserDefaults keys shared with the LiteRT generator (which exists only where LiteRT-LM does).
enum LiteRTGeneratorKeys {
    static let gpuFailed = "assistantGPUFailed"
}
