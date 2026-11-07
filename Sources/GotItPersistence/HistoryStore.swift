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
                       commands: [DocumentCommand], limit: Int, byteLimit: Int = Int.max, group: String?) throws {
        let id = SQLValue.text(before.id.uuidString)
        let position = try cursor(db, id: before.id)
        guard position < Int64.max else { throw DocumentError.invalid("History sequence exhausted") }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var inverse = try DocumentDelta.between(after, before)
        var forward = try DocumentDelta.between(before, after)
        let nextExists = try db.execute("SELECT sequence FROM history WHERE document_id = ? AND sequence > ?", [id, .integer(position)]).first != nil
        var sequence = position + 1
        if let group, !nextExists,
           let row = try db.execute("SELECT commands, before_snapshot, after_snapshot FROM history WHERE document_id = ? AND sequence = ?", [id, .integer(position)]).first,
           let metadata = row[0].data, (try? decoder.decode(String.self, from: metadata)) == group,
           let oldInverse = row[1].data, let oldForward = row[2].data {
            inverse.edits += try decoder.decode(DocumentDelta.self, from: oldInverse).edits
            forward.edits = try decoder.decode(DocumentDelta.self, from: oldForward).edits + forward.edits
            sequence = position
        }
        try db.execute("DELETE FROM history WHERE document_id = ? AND sequence >= ?", [id, .integer(sequence)])
        try db.execute("INSERT INTO history VALUES (?, ?, ?, ?, ?)", [id, .integer(sequence),
            .blob(try encoder.encode(group)), .blob(try encoder.encode(inverse)), .blob(try encoder.encode(forward))])
        try db.execute("UPDATE documents SET history_cursor = ? WHERE id = ?", [.integer(sequence), id])
        try db.execute("DELETE FROM history WHERE document_id = ? AND sequence <= ?", [id, .integer(sequence - Int64(limit))])
        try enforceByteBudget(db, id: id, newest: sequence, byteLimit: byteLimit)
    }

    /// Drops the oldest entries until the retained deltas fit in `byteLimit`. The newest entry is
    /// always kept, even when it alone exceeds the budget: the last edit must stay undoable.
    /// Large PencilKit snapshots therefore shorten the undo depth instead of growing the database.
    static func enforceByteBudget(_ db: SQLiteConnection, id: SQLValue, newest: Int64, byteLimit: Int) throws {
        guard byteLimit < Int.max else { return }
        let rows = try db.execute("""
            SELECT sequence, length(commands) + length(before_snapshot) + length(after_snapshot)
            FROM history WHERE document_id = ? ORDER BY sequence DESC
            """, [id])
        var total = 0
        for row in rows {
            guard let sequence = row[0].int, let size = row[1].int else { continue }
            total += Int(size)
            if total > byteLimit && sequence < newest {
                try db.execute("DELETE FROM history WHERE document_id = ? AND sequence <= ?", [id, .integer(sequence)])
                return
            }
        }
    }

    static func restore(_ db: SQLiteConnection, document: CanvasDocument, undo: Bool) throws -> CanvasDocument {
        let id = document.id
        let position = try cursor(db, id: id)
        let column = undo ? "before_snapshot" : "after_snapshot"
        if !undo && position == Int64.max { throw DocumentError.nothingToRedo }
        let target = undo ? position : position + 1
        guard let row = try db.execute("SELECT \(column) FROM history WHERE document_id = ? AND sequence = ?",
                                      [.text(id.uuidString), .integer(target)]).first else {
            throw undo ? DocumentError.nothingToUndo : DocumentError.nothingToRedo
        }
        guard let data = row[0].data else { throw PersistenceError.corruptData("Invalid history row") }
        let restored = try JSONDecoder().decode(DocumentDelta.self, from: data).applying(to: document)
        try db.execute("UPDATE documents SET history_cursor = ? WHERE id = ?",
                       [.integer(undo ? target - 1 : target), .text(id.uuidString)])
        return restored
    }

    static func state(_ db: SQLiteConnection, id: UUID) throws -> HistoryState {
        let position = try cursor(db, id: id)
        let rows = try db.execute("SELECT sequence FROM history WHERE document_id = ?", [.text(id.uuidString)])
        let sequences = rows.compactMap { $0.first?.int }
        return HistoryState(canUndo: sequences.contains(position),
                            canRedo: position < Int64.max && sequences.contains(position + 1), retainedEntries: sequences.count)
    }
}
