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
    private var engine: Engine?
    private var running: String?

    /// Set while the GPU is in use; still set at launch means the app died using it.
    static let gpuInUseKey = "assistantGPUInUse"
    static let gpuFailedKey = "assistantGPUFailed"

    init(path: String, allowGPU: @escaping @Sendable () -> Bool) { self.path = path; self.allowGPU = allowGPU }

    func backend() -> String? { running }

    nonisolated func generate(system: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(system: system, prompt: prompt, maxTokens: maxTokens, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(system: String, prompt: String, maxTokens: Int, into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            let engine = try await ready()
            let config = try ConversationConfig(systemMessage: Message(system, role: .system),
                                            samplerConfig: SamplerConfig(topK: 64, topP: 0.95, temperature: 0.3),
                                            thinkingConfig: ThinkingConfig(enableThinking: false))
            let conversation = try await engine.createConversation(with: config)
            for try await chunk in conversation.sendMessageStream(Message(prompt), maxOutputTokens: maxTokens) {
                if Task.isCancelled { try? conversation.cancel(); break }
                continuation.yield(chunk.toString)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func ready() async throws -> Engine {
        if let engine { return engine }
        try FileManager.default.createDirectory(at: ModelFile.cacheDirectory, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.gpuInUseKey) { defaults.set(true, forKey: Self.gpuFailedKey) }
        if allowGPU() && !defaults.bool(forKey: Self.gpuFailedKey) {
            defaults.set(true, forKey: Self.gpuInUseKey)
            let gpu = try Engine(engineConfig: EngineConfig(modelPath: path, backend: .gpu, maxNumTokens: AssistantModel.contextTokens,
                                                        cacheDir: ModelFile.cacheDirectory.path))
            do {
                try await gpu.initialize()
                engine = gpu; running = "GPU"
                return gpu
            } catch {
                defaults.set(false, forKey: Self.gpuInUseKey)
                defaults.set(true, forKey: Self.gpuFailedKey)
            }
        }
        let cpu = try Engine(engineConfig: EngineConfig(modelPath: path, backend: .cpu(), maxNumTokens: AssistantModel.contextTokens,
                                                    cacheDir: ModelFile.cacheDirectory.path))
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

/// The assistant: the model download, and what it is asked about the open note or the notes.
@Observable @MainActor
final class Assistant {
    enum Install: Equatable { case absent, downloading(Double), checking, installed, failed(String) }
    enum Action: String, CaseIterable, Identifiable {
        case summary, questions, ask
        var id: String { rawValue }
        var title: String {
            switch self {
            case .summary: "Resumir esta nota"
            case .questions: "Perguntas para revisar"
            case .ask: "Perguntar às notas"
            }
        }
        var symbol: String {
            switch self { case .summary: "text.badge.star"; case .questions: "questionmark.bubble"; case .ask: "text.magnifyingglass" }
        }
    }

    private(set) var install: Install = .absent
    /// The answer being written (or written).
    private(set) var output = ""
    private(set) var isWorking = false
    /// Loading the model, before the first words (a few seconds the first time).
    private(set) var isLoading = false
    private(set) var failure: String?
    /// Passages the last question was answered from, numbered as in the answer.
    private(set) var sources: [AssistantPrompts.Source] = []
    private(set) var noteWasCut = false
    private(set) var backend: String?
    let isAvailable: Bool
    nonisolated static let gpuKey = "assistantUseGPU"
    var useGPU: Bool {
        get { UserDefaults.standard.object(forKey: Self.gpuKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.gpuKey)
            if newValue { UserDefaults.standard.set(false, forKey: LiteRTGeneratorKeys.gpuFailed) }
            let current = generator; generator = nil
            Task { await current?.close() }
        }
    }
    /// The GPU could not be used (failed to load, or the app was closed while using it).
    var gpuFailed: Bool { UserDefaults.standard.bool(forKey: LiteRTGeneratorKeys.gpuFailed) }

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
                                   allowGPU: @escaping @Sendable () -> Bool = { UserDefaults.standard.object(forKey: Assistant.gpuKey) as? Bool ?? true }) -> (any TextGenerator)? {
        #if canImport(LiteRTLM)
        LiteRTGenerator(path: path, allowGPU: allowGPU)
        #else
        nil
        #endif
    }

    var sizeText: String { String(format: "%.1f GB", Double(modelFile.byteCount) / 1_000_000_000).replacingOccurrences(of: ".", with: ",") }
    var canResume: Bool { modelFile.canResume }

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

    // MARK: Asking

    /// Summary or review questions of `document`.
    func run(_ action: Action, on document: CanvasDocument) {
        let note = AssistantPrompts.noteText(document)
        guard !note.text.isEmpty else { failure = "Esta nota ainda não tem texto para o assistente ler."; return }
        noteWasCut = note.truncated
        let prompt = action == .questions
            ? AssistantPrompts.studyQuestions(title: document.title, text: note.text, truncated: note.truncated)
            : AssistantPrompts.summary(title: document.title, text: note.text, truncated: note.truncated)
        start(prompt: prompt, sources: [])
    }

    /// A question answered from passages of the notes (found by the search by meaning).
    func ask(_ question: String, sources: [AssistantPrompts.Source]) {
        noteWasCut = false
        guard !sources.isEmpty else {
            reset()
            failure = "Não encontrei trechos das suas notas sobre isso."
            return
        }
        start(prompt: AssistantPrompts.question(question, sources: sources), sources: sources)
    }

    func cancel() { work?.cancel(); work = nil; isWorking = false; isLoading = false }

    func reset() { cancel(); output = ""; failure = nil; sources = []; noteWasCut = false }

    private func start(prompt: String, sources: [AssistantPrompts.Source]) {
        reset()
        guard install == .installed, let generator = generator ?? makeGenerator() else {
            failure = "O modelo do assistente não está no aparelho."; return
        }
        self.generator = generator
        self.sources = sources
        isWorking = true
        isLoading = true
        work = Task { [weak self] in
            do {
                for try await piece in generator.generate(system: AssistantPrompts.system, prompt: prompt, maxTokens: AssistantModel.answerTokens) {
                    guard let self, !Task.isCancelled else { return }
                    if self.isLoading { self.isLoading = false; self.backend = await generator.backend() }
                    self.output += piece
                }
                guard let self, !Task.isCancelled else { return }
                self.isWorking = false; self.isLoading = false
                self.output = self.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.output.isEmpty { self.failure = "O modelo não escreveu nada. Tente de novo." }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isWorking = false; self.isLoading = false
                self.failure = "O assistente parou: \(error.localizedDescription)"
            }
        }
    }

    /// Sources the answer cites, in the order cited (all of them when it cites none).
    var citedSources: [(number: Int, source: AssistantPrompts.Source)] {
        let cited = AssistantPrompts.citations(in: output, count: sources.count)
        let numbers = cited.isEmpty ? Array(1...max(sources.count, 1)).filter { $0 <= sources.count } : cited
        return numbers.map { ($0, sources[$0 - 1]) }
    }
}

/// UserDefaults keys shared with the LiteRT generator (which exists only where LiteRT-LM does).
enum LiteRTGeneratorKeys {
    static let gpuFailed = "assistantGPUFailed"
}
