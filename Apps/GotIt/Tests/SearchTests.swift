import XCTest
import GotItDomain
import GotItPersistence
@testable import GotItApp

/// Search from the list: finds notes in any folder, ignoring accents, and opens them at the word.
@MainActor
final class SearchTests: XCTestCase {
    func testSearchFindsANoteAndOpensItAtTheWord() async throws {
        let model = AppModel()
        await model.start()
        model.currentFolder = nil
        defer { model.currentFolder = nil }
        let word = "Zebrafino\(Int.random(in: 1000...9999))"
        await model.createFolder(named: "Busca \(word)")
        let folder = try XCTUnwrap(model.folders.first { $0.name == "Busca \(word)" })
        model.currentFolder = folder.id
        await model.createNote()
        let note = try XCTUnwrap(model.document)
        model.currentFolder = nil
        var story = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 80, y: 80, width: 300, height: 44)), content: .text(.init("")))
        story.textFlowID = story.id
        model.enqueue([.insertBlock(story)], pageID: note.pages[0].id, documentID: note.id)
        story.content = .text(RichText("Reunião sobre a ação \(word) amanhã"))
        _ = model.editText(story, group: nil, selection: NSRange(location: 0, length: 0))
        while model.isSaving { try await Task.sleep(for: .milliseconds(20)) }
        // Found from the top level although it is in a folder, without accents, by the word's start.
        let results = await model.search("acao \(word.lowercased().prefix(8))")
        let result = try XCTUnwrap(results.first { $0.documentID == note.id })
        XCTAssertEqual(result.folder, "Busca \(word)")
        XCTAssertEqual(result.hit.blockID, story.id)
        XCTAssertTrue(NotesSidebar.highlighted(result.hit.snippet).characters.contains("ç"))
        XCTAssertFalse(String(NotesSidebar.highlighted(result.hit.snippet).characters).contains(SearchHit.markStart))
        await model.open(result, query: "acao")
        XCTAssertEqual(model.document?.id, note.id)
        XCTAssertTrue(model.revealPending)
        let focus = try XCTUnwrap(model.takeRevealFocus())
        XCTAssertEqual(focus.blockID, story.id)
        XCTAssertEqual(focus.range, NSRange(location: 16, length: 4), "the found word is selected")
        XCTAssertNil(model.takeRevealFocus(), "once")
        // In the Lixeira it is not found.
        await model.moveToTrash(note.id)
        let none = await model.search(word)
        XCTAssertTrue(none.isEmpty)
        await model.deleteForever(note.id)
        await model.deleteFolder(folder.id)
        XCTAssertNil(model.error)
    }
}
