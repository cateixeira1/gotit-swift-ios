import Foundation
import GotItDomain

enum MigrationManager {
    static func migrate(_ db: SQLiteConnection) throws {
        try db.transaction {
            guard let version = try db.execute("PRAGMA user_version").first?.first?.int else {
                throw PersistenceError.corruptData("Missing schema version")
            }
            guard version <= 6 else { throw PersistenceError.unsupportedSchema(version) }
            if version == 0 {
                guard let url = Bundle.module.url(forResource: "001_document_core", withExtension: "sql") else {
                    throw PersistenceError.corruptData("Missing bundled migration")
                }
                try db.script(String(contentsOf: url, encoding: .utf8))
            }
            // Version 2 adds canvas metadata and new block kinds. Legacy payloads (including
            // history snapshots) decode with defaults; old writers must refuse this database.
            // Version 3 adds ordered pages and page membership; payload defaults preserve v1/v2 history.
            if version < 4 {
                // Convert old snapshots transactionally; preserve the undo cursor and redo branch.
                for row in try db.execute("SELECT document_id, sequence, before_snapshot, after_snapshot FROM history") {
                    guard let beforeData = row[2].data, let afterData = row[3].data else { throw PersistenceError.corruptData("Invalid legacy history") }
                    func prune(_ document: CanvasDocument) -> CanvasDocument {
                        var result = document
                        let used = Set(document.blocks.compactMap { $0.content.assetHash })
                        result.assets.removeAll { $0.mediaType == "application/x-pencilkit" && !used.contains($0.hash) }
                        return result
                    }
                    let before = prune(try JSONDecoder().decode(CanvasDocument.self, from: beforeData))
                    let after = prune(try JSONDecoder().decode(CanvasDocument.self, from: afterData))
                    try db.execute("UPDATE history SET commands = ?, before_snapshot = ?, after_snapshot = ? WHERE document_id = ? AND sequence = ?",
                        [.blob(Data("null".utf8)), .blob(try JSONEncoder().encode(DocumentDelta.between(after, before))),
                         .blob(try JSONEncoder().encode(DocumentDelta.between(before, after))), row[0], row[1]])
                }
            }
            if version < 4 {
                for row in try db.execute("SELECT document_id, hash, metadata FROM assets WHERE NOT EXISTS (SELECT 1 FROM blocks WHERE blocks.document_id = assets.document_id AND blocks.asset_hash = assets.hash)") {
                    guard let data = row[2].data else { throw PersistenceError.corruptData("Missing asset") }
                    if try JSONDecoder().decode(Asset.self, from: data).mediaType == "application/x-pencilkit" {
                        try db.execute("DELETE FROM assets WHERE document_id = ? AND hash = ?", [row[0], row[1]])
                    }
                }
            }
            if version < 6 {
                try db.script("CREATE TABLE IF NOT EXISTS edit_receipts (id TEXT PRIMARY KEY NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, expected_revision INTEGER NOT NULL, commands BLOB NOT NULL);")
                try db.execute("PRAGMA user_version = 6")
            }
        }
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = FULL")
    }
}
