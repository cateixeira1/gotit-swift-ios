import XCTest
import UIKit
import GotItDomain
import GotItPersistence
@testable import GotItCanvasUI
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

    /// A link to another note opens it from the text's menu, and the other note lists who cites it.
    func testLinksBetweenNotesOpenAndAreListedAsBacklinks() async throws {
        let model = AppModel()
        await model.start()
        model.currentFolder = nil
        await model.createNote()
        let target = try XCTUnwrap(model.document)
        await model.createNote()
        let source = try XCTUnwrap(model.document)
        let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 80, y: 80, width: 300, height: 60)), content: .text(RichText(runs: [
            TextRun("ver "), TextRun("laudo", style: .init(link: NoteLinks.url(for: target.id))),
        ])))
        model.enqueue([.insertBlock(block)], pageID: source.pages[0].id, documentID: source.id)
        while model.isSaving { try await Task.sleep(for: .milliseconds(20)) }
        let cited = await model.backlinks(to: target.id)
        XCTAssertEqual(cited.map(\.id), [source.id])
        // In the editor, the text's menu on the link offers to open the note.
        var opened: UUID?
        let page = try XCTUnwrap(model.document)
        let controller = CanvasViewController(configuration: CanvasEditor(document: page,
            note: { $0 == target.id ? NoteCardPresentation(title: "Laudo", createdAt: Date()) : nil },
            onCommands: { _ in }, onOpenNote: { opened = $0 }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let text = try XCTUnwrap(Self.textViews(in: controller.view).first { $0.text == "ver laudo" })
        XCTAssertEqual(controller.linkedNote(in: text, at: NSRange(location: 6, length: 0)), target.id)
        XCTAssertNil(controller.linkedNote(in: text, at: NSRange(location: 1, length: 0)))
        let menu = try XCTUnwrap(controller.textView(text, editMenuForTextIn: NSRange(location: 6, length: 0), suggestedActions: []))
        let action = try XCTUnwrap(menu.children.first as? UIAction)
        XCTAssertEqual(action.title, "Abrir “Laudo”")
        XCTAssertNil(opened, "opens only when chosen")
        for id in [source.id, target.id] { await model.moveToTrash(id); await model.deleteForever(id) }
        XCTAssertNil(model.error)
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
    }
}
