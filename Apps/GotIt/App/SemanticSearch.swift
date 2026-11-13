import Foundation
import SwiftUI
import CryptoKit
import GotItDomain
import GotItPersistence
#if canImport(LiteRTLM)
@preconcurrency import LiteRTLM
#endif

/// The model that turns text into vectors for the search by meaning: Google's EmbeddingGemma 2
/// (text only, 270M parameters, Apache 2.0) in LiteRT-LM format. Downloaded once, on request, from
/// a fixed revision on Hugging Face and checked against its published size and SHA-256 before
/// use; after that everything runs on the device, without internet.
enum EmbeddingModel {
    static let fileName = "embeddinggemma-2-text-270m.litertlm"
    static let revision = "9be6e8b90982095dc05c2bd162e4b954ee4dbac7"
    static let url = URL(string: "https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/\(revision)/\(fileName)")!
    static let byteCount: Int64 = 164_626_432
    static let sha256 = "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb"
    /// Matryoshka size kept: 256 of the 768 dimensions (a quarter of the space, little loss).
    static let dimensions = 256
    /// Stored with every vector: another file or size means the notes are read again.
    static let identifier = "embeddinggemma-2-text-270m@9be6e8b/256"

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Models", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent(fileName) }
    static var isInstalled: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        return size == byteCount
    }

    enum Problem: LocalizedError {
        case http(Int), damaged, unavailable
        var errorDescription: String? {
            switch self {
            case .http(let code): "O servidor do modelo respondeu com o código \(code)."
            case .damaged: "O arquivo baixado não confere com o publicado (tamanho ou SHA-256) e foi descartado."
            case .unavailable: "A busca por significado não está disponível neste aparelho."
            }
        }
    }

    /// Downloads, checks and installs the model. `progress` gets 0…1 while downloading.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(fileName + ".part")
        try? FileManager.default.removeItem(at: partial)
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let temporary, status == 200 else { continuation.resume(throwing: Problem.http(status)); return }
                    // The temporary file is gone once this closure returns.
                    do { try FileManager.default.moveItem(at: temporary, to: partial); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
                box.start(task, progress: progress)
            }
        } onCancel: { box.cancel() }
        try Task.checkCancellation()
        let valid = try await Task.detached(priority: .userInitiated) { try verify(partial) }.value
        guard valid else { try? FileManager.default.removeItem(at: partial); throw Problem.damaged }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: partial, to: file)
        // Downloadable again at any time: not worth 165 MB of the person's iCloud backup.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var installed = file; try installed.setResourceValues(values)
    }

    /// Size and SHA-256 of `url` equal the published ones.
    static func verify(_ url: URL) throws -> Bool {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard size == byteCount else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName + ".part"))
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Where LiteRT-LM keeps what it prepares from the model on first load (rebuilt if removed).
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiteRTLM", isDirectory: true)
    }
}

/// The download task, its progress observation, and a cancel that may come before it starts.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
        if cancelled { task.cancel() } else { task.resume() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// Turns a text (already in the model's prompt form) into a vector of length 1.
protocol TextEmbedder: Sendable {
    func embed(_ text: String) async throws -> [Float]
    /// Frees the model's memory; the next `embed` loads it again.
    func close() async
}

#if canImport(LiteRTLM)
/// EmbeddingGemma through LiteRT-LM, on the CPU (works the same on every iPhone and iPad, and in
/// the Simulator). Loaded on first use.
actor LiteRTEmbedder: TextEmbedder {
    private let path: String
    private var engine: EmbeddingEngine?

    init(path: String) { self.path = path }

    func embed(_ text: String) async throws -> [Float] {
        let engine = try await ready()
        do { return try await vector(engine, text) }
        catch {
            // A passage too long for the model's input is read by its first part.
            guard text.count > 400 else { throw error }
            return try await vector(engine, String(text.prefix(400)))
        }
    }

    private func vector(_ engine: EmbeddingEngine, _ text: String) async throws -> [Float] {
        let options = EmbeddingOptions(normalize: true, outputSize: EmbeddingModel.dimensions)
        return try await engine.computeEmbedding(contents: [.text(text)], options: options).embedding
    }

    private func ready() async throws -> EmbeddingEngine {
        if let engine { return engine }
        try FileManager.default.createDirectory(at: EmbeddingModel.cacheDirectory, withIntermediateDirectories: true)
        let created = EmbeddingEngine(config: EmbeddingEngineConfig(modelPath: path, backend: .cpu(),
                                                                    cacheDir: EmbeddingModel.cacheDirectory.path, maxInputLength: 512))
        try await created.initialize()
        engine = created
        return created
    }

    func close() async {
        await engine?.close()
        engine = nil
    }
}
#endif

/// The search by meaning: whether it is on, the model download, reading the notes into vectors
/// (a few seconds after each change, while the app is open), and answering searches.
@Observable @MainActor
final class SemanticSearch {
    enum State: Equatable {
        /// Off, or on without the model (it has to be downloaded).
        case off, needsModel
        case downloading(Double), checking
        /// Reading notes: how many are up to date, out of how many.
        case indexing(Int, Int)
        case ready
        case failed(String)
    }

    private(set) var state: State = .off
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// Ready to answer (some notes may still be being read).
    var canSearch: Bool {
        switch state { case .ready, .indexing: true; default: false }
    }

    static let enabledKey = "semanticSearch"
    private let modelInstalled: () -> Bool
    private let makeEmbedder: () -> (any TextEmbedder)?
    private let model: String
    private var store: SQLiteStore?
    private var embedder: (any TextEmbedder)?
    private var download: Task<Void, Never>?
    private var indexing: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var active = true
    /// Tells a reading that was stopped from the one that replaced it.
    private var generation = 0
    /// Something changed while a reading was going on: look once more when it ends.
    private var again = false

    init(model: String = EmbeddingModel.identifier, modelInstalled: @escaping () -> Bool = { EmbeddingModel.isInstalled },
         makeEmbedder: @escaping () -> (any TextEmbedder)? = SemanticSearch.liteRT) {
        self.model = model; self.modelInstalled = modelInstalled; self.makeEmbedder = makeEmbedder
        isAvailable = makeEmbedder() != nil
    }

    nonisolated static func liteRT() -> (any TextEmbedder)? { liteRT(path: EmbeddingModel.file.path) }

    /// The LiteRT-LM embedder for a model file, where LiteRT-LM exists.
    nonisolated static func liteRT(path: String) -> (any TextEmbedder)? {
        #if canImport(LiteRTLM)
        LiteRTEmbedder(path: path)
        #else
        nil
        #endif
    }

    /// Available on this build (not on Mac Catalyst, which LiteRT-LM does not ship for).
    let isAvailable: Bool

    func attach(_ store: SQLiteStore) {
        self.store = store
        resume()
    }

    /// Turns it on: downloads the model if it is not on the device, then reads the notes.
    func enable() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        if modelInstalled() { resume() } else { startDownload() }
    }

    func startDownload() {
        guard download == nil else { return }
        state = .downloading(0)
        // Held until the download ends (this object lives as long as the app).
        let owner = self
        download = Task {
            do {
                try await EmbeddingModel.download { fraction in
                    Task { @MainActor in owner.downloaded(fraction) }
                }
                owner.download = nil
                owner.resume()
            } catch {
                owner.download = nil
                owner.state = error is CancellationError || (error as? URLError)?.code == .cancelled ? .needsModel
                    : .failed("Não foi possível baixar o modelo. \(error.localizedDescription)")
            }
        }
    }

    private func downloaded(_ fraction: Double) {
        guard case .downloading = state else { return }
        // Once the bytes are in, the check (SHA-256 of 165 MB) runs.
        state = fraction >= 1 ? .checking : .downloading(fraction)
    }

    func cancelDownload() { download?.cancel() }

    /// Turns it off. With `removingModel`, the 165 MB file and every vector are deleted too.
    func disable(removingModel: Bool) async {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        download?.cancel(); download = nil
        scheduled?.cancel(); scheduled = nil
        indexing?.cancel(); indexing = nil; generation += 1
        await embedder?.close(); embedder = nil
        if removingModel {
            EmbeddingModel.remove()
            try? await store?.clearSemantic()
        }
        state = .off
    }

    /// A note changed: read it again in a moment (edits in a row are read once).
    func changed() {
        guard isEnabled, active, modelInstalled(), store != nil else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.runIndexing()
        }
    }

    /// The app came to the front or left it. In the background nothing is read and the model's
    /// memory is given back.
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value { resume(); return }
        scheduled?.cancel(); scheduled = nil
        indexing?.cancel(); indexing = nil; generation += 1
        let current = embedder
        Task { await current?.close() }
    }

    func retry() { resume() }

    private func resume() {
        guard isEnabled else { state = .off; return }
        guard modelInstalled() else { if download == nil { state = .needsModel }; return }
        runIndexing()
    }

    private func runIndexing() {
        guard isEnabled, active, let store else { return }
        guard indexing == nil else { again = true; return }
        again = false
        guard let embedder = embedder ?? makeEmbedder() else { state = .failed(EmbeddingModel.Problem.unavailable.localizedDescription); return }
        self.embedder = embedder
        let model = model
        generation += 1
        let current = generation
        indexing = Task { [weak self] in
            do {
                var progress = try await store.semanticProgress(model: model)
                self?.state = progress.indexed == progress.total ? .ready : .indexing(progress.indexed, progress.total)
                while !Task.isCancelled {
                    let work = try await store.semanticWork(model: model, limit: 4)
                    if work.isEmpty { break }
                    for item in work {
                        var vectors: [String: [Float]] = [:]
                        for passage in item.missing {
                            try Task.checkCancellation()
                            vectors[passage.hash] = try await embedder.embed(SemanticChunks.documentPrompt(title: item.title, text: passage.text))
                        }
                        try await store.storeSemantic(item, vectors: vectors, model: model)
                    }
                    progress = try await store.semanticProgress(model: model)
                    self?.state = .indexing(progress.indexed, progress.total)
                }
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.indexing = nil
                self.state = .ready
                if self.again { self.runIndexing() }
            } catch {
                guard let self, self.generation == current else { return }
                self.indexing = nil
                if !Task.isCancelled, !(error is CancellationError) { self.state = .failed("A leitura das notas parou: \(error.localizedDescription)") }
            }
        }
    }

    /// Passages closest in meaning to `query`, best first; empty when it is off or not ready.
    func search(_ query: String) async -> [SemanticHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch, active, !text.isEmpty, let store, let embedder = embedder ?? makeEmbedder() else { return [] }
        self.embedder = embedder
        do {
            let vector = try await embedder.embed(SemanticChunks.queryPrompt(text))
            return try await store.semanticSearch(vector, model: model, limit: 40)
        } catch { return [] }
    }
}

/// Turning the search by meaning on or off, the model download, and how far reading has got.
struct SemanticSearchSettings: View {
    var search: SemanticSearch
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false

    static func shortStatus(_ search: SemanticSearch) -> String {
        switch search.state {
        case .off: "Desligada"
        case .needsModel: "Falta o modelo"
        case .downloading(let fraction): "\(Int(fraction * 100))%"
        case .checking: "Conferindo…"
        case .indexing(let done, let total): "\(done) de \(total)"
        case .ready: "Ligada"
        case .failed: "Erro"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Encontra notas pelo assunto, não só pelas palavras: buscar “contrato de aluguel” também acha uma nota sobre “locação do apartamento”.")
                    Text("Usa o modelo EmbeddingGemma 2, do Google (licença Apache 2.0), baixado uma vez (165 MB). Depois tudo roda no próprio aparelho, sem internet; nada das suas notas sai dele.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    status
                } header: { Text("Estado") }
                Section {
                    switch search.state {
                    case .off:
                        Button("Ligar busca por significado") { search.enable() }.accessibilityIdentifier("enableSemantic")
                    case .needsModel:
                        Button("Baixar modelo (165 MB)") { search.startDownload() }.accessibilityIdentifier("downloadSemantic")
                        Button("Desligar", role: .destructive) { Task { await search.disable(removingModel: false) } }
                    case .downloading, .checking:
                        Button("Cancelar download", role: .destructive) { search.cancelDownload() }
                    case .indexing, .ready, .failed:
                        if case .failed = search.state {
                            if EmbeddingModel.isInstalled { Button("Tentar de novo") { search.retry() } }
                            else { Button("Tentar baixar de novo") { search.startDownload() } }
                        }
                        Button("Desligar") { Task { await search.disable(removingModel: false) } }
                        Button("Desligar e apagar o modelo", role: .destructive) { confirmRemoval = true }
                    }
                }
            }
            .navigationTitle("Busca por significado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .confirmationDialog("Apagar o modelo?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Apagar modelo e índice", role: .destructive) { Task { await search.disable(removingModel: true) } }
            } message: {
                Text("Libera 165 MB. As notas não são afetadas; para voltar a usar, o modelo é baixado de novo.")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch search.state {
        case .off: Text("Desligada.")
        case .needsModel: Text("Ligada, mas o modelo ainda não está no aparelho.")
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Baixando o modelo… \(Int(fraction * 100))%") }
            Text("Mantenha o app aberto até terminar.").font(.footnote).foregroundStyle(.secondary)
        case .checking: ProgressView { Text("Conferindo o arquivo baixado…") }
        case .indexing(let done, let total):
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0) { Text("Lendo as notas: \(done) de \(total)") }
            Text("A busca já funciona com as notas lidas. Continua quando o app está aberto.").font(.footnote).foregroundStyle(.secondary)
        case .ready: Label("Pronta. As notas são relidas alguns segundos depois de cada mudança.", systemImage: "checkmark.circle")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}
