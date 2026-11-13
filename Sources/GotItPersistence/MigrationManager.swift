import Foundation
import GotItDomain

enum MigrationManager {
    static func migrate(_ db: SQLiteConnection) throws {
        try db.transaction {
            guard let version = try db.execute("PRAGMA user_version").first?.first?.int else {
                throw PersistenceError.corruptData("Missing schema version")
            }
            guard version <= 10 else { throw PersistenceError.unsupportedSchema(version) }
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
                        let used = Set(document.blocks.flatMap { $0.content.assetHashes })
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
            // Version 7: the Lixeira. A trashed document keeps all its rows (and assets) until it is
            // deleted for good; the row goes with the document.
            if version < 7 {
                try db.script("CREATE TABLE IF NOT EXISTS trash (document_id TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE, trashed_at INTEGER NOT NULL);")
                try db.execute("PRAGMA user_version = 7")
            }
            // Version 8: folders. Like the Lixeira, where a note is filed lives outside the note
            // (moving it is not an edit to undo). A deleted note takes its filing with it.
            if version < 8 {
                try db.script("""
                CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY NOT NULL, parent_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
                                                    name TEXT NOT NULL, created_at INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS document_folders (document_id TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                                                             folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE);
                """)
                try db.execute("PRAGMA user_version = 8")
            }
            // Version 9: search. An FTS5 index of the text of every note (accents and case ignored),
            // updated in the same transaction as each edit. It is built from the notes the first
            // time it is needed, and again whenever `SearchText.indexVersion` changes.
            if version < 9 {
                try db.script("""
                CREATE VIRTUAL TABLE IF NOT EXISTS search_text USING fts5(document_id UNINDEXED, block_id UNINDEXED, kind UNINDEXED, text,
                                                                         tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE IF NOT EXISTS search_state (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL);
                """)
                try db.execute("PRAGMA user_version = 9")
            }
            // Version 10: which notes point to which (links in the text, Teia cards), kept with the
            // search index. The target is not a foreign key: a link to a deleted note just leads nowhere.
            if version < 10 {
                try db.script("""
                CREATE TABLE IF NOT EXISTS note_links (source_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                                                       target_id TEXT NOT NULL, PRIMARY KEY(source_id, target_id));
                CREATE INDEX IF NOT EXISTS note_links_target ON note_links(target_id);
                """)
                try db.execute("PRAGMA user_version = 10")
            }
        }
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = FULL")
    }
}
