import Foundation
import GotItDomain

public struct PendingEdit: Codable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let expectedRevision: Int64
    public let commands: [DocumentCommand]
    public let historyGroup: String?
    public init(documentID: UUID, expectedRevision: Int64, commands: [DocumentCommand], historyGroup: String? = nil) {
        id = UUID(); self.documentID = documentID; self.expectedRevision = expectedRevision
        self.commands = commands; self.historyGroup = historyGroup
    }
}

/// Host-owned write-ahead queue. Persist before showing an optimistic edit and
/// remove only after SQLite commits. A malformed journal is never silently reset.
@MainActor public final class PendingEditJournal {
    private let url: URL
    public private(set) var entries: [PendingEdit]
    public init(url: URL) throws {
        self.url = url
        entries = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([PendingEdit].self, from: Data(contentsOf: url)) : []
    }
    public func append(_ edit: PendingEdit) throws {
        var next = entries; next.append(edit); try save(next)
    }
    public func removeFirst(_ id: UUID) throws {
        guard entries.first?.id == id else { throw DocumentError.invalid("Journal order mismatch") }
        try save(Array(entries.dropFirst()))
    }
    private func save(_ next: [PendingEdit]) throws {
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        entries = next
    }
}
