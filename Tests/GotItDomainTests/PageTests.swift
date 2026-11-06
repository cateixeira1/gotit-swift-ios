import Foundation
import Testing
@testable import GotItDomain

@Test func legacyPagesDecodeDeterministically() throws {
    let document = CanvasDocument(title: "Legacy")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
    json.removeValue(forKey: "pages")
    let data = try JSONSerialization.data(withJSONObject: json)
    let first = try JSONDecoder().decode(CanvasDocument.self, from: data)
    let second = try JSONDecoder().decode(CanvasDocument.self, from: data)
    #expect(first.pages == second.pages)
    #expect(first.pages.first?.id == document.id)
}

@Test func pageProjectionIncludesChildrenAndRoutesNewRoots() throws {
    var document = CanvasDocument(title: "Two pages")
    let second = CanvasPage(title: "Página 2")
    let root = CanvasBlock(content: .container)
    let child = CanvasBlock(parentID: root.id, content: .text(.init("First")))
    document = try CommandEngine.applying([.insertBlock(root), .insertBlock(child), .appendPage(second)], to: document)
    let next = CanvasBlock(content: .text(.init("Second")))
    document = try CommandEngine.applying(document.commands([.insertBlock(next)], on: second.id), to: document)
    #expect(try document.pageDocument(document.id).blocks.map(\.id) == [root.id, child.id])
    #expect(try document.pageDocument(second.id).blocks.map(\.id) == [next.id])
    #expect(document.blocks.last?.order == 1)
    #expect(try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(document)) == document)
}

@Test func crossPageLinksAndMissingPagesAreRejected() throws {
    var document = CanvasDocument(title: "Pages")
    let second = CanvasPage(title: "Second")
    document.pages.append(second)
    let firstBlock = CanvasBlock(content: .container)
    let secondBlock = CanvasBlock(order: 1, content: .container, pageID: second.id)
    document.blocks = [firstBlock, secondBlock]
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.setRelation(.init(sourceID: firstBlock.id, targetID: secondBlock.id, kind: .connector))], to: document) }
    var child = CanvasBlock(parentID: firstBlock.id, content: .text(.init("Wrong page")), pageID: second.id)
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.insertBlock(child)], to: document) }
    child.pageID = UUID()
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.insertBlock(child)], to: document) }
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.appendPage(second)], to: document) }
}
