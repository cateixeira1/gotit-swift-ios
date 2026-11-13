import Foundation
import GotItDomain

public struct DocumentSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let revision: Int64
    public let updatedAt: Date
    public let createdAt: Date
    public let kind: DocumentKind
    /// When it went to the Lixeira; nil for documents in use.
    public let trashedAt: Date?
    public var isTrashed: Bool { trashedAt != nil }
    /// The folder it is filed in; nil at the top level.
    public var folderID: UUID? = nil
}

/// A folder of notes and Teias, possibly inside another one.
public struct Folder: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public let createdAt: Date
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.parentID = parentID; self.createdAt = createdAt
    }

    /// Names are trimmed, not empty and at most 120 characters.
    public static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentError.invalid("Dê um nome à pasta.") }
        guard trimmed.count <= 120 else { throw DocumentError.invalid("O nome da pasta pode ter até 120 caracteres.") }
        return trimmed
    }
}

/// Offline document repository. No async suspension occurs inside a database transaction.
public actor SQLiteStore {
    private let db: SQLiteConnection
    private let historyLimit: Int
    private let historyByteLimit: Int
    private var cachedDocument: CanvasDocument?

    /// Use an app-owned Application Support URL. Parent directory must already exist.
    /// History keeps at most `historyLimit` groups and about `historyByteLimit` bytes of deltas per document.
    public init(url: URL, historyLimit: Int = 50, historyByteLimit: Int = 32 * 1024 * 1024) throws {
        guard url.isFileURL, !url.path.utf8.contains(0), historyLimit > 0, historyByteLimit > 0 else {
            throw DocumentError.invalid("Expected a file URL and positive history limits")
        }
        let db = try SQLiteConnection(path: url.path)
        try MigrationManager.migrate(db)
        self.db = db
        self.historyLimit = historyLimit
        self.historyByteLimit = historyByteLimit
    }

    public func close() throws { try db.close() }

    @discardableResult
    public func create(_ document: CanvasDocument) throws -> CanvasDocument {
        cachedDocument = nil
        guard document.revision == 0 else { throw DocumentError.invalid("New documents start at revision zero") }
        try DocumentValidator.validate(document)
        return try db.transaction {
            try db.execute("INSERT INTO documents(id, metadata) VALUES (?, ?)",
                           [.text(document.id.uuidString), .blob(try metadata(document))])
            try writeContents(document)
            return document
        }
    }

    public func load(_ id: UUID) throws -> CanvasDocument {
        let document = try db.transaction(write: false) { try readDocument(id) }
        cachedDocument = document
        return document
    }

    public func listDocuments() throws -> [DocumentSummary] {
        try db.execute("""
            SELECT documents.metadata, trash.trashed_at, document_folders.folder_id FROM documents
            LEFT JOIN trash ON trash.document_id = documents.id LEFT JOIN document_folders ON document_folders.document_id = documents.id
            ORDER BY documents.id
            """).map { row in
            let document: CanvasDocument = try decode(row[0])
            // Milliseconds since 1970; NULL when the document is not in the Lixeira.
            let trashedAt = row[1].int.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            var folder: UUID?
            if case .text(let id) = row[2] { folder = UUID(uuidString: id) }
            return DocumentSummary(id: document.id, title: document.title, revision: document.revision, updatedAt: document.updatedAt,
                                   createdAt: document.createdAt, kind: document.kind, trashedAt: trashedAt, folderID: folder)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    /// The revision is checked while holding SQLite's write lock, including across connections.
    @discardableResult
    public func execute(_ commands: [DocumentCommand], documentID: UUID, expectedRevision: Int64, historyGroup: String? = nil, operationID: UUID? = nil) throws -> CanvasDocument {
        let saved = try db.transaction {
            if let operationID, let receipt = try db.execute("SELECT document_id, expected_revision, commands FROM edit_receipts WHERE id = ?", [.text(operationID.uuidString)]).first {
                guard case .text(let owner) = receipt[0], owner == documentID.uuidString, receipt[1].int == expectedRevision,
                      let bytes = receipt[2].data, try JSONDecoder().decode([DocumentCommand].self, from: bytes) == commands else {
                    throw DocumentError.invalid("Operation ID reused with different contents")
                }
                return try readDocument(documentID)
            }
            let before = try readDocument(documentID)
            try checkRevision(before, expected: expectedRevision)
            var after = try CommandEngine.applying(commands, to: before)
            try advance(&after, from: before)
            try writeContents(after, previous: before)
            try HistoryStore.record(db, before: before, after: after, commands: commands, limit: historyLimit, byteLimit: historyByteLimit, group: historyGroup)
            if let operationID {
                try db.execute("INSERT INTO edit_receipts VALUES (?, ?, ?, ?)", [.text(operationID.uuidString), .text(documentID.uuidString), .integer(expectedRevision), .blob(try JSONEncoder().encode(commands))])
            }
            return after
        }
        cachedDocument = saved
        return saved
    }

    /// Acknowledge only after the host has durably removed this entry from its journal.
    public func acknowledgeOperation(_ id: UUID) throws {
        try db.execute("DELETE FROM edit_receipts WHERE id = ?", [.text(id.uuidString)])
    }

    /// Several acknowledgements in one transaction.
    public func acknowledgeOperations(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids { try db.execute("DELETE FROM edit_receipts WHERE id = ?", [.text(id.uuidString)]) }
        }
    }

    @discardableResult
    public func undo(documentID: UUID, expectedRevision: Int64) throws -> CanvasDocument {
        try restore(documentID, expectedRevision: expectedRevision, undo: true)
    }

    @discardableResult
    public func redo(documentID: UUID, expectedRevision: Int64) throws -> CanvasDocument {
        try restore(documentID, expectedRevision: expectedRevision, undo: false)
    }

    public func historyState(documentID: UUID) throws -> HistoryState {
        try db.transaction(write: false) { try HistoryStore.state(db, id: documentID) }
    }

    /// Run while the asset writer is idle. Both sides of retained undo/redo are roots.
    public func retainedAssetHashes() throws -> Set<String> {
        try db.transaction(write: false) {
            var hashes: Set<String> = []
            func retain(_ d: CanvasDocument) {
                for asset in d.assets { hashes.insert(asset.hash); hashes.formUnion(asset.derivatives.map(\.hash)) }
            }
            for summary in try listDocuments() {
                let current = try readDocument(summary.id)
                retain(current)
                let cursor = try HistoryStore.cursor(db, id: summary.id)
                let rows = try db.execute("SELECT sequence, before_snapshot, after_snapshot FROM history WHERE document_id = ? ORDER BY sequence", [.text(summary.id.uuidString)])
                var state = current
                for row in rows.reversed() where (row[0].int ?? 0) <= cursor {
                    guard let data = row[1].data else { throw PersistenceError.corruptData("Missing inverse delta") }
                    state = try JSONDecoder().decode(DocumentDelta.self, from: data).applying(to: state); retain(state)
                }
                state = current
                for row in rows where (row[0].int ?? 0) > cursor {
                    guard let data = row[2].data else { throw PersistenceError.corruptData("Missing forward delta") }
                    state = try JSONDecoder().decode(DocumentDelta.self, from: data).applying(to: state); retain(state)
                }
            }
            return hashes
        }
    }

    /// Explicit permanent deletion, including its history. Ordinary block deletion is undoable.
    public func deleteDocument(_ id: UUID, expectedRevision: Int64) throws {
        try db.transaction {
            try checkRevision(readDocument(id), expected: expectedRevision)
            try db.execute("DELETE FROM documents WHERE id = ?", [.text(id.uuidString)])
        }
        if cachedDocument?.id == id { cachedDocument = nil }
    }

    /// Moves a note or Teia to the Lixeira. Its contents and history stay as they are, so
    /// restoring it brings back exactly what was there (undo included).
    public func moveToTrash(_ id: UUID, at date: Date = Date()) throws {
        try db.transaction {
            _ = try readHeader(id)
            try db.execute("INSERT OR REPLACE INTO trash(document_id, trashed_at) VALUES (?, ?)", [.text(id.uuidString), .integer(Int64((date.timeIntervalSince1970 * 1000).rounded()))])
        }
    }

    public func restoreFromTrash(_ id: UUID) throws {
        try db.transaction {
            _ = try readHeader(id)
            try db.execute("DELETE FROM trash WHERE document_id = ?", [.text(id.uuidString)])
        }
    }

    /// Deletes for good everything in the Lixeira; returns how many documents went.
    @discardableResult
    public func emptyTrash() throws -> Int {
        let count = try db.transaction {
            let ids = try db.execute("SELECT document_id FROM trash")
            try db.execute("DELETE FROM documents WHERE id IN (SELECT document_id FROM trash)")
            return ids.count
        }
        cachedDocument = nil
        return count
    }

    // MARK: Folders

    /// Every folder, by name (case and accents ignored) within each parent.
    public func listFolders() throws -> [Folder] {
        try db.execute("SELECT id, parent_id, name, created_at FROM folders").compactMap { row -> Folder? in
            guard case .text(let id) = row[0], let uuid = UUID(uuidString: id), case .text(let name) = row[2] else { return nil }
            var parent: UUID?
            if case .text(let value) = row[1] { parent = UUID(uuidString: value) }
            return Folder(id: uuid, name: name, parentID: parent, createdAt: Date(timeIntervalSince1970: Double(row[3].int ?? 0) / 1000))
        }.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) == .orderedAscending }
    }

    @discardableResult
    public func createFolder(named name: String, in parent: UUID? = nil, at date: Date = Date()) throws -> Folder {
        let folder = Folder(name: try Folder.validName(name), parentID: parent, createdAt: date)
        try db.transaction {
            if let parent { try requireFolder(parent) }
            try db.execute("INSERT INTO folders(id, parent_id, name, created_at) VALUES (?, ?, ?, ?)",
                           [.text(folder.id.uuidString), parent.map { SQLValue.text($0.uuidString) } ?? .null, .text(folder.name),
                            .integer(Int64((date.timeIntervalSince1970 * 1000).rounded()))])
        }
        return folder
    }

    public func renameFolder(_ id: UUID, to name: String) throws {
        let valid = try Folder.validName(name)
        try db.transaction {
            try requireFolder(id)
            try db.execute("UPDATE folders SET name = ? WHERE id = ?", [.text(valid), .text(id.uuidString)])
        }
    }

    /// Puts a folder inside another (nil: the top level). A folder never goes inside itself or
    /// inside one of its own subfolders.
    public func moveFolder(_ id: UUID, to parent: UUID?) throws {
        try db.transaction {
            try requireFolder(id)
            if let parent {
                try requireFolder(parent)
                var current: UUID? = parent
                var seen: Set<UUID> = []
                while let folder = current, seen.insert(folder).inserted {
                    guard folder != id else { throw DocumentError.invalid("Uma pasta não pode ir para dentro dela mesma.") }
                    current = try db.execute("SELECT parent_id FROM folders WHERE id = ?", [.text(folder.uuidString)]).first.flatMap { row in
                        if case .text(let value) = row[0] { return UUID(uuidString: value) }; return nil
                    }
                }
            }
            try db.execute("UPDATE folders SET parent_id = ? WHERE id = ?", [parent.map { SQLValue.text($0.uuidString) } ?? .null, .text(id.uuidString)])
        }
    }

    /// Deletes a folder, never its contents: its notes and subfolders move up to its parent.
    public func deleteFolder(_ id: UUID) throws {
        try db.transaction {
            try requireFolder(id)
            let parent: SQLValue = try db.execute("SELECT parent_id FROM folders WHERE id = ?", [.text(id.uuidString)]).first?[0] ?? .null
            try db.execute("UPDATE folders SET parent_id = ? WHERE parent_id = ?", [parent, .text(id.uuidString)])
            if case .text = parent {
                try db.execute("UPDATE document_folders SET folder_id = ? WHERE folder_id = ?", [parent, .text(id.uuidString)])
            } else {
                try db.execute("DELETE FROM document_folders WHERE folder_id = ?", [.text(id.uuidString)])
            }
            try db.execute("DELETE FROM folders WHERE id = ?", [.text(id.uuidString)])
        }
    }

    /// Files a note or Teia in a folder (nil: the top level). Not an edit of the note: no history.
    public func moveDocument(_ id: UUID, to folder: UUID?) throws {
        try db.transaction {
            _ = try readHeader(id)
            if let folder {
                try requireFolder(folder)
                try db.execute("INSERT OR REPLACE INTO document_folders(document_id, folder_id) VALUES (?, ?)", [.text(id.uuidString), .text(folder.uuidString)])
            } else {
                try db.execute("DELETE FROM document_folders WHERE document_id = ?", [.text(id.uuidString)])
            }
        }
    }

    private func requireFolder(_ id: UUID) throws {
        guard try !db.execute("SELECT 1 FROM folders WHERE id = ?", [.text(id.uuidString)]).isEmpty else {
            throw DocumentError.invalid("A pasta não existe mais.")
        }
    }

    private func readHeader(_ id: UUID) throws -> CanvasDocument {
        guard let row = try db.execute("SELECT metadata FROM documents WHERE id = ?", [.text(id.uuidString)]).first else {
            throw DocumentError.missingDocument(id)
        }
        return try decode(row[0])
    }

    private func restore(_ id: UUID, expectedRevision: Int64, undo: Bool) throws -> CanvasDocument {
        try db.transaction {
            let before = try readDocument(id)
            try checkRevision(before, expected: expectedRevision)
            var restored = try HistoryStore.restore(db, document: before, undo: undo)
            try advance(&restored, from: before)
            try DocumentValidator.validate(restored)
            try writeContents(restored, previous: before)
            return restored
        }
    }

    private func checkRevision(_ document: CanvasDocument, expected: Int64) throws {
        guard document.revision == expected else {
            throw DocumentError.revisionConflict(expected: expected, actual: document.revision)
        }
    }

    private func advance(_ document: inout CanvasDocument, from before: CanvasDocument) throws {
        guard before.revision < Int64.max else { throw DocumentError.invalid("Revision exhausted") }
        document.revision = before.revision + 1
        document.createdAt = before.createdAt
        document.updatedAt = max(Date(), before.updatedAt)
    }

    private func metadata(_ document: CanvasDocument) throws -> Data {
        var header = document
        header.blocks = []; header.assets = []; header.relations = []
        return try JSONEncoder().encode(header)
    }

    private func decode<T: Decodable>(_ value: SQLValue) throws -> T {
        guard let data = value.data else { throw PersistenceError.corruptData("Expected JSON blob") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func readDocument(_ id: UUID) throws -> CanvasDocument {
        let key = SQLValue.text(id.uuidString)
        guard let row = try db.execute("SELECT metadata FROM documents WHERE id = ?", [key]).first else {
            throw DocumentError.missingDocument(id)
        }
        var document: CanvasDocument = try decode(row[0])
        guard document.id == id else { throw PersistenceError.corruptData("Document ID mismatch") }
        // Read the revision while holding SQLite's transaction lock: another connection
        // invalidates this single-document cache by committing a new revision.
        if let cachedDocument, cachedDocument.id == id, cachedDocument.revision == document.revision {
            var cachedHeader = cachedDocument
            cachedHeader.blocks = []; cachedHeader.assets = []; cachedHeader.relations = []
            if cachedHeader == document { return cachedDocument }
        }
        let textRows = try db.execute("SELECT block_id, content FROM text_contents WHERE document_id = ?", [key])
        var texts: [String: RichText] = [:]
        for row in textRows {
            guard case .text(let blockID) = row[0] else { throw PersistenceError.corruptData("Invalid text owner") }
            texts[blockID] = try decode(row[1])
        }
        document.blocks = try db.execute("SELECT id, metadata FROM blocks WHERE document_id = ? ORDER BY ordinal", [key]).map { row in
            var block: CanvasBlock = try decode(row[1])
            guard case .text(let storedID) = row[0], storedID == block.id.uuidString else {
                throw PersistenceError.corruptData("Block ID mismatch")
            }
            if case .text = block.content {
                guard let text = texts.removeValue(forKey: block.id.uuidString) else {
                    throw PersistenceError.corruptData("Missing rich text")
                }
                block.content = .text(text)
            }
            return block
        }
        guard texts.isEmpty else { throw PersistenceError.corruptData("Unexpected rich text row") }
        let derivatives = try db.execute("SELECT asset_hash, metadata FROM asset_derivatives WHERE document_id = ? ORDER BY ordinal", [key])
        var byHash: [String: [AssetDerivative]] = [:]
        for row in derivatives {
            guard case .text(let hash) = row[0] else { throw PersistenceError.corruptData("Invalid derivative owner") }
            byHash[hash, default: []].append(try decode(row[1]))
        }
        document.assets = try db.execute("SELECT hash, metadata FROM assets WHERE document_id = ? ORDER BY ordinal", [key]).map { row in
            var asset: Asset = try decode(row[1])
            guard case .text(let hash) = row[0], hash == asset.hash else { throw PersistenceError.corruptData("Asset hash mismatch") }
            asset.derivatives = byHash.removeValue(forKey: asset.hash) ?? []
            return asset
        }
        guard byHash.isEmpty else { throw PersistenceError.corruptData("Unexpected derivative row") }
        document.relations = try db.execute("SELECT metadata FROM block_relations WHERE document_id = ? ORDER BY ordinal", [key]).map { try decode($0[0]) }
        try DocumentValidator.validate(document)
        return document
    }

    /// Upsert only changed rows; never delete/reinsert unrelated blocks on typing.
    private func writeContents(_ document: CanvasDocument, previous: CanvasDocument? = nil) throws {
        let key = SQLValue.text(document.id.uuidString)
        let encoder = JSONEncoder()
        try db.execute("UPDATE documents SET metadata = ? WHERE id = ?", [.blob(try metadata(document)), key])
        let oldBlocks = Dictionary(uniqueKeysWithValues: (previous?.blocks ?? []).enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
        let oldAssets = Dictionary(uniqueKeysWithValues: (previous?.assets ?? []).enumerated().map { ($0.element.hash, ($0.offset, $0.element)) })
        let oldRelations = Dictionary(uniqueKeysWithValues: (previous?.relations ?? []).enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
        for old in previous?.relations ?? [] where !document.relations.contains(where: { $0.id == old.id }) {
            try db.execute("DELETE FROM block_relations WHERE document_id = ? AND id = ?", [key, .text(old.id.uuidString)])
        }
        for old in previous?.blocks ?? [] where !document.blocks.contains(where: { $0.id == old.id }) {
            try db.execute("DELETE FROM blocks WHERE document_id = ? AND id = ?", [key, .text(old.id.uuidString)])
        }
        for old in previous?.assets ?? [] where !document.assets.contains(where: { $0.hash == old.hash }) {
            try db.execute("DELETE FROM assets WHERE document_id = ? AND hash = ?", [key, .text(old.hash)])
        }
        for (ordinal, asset) in document.assets.enumerated() {
            if let old = oldAssets[asset.hash], old.0 == ordinal, old.1 == asset { continue }
            try db.execute("DELETE FROM asset_derivatives WHERE document_id = ? AND asset_hash = ?", [key, .text(asset.hash)])
            var header = asset
            header.derivatives = []
            try db.execute("INSERT INTO assets VALUES (?, ?, ?, ?) ON CONFLICT(document_id, hash) DO UPDATE SET ordinal=excluded.ordinal, metadata=excluded.metadata",
                           [key, .text(asset.hash), .integer(Int64(ordinal)), .blob(try encoder.encode(header))])
            for (index, derivative) in asset.derivatives.enumerated() {
                try db.execute("INSERT INTO asset_derivatives VALUES (?, ?, ?, ?, ?)",
                               [key, .text(asset.hash), .text(derivative.role), .integer(Int64(index)), .blob(try encoder.encode(derivative))])
            }
        }
        for (ordinal, block) in document.blocks.enumerated() {
            if let old = oldBlocks[block.id], old.0 == ordinal, old.1 == block { continue }
            var header = block
            if case .text = block.content { header.content = .text(RichText(runs: [])) }
            try db.execute("INSERT INTO blocks VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(document_id, id) DO UPDATE SET parent_id=excluded.parent_id, anchor_id=excluded.anchor_id, asset_hash=excluded.asset_hash, ordinal=excluded.ordinal, metadata=excluded.metadata", [key, .text(block.id.uuidString),
                block.parentID.map { .text($0.uuidString) } ?? .null,
                block.layout.anchorID.map { .text($0.uuidString) } ?? .null,
                block.content.assetHash.map { .text($0) } ?? .null,
                .integer(Int64(ordinal)), .blob(try encoder.encode(header))])
            try db.execute("DELETE FROM text_contents WHERE document_id = ? AND block_id = ?", [key, .text(block.id.uuidString)])
            if case .text(let text) = block.content {
                try db.execute("INSERT INTO text_contents VALUES (?, ?, ?)",
                               [key, .text(block.id.uuidString), .blob(try encoder.encode(text))])
            }
        }
        for (ordinal, relation) in document.relations.enumerated() {
            if let old = oldRelations[relation.id], old.0 == ordinal, old.1 == relation { continue }
            try db.execute("INSERT INTO block_relations VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(document_id, id) DO UPDATE SET source_id=excluded.source_id, target_id=excluded.target_id, ordinal=excluded.ordinal, metadata=excluded.metadata", [key, .text(relation.id.uuidString),
                .text(relation.sourceID.uuidString), .text(relation.targetID.uuidString),
                .integer(Int64(ordinal)), .blob(try encoder.encode(relation))])
        }
    }
}
