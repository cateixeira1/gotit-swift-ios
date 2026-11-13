import Foundation
import Testing
@testable import GotItDomain

@Test func stylesCascadeAndExplicitFalseOverrides() throws {
    var document = CanvasDocument(title: "Styles", defaultStyle: .init(fontSize: 18, bold: true, foreground: "#112233"))
    let group = CanvasBlock(style: .init(fontSize: 24), content: .container)
    let child = CanvasBlock(parentID: group.id, style: .init(bold: false), content: .text(RichText("Hello")))
    document.blocks = [child, group]
    try DocumentValidator.validate(document)
    let style = try document.resolvedStyle(for: child.id)
    #expect(style.fontSize == 24)
    #expect(style.bold == false)
    #expect(style.foreground == "#112233")
    #expect(document.children().map(\.id) == [group.id])
}

@Test func unicodeAndRunsRoundTrip() throws {
    let text = RichText(runs: [TextRun("Olá 👨‍👩‍👧‍👦 e\u{301}\n\0", style: .init(bold: true)), TextRun("漢字", style: .init(italic: true))])
    let data = try JSONEncoder().encode(text)
    #expect(try JSONDecoder().decode(RichText.self, from: data) == text)
    #expect(text.plainText == "Olá 👨‍👩‍👧‍👦 e\u{301}\n\0漢字")
}

@Test func batchReordersSiblingsAtomically() throws {
    var document = CanvasDocument(title: "Order")
    var first = CanvasBlock(order: 0, content: .text(RichText("A")))
    var second = CanvasBlock(order: 1, content: .text(RichText("B")))
    document.blocks = [first, second]
    first.order = 1; second.order = 0
    let reordered = try CommandEngine.applying([.replaceBlock(first), .replaceBlock(second)], to: document)
    #expect(reordered.children().map(\.id) == [second.id, first.id])
    #expect(document.blocks[0].order == 0)
}

@Test func deletesSubtreeAndConnectedRelations() throws {
    var document = CanvasDocument(title: "Tree")
    let root = CanvasBlock(content: .container)
    let child = CanvasBlock(parentID: root.id, content: .text(RichText("Child")))
    let other = CanvasBlock(order: 1, content: .text(RichText("Keep")))
    document.blocks = [root, child, other]
    document.relations = [.init(sourceID: child.id, targetID: other.id, kind: .connector)]
    let result = try CommandEngine.applying([.removeSubtree(root.id)], to: document)
    #expect(result.blocks == [other])
    #expect(result.relations.isEmpty)
}

@Test func rejectsParentAndAnchorCycles() {
    var document = CanvasDocument(title: "Cycles")
    var root = CanvasBlock(content: .container)
    let child = CanvasBlock(parentID: root.id, content: .container)
    root.layout = .init(mode: .anchored, anchorID: child.id)
    document.blocks = [root, child]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
    root.layout = .init()
    root.parentID = child.id
    document.blocks = [root, child]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
}

@Test func rejectsDuplicateIDsOrdersAndMissingParents() {
    var document = CanvasDocument(title: "Invalid")
    let block = CanvasBlock(content: .container)
    document.blocks = [block, block]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
    document.blocks = [block, CanvasBlock(content: .container)]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
    document.blocks = [CanvasBlock(parentID: UUID(), content: .container)]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
}

@Test(arguments: [Double.nan, Double.infinity, -1.0])
func rejectsInvalidDimensions(_ width: Double) {
    var document = CanvasDocument(title: "Frame")
    document.blocks = [CanvasBlock(layout: .init(frame: .init(width: width)), content: .container)]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
}

@Test func requiresAssetsAndValidStyles() {
    var document = CanvasDocument(title: "Assets")
    document.blocks = [CanvasBlock(content: .image(.init(hash: String(repeating: "a", count: 64))))]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
    document.blocks = []
    document.defaultStyle.fontSize = 0
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
    document.defaultStyle = .init(background: "red")
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(document) }
}

@Test func invalidBatchDoesNotMutateOriginal() {
    let document = CanvasDocument(title: "Original")
    #expect(throws: DocumentError.self) {
        try CommandEngine.applying([.rename("Changed"), .removeSubtree(UUID())], to: document)
    }
    #expect(document.title == "Original")
}

@Test func removingAnAnchorRequiresExplicitRepair() throws {
    var document = CanvasDocument(title: "Anchor")
    let anchor = CanvasBlock(content: .container)
    var anchored = CanvasBlock(order: 1, layout: .init(mode: .anchored, anchorID: anchor.id), content: .text(RichText("Note")))
    document.blocks = [anchor, anchored]
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.removeSubtree(anchor.id)], to: document) }
    anchored.layout = .init(mode: .absolute)
    let result = try CommandEngine.applying([.removeSubtree(anchor.id), .replaceBlock(anchored)], to: document)
    #expect(result.blocks == [anchored])
}

@Test func deepTreeValidationDoesNotUseRecursion() throws {
    var document = CanvasDocument(title: "Deep")
    var parent: UUID?
    for _ in 0..<5_000 {
        let block = CanvasBlock(parentID: parent, content: .container)
        document.blocks.append(block)
        parent = block.id
    }
    try DocumentValidator.validate(document)
    #expect(try document.resolvedStyle(for: #require(parent)) == .init())
}

@Test func drawingPartsMustBeRegisteredAndKeepTheirAssetsInUse() throws {
    var document = CanvasDocument(title: "Partes")
    let base = Asset(hash: String(repeating: "a", count: 64), mediaType: "application/x-pencilkit", byteCount: 10)
    let part = Asset(hash: String(repeating: "b", count: 64), mediaType: "application/x-pencilkit", byteCount: 4)
    let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: 100, height: 100)),
                            content: .drawing(.init(hash: base.hash, parts: [part.hash])))
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.registerAsset(base), .insertBlock(block)], to: document) }
    document = try CommandEngine.applying([.registerAsset(base), .registerAsset(part), .insertBlock(block)], to: document)
    #expect(block.content.assetHashes == [base.hash, part.hash])
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.unregisterAsset(part.hash)], to: document) }
    // Older documents decode with no parts.
    let old = try JSONDecoder().decode(AssetReference.self, from: Data(#"{"hash":"x"}"#.utf8))
    #expect(old.parts == nil); #expect(old.allHashes == ["x"])
}

@Test func searchTextCoversTitleTextTablesAndCaptionsAndOnlyWhatChanged() throws {
    var note = CanvasDocument(title: "Nota")
    let text = CanvasBlock(order: 0, content: .text(RichText("olá")))
    let image = CanvasBlock(order: 1, layout: .init(mode: .absolute), content: .image(AssetReference(hash: String(repeating: "a", count: 64), caption: "Raio-X")))
    let empty = CanvasBlock(order: 2, content: .text(RichText("  ")))
    note.assets = [Asset(hash: String(repeating: "a", count: 64), mediaType: "image/png", byteCount: 1)]
    note.blocks = [text, image, empty]
    let entries = SearchText.entries(note)
    #expect(entries.map(\.kind) == [.title, .text, .caption])
    var changed = note
    changed.blocks[0].content = .text(RichText("olá mundo"))
    let change = SearchText.changes(from: note, to: changed)
    #expect(change.removed == [text.id] && change.written.map(\.blockID) == [text.id])
    #expect(SearchText.changes(from: note, to: note).written.isEmpty)
    #expect(SearchText.query("Ação, 2026!") == "\"Ação\"* \"2026\"*")
    #expect(SearchText.query(" \"; ") == nil)
    #expect(SearchText.firstMatch(of: "acao", in: "Uma Ação aqui") == NSRange(location: 4, length: 4))
}

@Test func noteLinksNameNotesByIdentifier() throws {
    let other = UUID()
    #expect(NoteLinks.target(of: NoteLinks.url(for: other)) == other)
    #expect(NoteLinks.target(of: "GOTIT://nota/" + other.uuidString) == other)
    #expect(NoteLinks.target(of: "https://exemplo.com") == nil && NoteLinks.target(of: nil) == nil)
    var note = CanvasDocument(title: "N")
    var table = CanvasTable(rows: 1, columns: 1, width: 100)
    let third = UUID()
    table.cells[0][0].text = RichText(runs: [TextRun("x", style: .init(link: NoteLinks.url(for: third)))])
    note.blocks = [CanvasBlock(order: 0, content: .text(RichText(runs: [TextRun("a", style: .init(link: NoteLinks.url(for: other))),
                                                                       TextRun("eu", style: .init(link: NoteLinks.url(for: note.id)))]))),
                   CanvasBlock(order: 1, layout: .init(mode: .absolute), content: .table(table))]
    #expect(NoteLinks.targets(in: note) == [other, third], "a link to itself is not a reference")
}
