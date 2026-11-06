import Foundation

enum MigrationManager {
    static func migrate(_ db: SQLiteConnection) throws {
        try db.transaction {
            guard let version = try db.execute("PRAGMA user_version").first?.first?.int else {
                throw PersistenceError.corruptData("Missing schema version")
            }
            guard version <= 2 else { throw PersistenceError.unsupportedSchema(version) }
            if version == 0 {
                guard let url = Bundle.module.url(forResource: "001_document_core", withExtension: "sql") else {
                    throw PersistenceError.corruptData("Missing bundled migration")
                }
                try db.script(String(contentsOf: url, encoding: .utf8))
            }
            // Version 2 adds canvas metadata and new block kinds. Legacy payloads (including
            // history snapshots) decode with defaults; old writers must refuse this database.
            if version < 2 { try db.execute("PRAGMA user_version = 2") }
        }
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = FULL")
    }
}
