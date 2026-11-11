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

@Test func newAndMovedObjectsGoOnTopOfTheirPage() throws {
    let first = CanvasPage(title: "1"), second = CanvasPage(title: "2")
    var document = CanvasDocument(title: "Camadas"); document.pages = [first, second]
    func object(_ z: Int = 0) -> CanvasBlock {
        CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 10, y: 10, width: 50, height: 50), zIndex: z), content: .shape(.init(kind: .rectangle)))
    }
    var text = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: 200, height: 40), zIndex: 3), content: .text(.init("texto")))
    text.textFlowID = text.id
    document = try CommandEngine.applying(document.commands([.insertBlock(text)], on: first.id), to: document)
    let sticker = object(), later = object()
    document = try CommandEngine.applying(document.commands([.insertBlock(sticker), .insertBlock(later)], on: first.id), to: document)
    func z(_ id: UUID) -> Int { document.blocks.first { $0.id == id }!.layout.zIndex }
    #expect(z(text.id) == 1 && z(sticker.id) == 2 && z(later.id) == 3, "each new object above the last, text included")
    #expect(document.stackTop(on: first.id) == 3 && document.stackBottom(on: first.id) == 1)
    // Another page's stack is separate; an object moved there goes on top of it.
    let other = object(7)
    document = try CommandEngine.applying(document.commands([.insertBlock(other)], on: second.id), to: document)
    #expect(z(other.id) == 1)
    var moved = document.blocks.first { $0.id == sticker.id }!
    moved.pageID = second.id
    document = try CommandEngine.applying(document.commands([.replaceBlock(moved)], on: first.id), to: document)
    #expect(z(sticker.id) == 2)
    // Edits that stay on the page keep the stacking.
    var nudged = document.blocks.first { $0.id == later.id }!
    nudged.layout.frame.x = 30
    #expect(try document.commands([.replaceBlock(nudged)], on: first.id) == [.replaceBlock(nudged)])
    // Ties (old notes, all at 0) are broken by insertion order.
    var a = object(), b = object(); a.order = 2; b.order = 1
    #expect(CanvasBlock.stackedBelow(b, a) && !CanvasBlock.stackedBelow(a, b))
}

@Test func childrenArePaintedRightAboveTheirParent() throws {
    var document = CanvasDocument(title: "Ordem")
    let note = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: 200, height: 200), zIndex: 2), content: .shape(.init(kind: .stickyNote)))
    var label = CanvasBlock(parentID: note.id, layout: .init(mode: .absolute, frame: .init(x: 10, y: 10, width: 100, height: 40)), content: .text(.init("oi")))
    label.order = 0
    var cover = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 50, y: 50, width: 80, height: 80), zIndex: 5), content: .shape(.init(kind: .ellipse)))
    cover.order = 1
    var under = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: 80, height: 80), zIndex: 1), content: .shape(.init(kind: .rectangle)))
    under.order = 2
    var stuck = note; stuck.order = 3
    document.blocks = [cover, label, under, stuck]
    #expect(document.paintOrder().map(\.id) == [under.id, note.id, label.id, cover.id])
}
