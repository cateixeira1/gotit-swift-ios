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
    private var cachedDocument: CanvasDocument?

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
        try db.execute("SELECT metadata FROM documents ORDER BY id").map { row in
            let document: CanvasDocument = try decode(row[0])
            return DocumentSummary(id: document.id, title: document.title, revision: document.revision, updatedAt: document.updatedAt, createdAt: document.createdAt, kind: document.kind)
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
            try HistoryStore.record(db, before: before, after: after, commands: commands, limit: historyLimit, group: historyGroup)
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
