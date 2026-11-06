import Foundation
import GotItDomain

public struct HistoryState: Equatable, Sendable {
    public let canUndo: Bool
    public let canRedo: Bool
    public let retainedEntries: Int
}

/// Called only inside the owning SQLiteStore transaction.
enum HistoryStore {
    static func cursor(_ db: SQLiteConnection, id: UUID) throws -> Int64 {
        guard let cursor = try db.execute("SELECT history_cursor FROM documents WHERE id = ?", [.text(id.uuidString)]).first?.first?.int else {
            throw DocumentError.missingDocument(id)
        }
        return cursor
    }

    static func record(_ db: SQLiteConnection, before: CanvasDocument, after: CanvasDocument,
                       commands: [DocumentCommand], limit: Int) throws {
        let id = SQLValue.text(before.id.uuidString)
        let position = try cursor(db, id: before.id)
        guard position < Int64.max else { throw DocumentError.invalid("History sequence exhausted") }
        let sequence = position + 1
        try db.execute("DELETE FROM history WHERE document_id = ? AND sequence > ?", [id, .integer(position)])
        let encoder = JSONEncoder()
        try db.execute("INSERT INTO history VALUES (?, ?, ?, ?, ?)", [id, .integer(sequence),
            .blob(try encoder.encode(commands)), .blob(try encoder.encode(before)), .blob(try encoder.encode(after))])
        try db.execute("UPDATE documents SET history_cursor = ? WHERE id = ?", [.integer(sequence), id])
        try db.execute("DELETE FROM history WHERE document_id = ? AND sequence <= ?", [id, .integer(sequence - Int64(limit))])
    }

    static func restore(_ db: SQLiteConnection, id: UUID, undo: Bool) throws -> CanvasDocument {
        let position = try cursor(db, id: id)
        let sql = undo
            ? "SELECT sequence, before_snapshot FROM history WHERE document_id = ? AND sequence = ?"
            : "SELECT sequence, after_snapshot FROM history WHERE document_id = ? AND sequence = ?"
        if !undo && position == Int64.max { throw DocumentError.nothingToRedo }
        let target = undo ? position : position + 1
        guard let row = try db.execute(sql, [.text(id.uuidString), .integer(target)]).first else {
            throw undo ? DocumentError.nothingToUndo : DocumentError.nothingToRedo
        }
        guard let sequence = row[0].int, let data = row[1].data else { throw PersistenceError.corruptData("Invalid history row") }
        let snapshot = try JSONDecoder().decode(CanvasDocument.self, from: data)
        guard snapshot.id == id else { throw PersistenceError.corruptData("Snapshot document ID mismatch") }
        try db.execute("UPDATE documents SET history_cursor = ? WHERE id = ?",
                       [.integer(undo ? sequence - 1 : sequence), .text(id.uuidString)])
        return snapshot
    }

    static func state(_ db: SQLiteConnection, id: UUID) throws -> HistoryState {
        let position = try cursor(db, id: id)
        let rows = try db.execute("SELECT sequence FROM history WHERE document_id = ?", [.text(id.uuidString)])
        let sequences = rows.compactMap { $0.first?.int }
        return HistoryState(canUndo: sequences.contains(position),
                            canRedo: position < Int64.max && sequences.contains(position + 1), retainedEntries: sequences.count)
    }
}
