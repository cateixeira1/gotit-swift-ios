import Foundation
import GotItDomain

public struct DocumentSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let revision: Int64
    public let updatedAt: Date
    public let createdAt: Date
    public let kind: DocumentKind
}

/// Offline document repository. No async suspension occurs inside a database transaction.
public actor SQLiteStore {
    private let db: SQLiteConnection
    private let historyLimit: Int

    /// Use an app-owned Application Support URL. Parent directory must already exist.
    public init(url: URL, historyLimit: Int = 50) throws {
        guard url.isFileURL, !url.path.utf8.contains(0), historyLimit > 0 else {
            throw DocumentError.invalid("Expected a file URL and positive history limit")
        }
        let db = try SQLiteConnection(path: url.path)
        try MigrationManager.migrate(db)
        self.db = db
        self.historyLimit = historyLimit
    }

    public func close() throws { try db.close() }

    @discardableResult
    public func create(_ document: CanvasDocument) throws -> CanvasDocument {
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
        try db.transaction(write: false) { try readDocument(id) }
    }

    public func listDocuments() throws -> [DocumentSummary] {
        try db.execute("SELECT metadata FROM documents ORDER BY id").map { row in
            let document: CanvasDocument = try decode(row[0])
            return DocumentSummary(id: document.id, title: document.title, revision: document.revision, updatedAt: document.updatedAt, createdAt: document.createdAt, kind: document.kind)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    /// The revision is checked while holding SQLite's write lock, including across connections.
    @discardableResult
    public func execute(_ commands: [DocumentCommand], documentID: UUID, expectedRevision: Int64) throws -> CanvasDocument {
        try db.transaction {
            let before = try readDocument(documentID)
            try checkRevision(before, expected: expectedRevision)
            var after = try CommandEngine.applying(commands, to: before)
            try advance(&after, from: before)
            try writeContents(after)
            try HistoryStore.record(db, before: before, after: after, commands: commands, limit: historyLimit)
            return after
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

    /// Explicit permanent deletion, including its history. Ordinary block deletion is undoable.
    public func deleteDocument(_ id: UUID, expectedRevision: Int64) throws {
        try db.transaction {
            try checkRevision(readDocument(id), expected: expectedRevision)
            try db.execute("DELETE FROM documents WHERE id = ?", [.text(id.uuidString)])
        }
    }

    private func restore(_ id: UUID, expectedRevision: Int64, undo: Bool) throws -> CanvasDocument {
        try db.transaction {
            let before = try readDocument(id)
            try checkRevision(before, expected: expectedRevision)
            var restored = try HistoryStore.restore(db, id: id, undo: undo)
            try advance(&restored, from: before)
            try DocumentValidator.validate(restored)
            try writeContents(restored)
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

    /// First implementation rewrites a document's rows inside one transaction.
    /// Keep this private so differential writes can replace it without changing the editor API.
    private func writeContents(_ document: CanvasDocument) throws {
        let key = SQLValue.text(document.id.uuidString)
        let encoder = JSONEncoder()
        try db.execute("UPDATE documents SET metadata = ? WHERE id = ?", [.blob(try metadata(document)), key])
        try db.execute("DELETE FROM block_relations WHERE document_id = ?", [key])
        try db.execute("DELETE FROM blocks WHERE document_id = ?", [key])
        try db.execute("DELETE FROM assets WHERE document_id = ?", [key])
        for (ordinal, asset) in document.assets.enumerated() {
            var header = asset
            header.derivatives = []
            try db.execute("INSERT INTO assets VALUES (?, ?, ?, ?)",
                           [key, .text(asset.hash), .integer(Int64(ordinal)), .blob(try encoder.encode(header))])
            for (index, derivative) in asset.derivatives.enumerated() {
                try db.execute("INSERT INTO asset_derivatives VALUES (?, ?, ?, ?, ?)",
                               [key, .text(asset.hash), .text(derivative.role), .integer(Int64(index)), .blob(try encoder.encode(derivative))])
            }
        }
        for (ordinal, block) in document.blocks.enumerated() {
            var header = block
            if case .text = block.content { header.content = .text(RichText(runs: [])) }
            try db.execute("INSERT INTO blocks VALUES (?, ?, ?, ?, ?, ?, ?)", [key, .text(block.id.uuidString),
                block.parentID.map { .text($0.uuidString) } ?? .null,
                block.layout.anchorID.map { .text($0.uuidString) } ?? .null,
                block.content.assetHash.map { .text($0) } ?? .null,
                .integer(Int64(ordinal)), .blob(try encoder.encode(header))])
            if case .text(let text) = block.content {
                try db.execute("INSERT INTO text_contents VALUES (?, ?, ?)",
                               [key, .text(block.id.uuidString), .blob(try encoder.encode(text))])
            }
        }
        for (ordinal, relation) in document.relations.enumerated() {
            try db.execute("INSERT INTO block_relations VALUES (?, ?, ?, ?, ?, ?)", [key, .text(relation.id.uuidString),
                .text(relation.sourceID.uuidString), .text(relation.targetID.uuidString),
                .integer(Int64(ordinal)), .blob(try encoder.encode(relation))])
        }
    }
}
