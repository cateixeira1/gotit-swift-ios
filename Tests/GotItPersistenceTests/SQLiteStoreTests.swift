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

@Test func sqlFailureAfterDeletesRollsBackAllRowsAndHistory() async throws {
    let fixture = try DatabaseFixture(); defer { fixture.clean() }
    let store = try SQLiteStore(url: fixture.url)
    let original = try await store.create(multimediaDocument())
    let fault = try SQLiteConnection(path: fixture.url.path)
    try fault.script("CREATE TRIGGER fail_write BEFORE INSERT ON blocks BEGIN SELECT RAISE(ABORT, 'injected disk write failure'); END;")
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
    try fault.script("CREATE TRIGGER fail_undo BEFORE INSERT ON blocks BEGIN SELECT RAISE(ABORT, 'injected'); END;")
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
    #expect(try db.execute("PRAGMA user_version").first?.first?.int == 1)
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
