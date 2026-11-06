import Foundation
import Testing
import GotItDomain
@testable import GotItPersistence

private struct DatabaseFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("notes.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gotit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

private func multimediaDocument() -> CanvasDocument {
    let hash = String(repeating: "a", count: 64)
    var document = CanvasDocument(title: "Got It! \0 — multimídia", defaultStyle: .init(fontSize: 18))
    let container = CanvasBlock(content: .container)
    let text = CanvasBlock(parentID: container.id, style: .init(bold: false), content: .text(RichText(runs: [
        TextRun("Olá 👨‍👩‍👧‍👦 e\u{301}\n\0", style: .init(bold: true)), TextRun("漢字", style: .init(italic: true))
    ])))
    let ref = AssetReference(hash: hash, caption: "Original")
    document.assets = [Asset(hash: hash, mediaType: "application/octet-stream", byteCount: 100,
        derivatives: [.init(role: "thumbnail", hash: String(repeating: "b", count: 64), mediaType: "image/png", byteCount: 10)])]
    // Child before parent exercises deferred foreign keys.
    document.blocks = [text, container]
    let contents: [BlockContent] = [.image(ref), .drawing(ref), .pdf(ref), .audio(ref), .video(ref), .shape(.init(kind: .ellipse))]
    for (index, content) in contents.enumerated() {
        document.blocks.append(CanvasBlock(order: index + 1, layout: .init(mode: .absolute), content: content))
    }
    document.blocks.append(CanvasBlock(order: 7, layout: .init(mode: .anchored, anchorID: container.id), content: .text(RichText("Anchor"))))
    document.relations = [.init(sourceID: text.id, targetID: document.blocks[2].id, kind: .annotation)]
    return document
}

@Test func allContentRoundTripsAfterClosingAndReopening() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let document = multimediaDocument()
    try await store.create(document)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    #expect(try await reopened.load(document.id) == document)
    #expect(try await reopened.listDocuments().first?.title == document.title)
    try await reopened.close()
}

@Test func undoRedoSurvivesRestartWithMonotonicRevisions() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = multimediaDocument()
    try await store.create(original)
    let edited = try await store.execute([.rename("Edited"), .removeSubtree(original.blocks[0].id)], documentID: original.id, expectedRevision: 0)
    #expect(edited.revision == 1)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    let undone = try await reopened.undo(documentID: original.id, expectedRevision: 1)
    #expect(undone.blocks == original.blocks)
    #expect(undone.relations == original.relations)
    #expect(undone.assets == original.assets)
    #expect(undone.title == original.title)
    #expect(undone.revision == 2)
    try await reopened.close()
    let again = try SQLiteStore(url: fixture.url)
    let redone = try await again.redo(documentID: original.id, expectedRevision: 2)
    #expect(redone.blocks == edited.blocks)
    #expect(redone.title == "Edited")
    #expect(redone.revision == 3)
    try await again.close()
}

@Test func newEditAfterUndoDiscardsRedo() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let document = try await store.create(CanvasDocument(title: "A"))
    try await store.execute([.rename("B")], documentID: document.id, expectedRevision: 0)
    try await store.undo(documentID: document.id, expectedRevision: 1)
    try await store.execute([.rename("C")], documentID: document.id, expectedRevision: 2)
    #expect(try await store.historyState(documentID: document.id).canRedo == false)
    await #expect(throws: DocumentError.nothingToRedo) { try await store.redo(documentID: document.id, expectedRevision: 3) }
    #expect(try await store.load(document.id).title == "C")
    try await store.close()
}

@Test func staleRevisionCannotOverwriteAnotherConnection() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let first = try SQLiteStore(url: fixture.url)
    let second = try SQLiteStore(url: fixture.url)
    let document = try await first.create(CanvasDocument(title: "A"))
    try await first.execute([.rename("Winner")], documentID: document.id, expectedRevision: 0)
    await #expect(throws: DocumentError.revisionConflict(expected: 0, actual: 1)) {
        try await second.execute([.rename("Stale")], documentID: document.id, expectedRevision: 0)
    }
    #expect(try await second.load(document.id).title == "Winner")
    #expect(try await second.historyState(documentID: document.id).retainedEntries == 1)
    try await first.close(); try await second.close()
}

@Test func concurrentWritersHaveExactlyOneWinner() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let first = try SQLiteStore(url: fixture.url)
    let second = try SQLiteStore(url: fixture.url)
    let document = try await first.create(CanvasDocument(title: "A"))
    let outcomes = await withTaskGroup(of: String.self) { group in
        for store in [first, second] {
            group.addTask {
                do {
                    try await store.execute([.rename("Winner")], documentID: document.id, expectedRevision: 0)
                    return "success"
                } catch DocumentError.revisionConflict { return "conflict" }
                catch { return "unexpected: \(error)" }
            }
        }
        var results: [String] = []
        for await result in group { results.append(result) }
        return results.sorted()
    }
    #expect(outcomes == ["conflict", "success"])
    #expect(try await first.load(document.id).revision == 1)
    try await first.close(); try await second.close()
}

@Test func invalidBatchRollsBackDocumentRevisionAndHistory() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(CanvasDocument(title: "Original"))
    let orphan = CanvasBlock(parentID: UUID(), content: .text(RichText("Orphan")))
    await #expect(throws: DocumentError.self) {
        try await store.execute([.rename("Changed"), .insertBlock(orphan)], documentID: original.id, expectedRevision: 0)
    }
    #expect(try await store.load(original.id) == original)
    #expect(try await store.historyState(documentID: original.id).retainedEntries == 0)
    try await store.close()
}

@Test func sqlFailureRollsBackRowsAndHistory() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(multimediaDocument())
    let fault = try SQLiteConnection(path: fixture.url.path)
    try fault.script("CREATE TRIGGER fail_write BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT, 'injected disk write failure'); END;")
    await #expect(throws: PersistenceError.self) {
        try await store.execute([.rename("Must roll back")], documentID: original.id, expectedRevision: 0)
    }
    try fault.script("DROP TRIGGER fail_write;")
    try fault.close()
    #expect(try await store.load(original.id) == original)
    #expect(try await store.historyState(documentID: original.id).retainedEntries == 0)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    #expect(try await reopened.load(original.id) == original)
    try await reopened.close()
}

@Test func failedUndoDoesNotAdvanceHistoryCursor() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(multimediaDocument())
    let edited = try await store.execute([.rename("B")], documentID: original.id, expectedRevision: 0)
    let fault = try SQLiteConnection(path: fixture.url.path)
    try fault.script("CREATE TRIGGER fail_undo BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT, 'injected'); END;")
    await #expect(throws: PersistenceError.self) { try await store.undo(documentID: original.id, expectedRevision: 1) }
    try fault.script("DROP TRIGGER fail_undo;")
    try fault.close()
    #expect(try await store.load(original.id) == edited)
    #expect(try await store.historyState(documentID: original.id).canUndo)
    let restored = try await store.undo(documentID: original.id, expectedRevision: 1)
    #expect(restored.title == original.title)
    try await store.close()
}

@Test func boundedHistoryHasCorrectUndoFloor() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url, historyLimit: 2)
    let document = try await store.create(CanvasDocument(title: "0"))
    for revision in 0..<4 {
        try await store.execute([.rename(String(revision + 1))], documentID: document.id, expectedRevision: Int64(revision))
    }
    #expect(try await store.historyState(documentID: document.id).retainedEntries == 2)
    try await store.undo(documentID: document.id, expectedRevision: 4)
    let floor = try await store.undo(documentID: document.id, expectedRevision: 5)
    #expect(floor.title == "2")
    await #expect(throws: DocumentError.nothingToUndo) { try await store.undo(documentID: document.id, expectedRevision: 6) }
    #expect(try await store.redo(documentID: document.id, expectedRevision: 6).title == "3")
    try await store.close()
}

@Test func documentsAndTheirHistoriesRemainIsolated() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let a = try await store.create(multimediaDocument())
    var b = a; b.id = UUID(); b.title = "Other"
    try await store.create(b)
    try await store.execute([.rename("Changed")], documentID: a.id, expectedRevision: 0)
    #expect(try await store.load(b.id) == b)
    try await store.deleteDocument(a.id, expectedRevision: 1)
    #expect(try await store.load(b.id) == b)
    #expect(try await store.listDocuments().count == 1)
    await #expect(throws: DocumentError.missingDocument(a.id)) { try await store.load(a.id) }
    try await store.close()
}

@Test func refusesFutureSchemaWithoutResettingDatabase() throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let db = try SQLiteConnection(path: fixture.url.path)
    try db.script("PRAGMA user_version = 99; CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES ('keep');")
    #expect(throws: PersistenceError.unsupportedSchema(99)) { try SQLiteStore(url: fixture.url) }
    #expect(try db.execute("SELECT COUNT(*) FROM sentinel").first?.first?.int == 1)
    #expect(try db.execute("PRAGMA user_version").first?.first?.int == 99)
    try db.close()
}

@Test func migrationIsAtomicAndSafeToReopen() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    try await reopened.close()
    let db = try SQLiteConnection(path: fixture.url.path)
    #expect(try db.execute("PRAGMA user_version").first?.first?.int == 6)
    #expect(try db.execute("PRAGMA foreign_key_check").isEmpty)
    let failingFixture = try DatabaseFixture(); defer { failingFixture.clean() }
    let failing = try SQLiteConnection(path: failingFixture.url.path)
    try failing.script("CREATE TABLE blocks(sentinel INTEGER);")
    #expect(throws: PersistenceError.self) { try MigrationManager.migrate(failing) }
    #expect(try failing.execute("PRAGMA user_version").first?.first?.int == 0)
    #expect(try failing.execute("SELECT COUNT(*) FROM sqlite_master WHERE name = 'documents'").first?.first?.int == 0)
    try failing.close(); try db.close()
}

@Test func duplicateCreationAndClosedStoreFailExplicitly() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(CanvasDocument(title: "Keep"))
    await #expect(throws: PersistenceError.self) { try await store.create(original) }
    #expect(try await store.load(original.id) == original)
    try await store.close()
    await #expect(throws: PersistenceError.closed) { try await store.load(original.id) }
}

@Test func stageTwoMetadataAndTeiaRoundTripWithUndo() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    var web = multimediaDocument(); web.kind = .web
    web.blocks[0].style = .init(underline: true, strikethrough: true, baseline: .superscript, link: "https://example.com", paragraph: .init(lineSpacing: 4, headIndent: 18, list: .numbered))
    web.blocks[2].presentation = .init(wrap: .contour, rotationRadians: .pi / 4, imageCrop: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
    web.blocks.append(.init(order: 8, content: .noteReference(.init(documentID: UUID()))))
    web.blocks.append(.init(order: 9, content: .sticker(.init(hash: web.assets[0].hash))))
    web.blocks.append(.init(order: 10, content: .ink(.init(points: [.init(x: 0, y: 0), .init(x: 10, y: 10)]))))
    web.relations[0].style = .init(color: "#FFAA00", width: 3, routing: .orthogonal)
    try await store.create(web)
    var settings = web.canvas
    settings.size = try .init(width: 1200, height: 900, unit: .pixels)
    settings.recognizeDiagrams = false; settings.solveEquations = false
    let modified = try await store.execute([.setCanvasSettings(settings)], documentID: web.id, expectedRevision: 0)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    #expect(try await reopened.load(web.id) == modified)
    let undone = try await reopened.undo(documentID: web.id, expectedRevision: 1)
    #expect(undone.canvas == web.canvas)
    #expect(undone.blocks == web.blocks)
    try await reopened.close()
}

@Test(arguments: [1, 2, 3]) func migratesLegacyDocumentsAndHistoryWithoutLoss(version: Int) async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(multimediaDocument())
    try await store.execute([.rename("After")], documentID: original.id, expectedRevision: 0)
    try await store.close()
    let db = try SQLiteConnection(path: fixture.url.path)
    func legacy(_ data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if version == 1 { object.removeValue(forKey: "kind"); object.removeValue(forKey: "canvas") }
        object.removeValue(forKey: "pages")
        return try JSONSerialization.data(withJSONObject: object)
    }
    let metadata = try #require(db.execute("SELECT metadata FROM documents").first?.first?.data)
    try db.execute("UPDATE documents SET metadata = ?", [.blob(try legacy(metadata))])
    var after = original; after.title = "After"; after.revision = 1
    try db.execute("UPDATE history SET before_snapshot = ?, after_snapshot = ?", [.blob(try legacy(JSONEncoder().encode(original))), .blob(try legacy(JSONEncoder().encode(after)))])
    try db.execute("PRAGMA user_version = \(version)"); try db.close()
    let reopened = try SQLiteStore(url: fixture.url)
    let loaded = try await reopened.load(original.id)
    #expect(loaded.canvas == .init())
    #expect(loaded.kind == .note)
    #expect(loaded.pages.first?.id == original.id)
    let undone = try await reopened.undo(documentID: original.id, expectedRevision: 1)
    #expect(undone.blocks == original.blocks)
    #expect(undone.title == original.title)
    try await reopened.close()
}

@Test func pagesAndDrawingAssetsSurviveReopenAndUndo() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(CanvasDocument(title: "Notebook"))
    let page = CanvasPage(title: "Second")
    let asset = Asset(hash: String(repeating: "a", count: 64), mediaType: "application/x-pencilkit", byteCount: 512)
    let block = CanvasBlock(layout: .init(mode: .absolute), content: .drawing(.init(hash: asset.hash)), presentation: .init(wrap: .none), pageID: page.id)
    let saved = try await store.execute([.appendPage(page), .registerAsset(asset), .insertBlock(block)], documentID: original.id, expectedRevision: 0)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    #expect(try await reopened.load(original.id) == saved)
    let undone = try await reopened.undo(documentID: original.id, expectedRevision: 1)
    #expect(undone.pages == original.pages)
    #expect(undone.blocks.isEmpty)
    let redone = try await reopened.redo(documentID: original.id, expectedRevision: 2)
    #expect(redone.pages == saved.pages)
    #expect(redone.blocks == saved.blocks)
    try await reopened.close()
}

@Test func groupedTypingUsesDeltasAndLeavesUnrelatedRowsUntouched() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    var note = CanvasDocument(title: "Large")
    let large = CanvasBlock(order: 1, content: .text(.init(String(repeating: "unchanged", count: 100_000))))
    var text = CanvasBlock(content: .text(.init("")))
    note.blocks = [text, large]
    note = try await store.create(note)
    let db = try SQLiteConnection(path: fixture.url.path)
    try db.script("CREATE TABLE touched(id TEXT); CREATE TRIGGER block_updated AFTER UPDATE ON blocks BEGIN INSERT INTO touched VALUES (new.id); END;")
    for i in 1...80 {
        text.content = .text(.init(String(repeating: "é👨‍👩‍👧‍👦", count: i)))
        note = try await store.execute([.replaceBlock(text)], documentID: note.id, expectedRevision: note.revision, historyGroup: "typing")
    }
    #expect(try await store.historyState(documentID: note.id).retainedEntries == 1)
    #expect(try db.execute("SELECT id FROM touched WHERE id = ?", [.text(large.id.uuidString)]).isEmpty)
    let size = try #require(db.execute("SELECT length(before_snapshot) + length(after_snapshot) FROM history").first?.first?.int)
    #expect(size < 80_000)
    try await store.close(); try db.close()
    let reopened = try SQLiteStore(url: fixture.url)
    let undone = try await reopened.undo(documentID: note.id, expectedRevision: note.revision)
    #expect(undone.blocks[0].content == .text(.init("")))
    let redone = try await reopened.redo(documentID: note.id, expectedRevision: undone.revision)
    #expect(redone.blocks == note.blocks)
    let branched = try await reopened.undo(documentID: note.id, expectedRevision: redone.revision)
    text.content = .text(.init("branch"))
    let replacement = try await reopened.execute([.replaceBlock(text)], documentID: note.id, expectedRevision: branched.revision, historyGroup: "typing")
    #expect(try await reopened.historyState(documentID: note.id).canRedo == false)
    #expect(try await reopened.undo(documentID: note.id, expectedRevision: replacement.revision).blocks[0].content == .text(.init("")))
    try await reopened.close()
}

@Test func drawingAssetsRemainReachableOnlyWhileUndoOrRedoNeedsThem() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url, historyLimit: 2)
    var note = try await store.create(.init(title: "Ink"))
    var block = CanvasBlock(content: .drawing(.init(hash: String(repeating: "a", count: 64))))
    var hashes: [String] = []
    for letter in ["a", "b", "c", "d"] {
        let hash = String(repeating: letter, count: 64); hashes.append(hash)
        block.content = .drawing(.init(hash: hash))
        var commands: [DocumentCommand] = [.registerAsset(.init(hash: hash, mediaType: "application/x-pencilkit", byteCount: 100))]
        commands.append(note.blocks.isEmpty ? .insertBlock(block) : .replaceBlock(block))
        if hashes.count > 1 { commands.append(.unregisterAsset(hashes[hashes.count - 2])) }
        note = try await store.execute(commands, documentID: note.id, expectedRevision: note.revision)
    }
    #expect(note.assets.count == 1)
    #expect(try await store.retainedAssetHashes() == Set(hashes.dropFirst()))
    note = try await store.undo(documentID: note.id, expectedRevision: note.revision)
    #expect(try await store.retainedAssetHashes() == Set(hashes.dropFirst()))
    note = try await store.execute([.rename("branch")], documentID: note.id, expectedRevision: note.revision)
    #expect(try await store.retainedAssetHashes() == Set(hashes[1...2]))
    try await store.close()
}

@Test func deltasPreserveLargeIntegerMetadataAndFormatting() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    var original = CanvasDocument(title: "Precision")
    let asset = Asset(hash: String(repeating: "a", count: 64), mediaType: "application/octet-stream", byteCount: Int64.max)
    var block = CanvasBlock(content: .text(.init(runs: [TextRun("e\u{301} 👩🏽‍💻", style: .init(fontSize: 17.25, bold: true))])))
    original.assets = [asset]; original.blocks = [block]
    try await store.create(original)
    block.style = .init(italic: true)
    let edited = try await store.execute([.replaceBlock(block)], documentID: original.id, expectedRevision: 0)
    let undone = try await store.undo(documentID: original.id, expectedRevision: edited.revision)
    #expect(undone.assets == original.assets)
    #expect(undone.blocks == original.blocks)
    try await store.close()
}

@Test func committedOperationCanReplayAfterCrashWithoutDuplicatingHistory() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let note = try await store.create(.init(title: "Before"))
    let operation = UUID()
    let saved = try await store.execute([.rename("After")], documentID: note.id, expectedRevision: 0, operationID: operation)
    try await store.close()
    let reopened = try SQLiteStore(url: fixture.url)
    let replayed = try await reopened.execute([.rename("After")], documentID: note.id, expectedRevision: 0, operationID: operation)
    #expect(replayed == saved)
    #expect(try await reopened.historyState(documentID: note.id).retainedEntries == 1)
    await #expect(throws: DocumentError.self) { try await reopened.execute([.rename("Different")], documentID: note.id, expectedRevision: 0, operationID: operation) }
    try await reopened.acknowledgeOperation(operation)
    try await reopened.close()
}

@Test @MainActor func journalSurvivesRestartAndRejectsCorruption() throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let url = fixture.directory.appendingPathComponent("pending.json")
    let journal = try PendingEditJournal(url: url)
    let edit = PendingEdit(documentID: UUID(), expectedRevision: 7, commands: [.rename("Recovered")])
    try journal.append(edit)
    let restored = try PendingEditJournal(url: url)
    #expect(restored.entries == [edit])
    try restored.removeFirst(edit.id)
    #expect(try PendingEditJournal(url: url).entries.isEmpty)
    try Data("invalid".utf8).write(to: url)
    #expect(throws: (any Error).self) { try PendingEditJournal(url: url) }
    #expect(try Data(contentsOf: url) == Data("invalid".utf8))
}
