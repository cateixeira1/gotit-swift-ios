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
}
