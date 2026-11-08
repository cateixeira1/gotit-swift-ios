import Foundation
import GotItDomain

public struct PendingEdit: Codable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let expectedRevision: Int64
    public let commands: [DocumentCommand]
    public let historyGroup: String?
    public init(id: UUID = UUID(), documentID: UUID, expectedRevision: Int64, commands: [DocumentCommand], historyGroup: String? = nil) {
        self.id = id; self.documentID = documentID; self.expectedRevision = expectedRevision
        self.commands = commands; self.historyGroup = historyGroup
    }
}

/// Host-owned write-ahead queue for edits that are on screen but not yet committed to SQLite.
///
/// Append an edit before showing it and remove it after SQLite commits it. The file is an
/// append-only log, one JSON record per line (an edit, or the ID of an edit that was committed),
/// so each keystroke writes one short line instead of rewriting the queue; it is emptied when
/// nothing is pending. Writes reach the operating system before the call returns, so an app that
/// is closed or killed keeps them; a power loss in the same instant is not covered (no fsync per
/// keystroke). A last line cut short by a crash is ignored: its edit had not been shown yet.
/// Any other malformed line stops loading and leaves the file as it is.
@MainActor public final class PendingEditJournal {
    private struct Record: Codable {
        var edit: PendingEdit?
        var done: UUID?
    }
    public let url: URL
    public private(set) var entries: [PendingEdit]

    public init(url: URL) throws {
        self.url = url
        entries = []
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        // Complete records end with a newline, so the last piece is either empty or an append that
        // was cut short by a crash; either way it holds no edit.
        lines.removeLast()
        var pending: [PendingEdit] = []
        for line in lines {
            guard !line.isEmpty else { continue }
            let record = try JSONDecoder().decode(Record.self, from: Data(line))
            if let edit = record.edit { pending.append(edit) }
            else if let done = record.done { pending.removeAll { $0.id == done } }
            else { throw DocumentError.invalid("Empty journal record") }
        }
        entries = pending
    }

    public func append(_ edit: PendingEdit) throws {
        try write(Record(edit: edit, done: nil))
        entries.append(edit)
    }

    /// The edit was committed: it no longer needs recovering.
    public func remove(_ id: UUID) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        let remaining = entries.filter { $0.id != id }
        if remaining.isEmpty {
            try Data().write(to: url, options: .atomic)      // nothing pending: start a fresh log
        } else {
            try write(Record(edit: nil, done: id))
        }
        entries = remaining
    }

    /// Kept for callers that remove in order.
    public func removeFirst(_ id: UUID) throws {
        guard entries.first?.id == id else { throw DocumentError.invalid("Journal order mismatch") }
        try remove(id)
    }

    /// Re-applies what was pending when the app last stopped, in order. Each edit carries its own
    /// operation ID, so an edit SQLite had already committed (the app stopped before removing it
    /// here) is recognized and not applied twice. Returns the documents that were touched.
    @discardableResult
    public func replay(into store: SQLiteStore) async throws -> [UUID] {
        var touched: [UUID] = []
        while let edit = entries.first {
            _ = try await store.execute(edit.commands, documentID: edit.documentID, expectedRevision: edit.expectedRevision,
                                        historyGroup: edit.historyGroup, operationID: edit.id)
            try remove(edit.id)
            try await store.acknowledgeOperation(edit.id)
            if !touched.contains(edit.documentID) { touched.append(edit.documentID) }
        }
        return touched
    }

    /// Moves the log aside (when its edits cannot be applied), so it is never lost or retried
    /// forever, and starts an empty one. Returns where the old log was kept.
    @discardableResult
    public func quarantine(now: Date = Date()) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        let kept = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-unrecovered-\(stamp).\(url.pathExtension)")
        if FileManager.default.fileExists(atPath: kept.path) { try FileManager.default.removeItem(at: kept) }
        try FileManager.default.moveItem(at: url, to: kept)
        entries = []
        return kept
    }

    private func write(_ record: Record) throws {
        var line = try JSONEncoder().encode(record)
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
