import XCTest
import GotItDomain
import GotItPersistence
@testable import GotItApp

/// Folders in the list: new notes go into the folder shown, notes move between folders, and
/// deleting a folder keeps its notes.
@MainActor
final class FolderTests: XCTestCase {
    func testNotesAreFiledInFoldersAndSurviveTheFolder() async throws {
        let model = AppModel()
        await model.start()
        model.currentFolder = nil
        defer { model.currentFolder = nil }
        let name = "Pasta \(UUID().uuidString.prefix(6))"
        await model.createFolder(named: name)
        let folder = try XCTUnwrap(model.folders.first { $0.name == name })
        XCTAssertTrue(model.subfolders(of: nil).contains { $0.id == folder.id })
        model.currentFolder = folder.id
        await model.createNote()
        let note = try XCTUnwrap(model.document)
        XCTAssertEqual(model.visibleSummaries.map(\.id), [note.id], "a new note goes into the folder shown")
        await model.createFolder(named: "Dentro")
        let inner = try XCTUnwrap(model.subfolders(of: folder.id).first)
        XCTAssertEqual(model.count(in: folder.id), 2)
        XCTAssertEqual(model.folderTree.first { $0.folder.id == inner.id }?.depth, (model.folderTree.first { $0.folder.id == folder.id }?.depth ?? 0) + 1)
        await model.moveDocument(note.id, to: inner.id)
        XCTAssertTrue(model.visibleSummaries.isEmpty)
        // A folder cannot go into its own subfolder.
        await model.moveFolder(folder.id, to: inner.id)
        XCTAssertNotNil(model.error); model.error = nil
        // Deleting the outer folder while it is shown: the list goes up, "Dentro" and the note stay.
        await model.deleteFolder(folder.id)
        XCTAssertNil(model.currentFolder)
        XCTAssertEqual(model.folder(inner.id)?.parentID, nil)
        XCTAssertEqual(model.summaries.first { $0.id == note.id }?.folderID, inner.id)
        await model.deleteFolder(inner.id)
        XCTAssertNil(model.summaries.first { $0.id == note.id }?.folderID)
        await model.moveToTrash(note.id)
        await model.deleteForever(note.id)
        XCTAssertNil(model.error)
    }

    /// A note dropped on another makes "Pasta N" holding both, in the folder shown; Teias too.
    func testDroppingANoteOnAnotherMakesANumberedFolder() async throws {
        let model = AppModel()
        await model.start()
        model.currentFolder = nil
        defer { model.currentFolder = nil }
        await model.createFolder(named: "Arrastar \(UUID().uuidString.prefix(6))")
        let place = try XCTUnwrap(model.folders.last)
        model.currentFolder = place.id
        await model.createNote(); let first = try XCTUnwrap(model.document)
        await model.createNote(); let second = try XCTUnwrap(model.document)
        let expected = model.genericFolderName
        let folder = try XCTUnwrap(await model.makeFolder(dropping: second.id, onto: first.id))
        XCTAssertEqual(folder.name, expected)
        XCTAssertEqual(folder.parentID, place.id)
        XCTAssertEqual(Set(model.summaries.filter { $0.folderID == folder.id }.map(\.id)), [first.id, second.id])
        XCTAssertTrue(model.recent(.note).isEmpty, "both left the folder shown")
        // The next one without a name gets the following number.
        let number = Int(expected.split(separator: " ").last ?? "") ?? 0
        XCTAssertEqual(model.genericFolderName, "Pasta \(number + 1)")
        await model.createWeb(); let web = try XCTUnwrap(model.document)
        try await Task.sleep(for: .milliseconds(30))
        await model.createWeb(); let other = try XCTUnwrap(model.document)
        XCTAssertEqual(model.recent(.web).first?.id, other.id, "most recent first")
        let webs = try XCTUnwrap(await model.makeFolder(dropping: web.id, onto: other.id))
        XCTAssertEqual(webs.name, "Pasta \(number + 1)")
        XCTAssertNil(await model.makeFolder(dropping: web.id, onto: web.id))
        await model.deleteFolder(place.id)
        await model.deleteFolder(folder.id)
        await model.deleteFolder(webs.id)
        for id in [first.id, second.id, web.id, other.id] { await model.moveToTrash(id); await model.deleteForever(id) }
        XCTAssertNil(model.error)
    }
}
