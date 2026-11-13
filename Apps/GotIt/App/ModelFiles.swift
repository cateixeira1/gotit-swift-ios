import Foundation
import CryptoKit

/// A model file the app downloads on request (EmbeddingGemma for the search by meaning, Gemma for
/// the assistant): a fixed revision of a Hugging Face repository, checked against its published
/// size and SHA-256 before use. Kept in Application Support/Models, outside the iCloud backup
/// (it can be downloaded again at any time).
struct ModelFile: Sendable {
    let repository: String
    let revision: String
    let fileName: String
    let byteCount: Int64
    let sha256: String

    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")! }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
    }
    /// Where LiteRT-LM keeps what it prepares from a model on first load (rebuilt if removed).
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiteRTLM", isDirectory: true)
    }
    var location: URL { Self.directory.appendingPathComponent(fileName) }
    private var partial: URL { Self.directory.appendingPathComponent(fileName + ".part") }
    /// What URLSession needs to continue an interrupted download where it stopped.
    private var resumeFile: URL { Self.directory.appendingPathComponent(fileName + ".resume") }

    var isInstalled: Bool { Self.size(of: location) == byteCount }
    /// An interrupted download that can continue.
    var canResume: Bool { FileManager.default.fileExists(atPath: resumeFile.path) }
    var megabytes: Int { Int((Double(byteCount) / 1_000_000).rounded()) }

    enum Problem: LocalizedError {
        case http(Int), damaged, space(needed: Int64, free: Int64)
        var errorDescription: String? {
            switch self {
            case .http(let code): "O servidor do modelo respondeu com o código \(code)."
            case .damaged: "O arquivo baixado não confere com o publicado (tamanho ou SHA-256) e foi descartado."
            case .space(let needed, let free):
                "Falta espaço: o modelo precisa de \(needed / 1_000_000) MB livres e há \(free / 1_000_000) MB."
            }
        }
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Downloads (or continues), checks and installs the file. `progress` gets 0…1 while downloading.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // The download is written to a temporary file and then moved, so twice the size at worst.
        let values = try? Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < byteCount * 2 + 200_000_000 {
            throw Problem.space(needed: byteCount * 2 + 200_000_000, free: free)
        }
        try? FileManager.default.removeItem(at: partial)
        let resumeData = try? Data(contentsOf: resumeFile)
        try? FileManager.default.removeItem(at: resumeFile)
        do {
            try await transfer(resumeData: resumeData, progress: progress)
        } catch where resumeData != nil && !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
            // A stale resume (the signed address expired, the file changed): start over once.
            try await transfer(resumeData: nil, progress: progress)
        }
        try Task.checkCancellation()
        let target = partial
        let valid = try await Task.detached(priority: .userInitiated) { [self] in try verify(target) }.value
        guard valid else { try? FileManager.default.removeItem(at: partial); throw Problem.damaged }
        try? FileManager.default.removeItem(at: location)
        try FileManager.default.moveItem(at: partial, to: location)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var installed = location; try installed.setResourceValues(excluded)
    }

    private func transfer(resumeData: Data?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = DownloadBox(resumeFile: resumeFile)
        let partial = partial, resumeFile = resumeFile
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let finished: @Sendable (URL?, URLResponse?, Error?) -> Void = { temporary, response, error in
                    if let error {
                        // Keep what is needed to continue later (network lost, app closed, cancel).
                        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: resumeFile) }
                        continuation.resume(throwing: error); return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let temporary, status == 200 || status == 206 else { continuation.resume(throwing: Problem.http(status)); return }
                    // The temporary file is gone once this closure returns.
                    do { try FileManager.default.moveItem(at: temporary, to: partial); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
                let task = resumeData.map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: finished) }
                    ?? URLSession.shared.downloadTask(with: url, completionHandler: finished)
                box.start(task, progress: progress)
            }
        } onCancel: { box.cancel() }
    }

    /// Size and SHA-256 of `url` equal the published ones.
    func verify(_ url: URL) throws -> Bool {
        guard Self.size(of: url) == byteCount else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

    func remove() {
        for url in [location, partial, resumeFile] { try? FileManager.default.removeItem(at: url) }
    }
}

/// The download task, its progress observation, and a cancel that may come before it starts.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private let resumeFile: URL
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    init(resumeFile: URL) { self.resumeFile = resumeFile }

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
        if cancelled { task.cancel() } else { task.resume() }
    }

    /// Stops, keeping what was downloaded so "Continuar" picks up from there.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        let resumeFile = resumeFile
        task?.cancel(byProducingResumeData: { data in if let data { try? data.write(to: resumeFile) } })
    }
}
