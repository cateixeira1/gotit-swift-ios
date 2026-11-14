import Foundation
import Testing
@testable import GotItDomain

private let heading = NamedStyle.builtIn.first { $0.id == "heading1" }!
private let body = NamedStyle.builtIn.first { $0.id == "body" }!

private func plain(_ rich: RichText, styled id: String) -> String {
    rich.runs.filter { $0.style.namedStyle == id }.map(\.text).joined()
}

@Test func caretAppliesStyleToItsWholeParagraphOnly() {
    let text = RichText("Primeiro\nSegundo parágrafo\nTerceiro")
    let caret = "Primeiro\nSeg".utf16.count
    let styled = text.applyingNamedStyle(heading, utf16Range: caret..<caret)
    #expect(styled.plainText == text.plainText)
    #expect(plain(styled, styled: "heading1") == "Segundo parágrafo\n")
    #expect(styled.runs.first(where: { $0.style.namedStyle == "heading1" })?.style.fontSize == 24)
}

@Test func selectionAcrossParagraphsStylesEachTouchedParagraph() {
    let text = RichText("A1\nB2\nC3")
    let start = 1, end = "A1\nB".utf16.count
    let styled = text.applyingNamedStyle(heading, utf16Range: start..<end)
    #expect(plain(styled, styled: "heading1") == "A1\nB2\n")
    #expect(styled.runs.last?.text == "C3" && styled.runs.last?.style.namedStyle == nil)
}

@Test func switchingStylesReplacesEveryControlledAttribute() {
    let styled = RichText("Linha").applyingNamedStyle(heading, utf16Range: 0..<0).applyingNamedStyle(body, utf16Range: 0..<0)
    let style = styled.runs[0].style
    #expect(style.namedStyle == "body" && style.bold == false && style.fontSize == 18)
}

@Test func emojiOffsetsAndEmptyTextAreHandled() {
    let text = RichText("👍🏽 ok\nfim")
    let styled = text.applyingNamedStyle(heading, utf16Range: 2..<2)
    #expect(plain(styled, styled: "heading1") == "👍🏽 ok\n")
    let empty = RichText("").applyingNamedStyle(heading, utf16Range: 0..<0)
    #expect(empty.runs.first?.style.namedStyle == "heading1")
}

@Test func redefiningAStyleUpdatesTaggedTextAndKeepsManualOverrides() throws {
    var document = CanvasDocument(title: "Estilos")
    let tagged = RichText("x").applyingNamedStyle(heading, utf16Range: 0..<0).runs[0].style
    var red = tagged; red.foreground = "#FF0000"   // the user colours the first heading by hand
    let rich = RichText(runs: [TextRun("Título manual\n", style: red), TextRun("Outro título", style: tagged)])
    let block = CanvasBlock(content: .text(rich))
    let untouched = CanvasBlock(order: 1, content: .text(RichText("Sem estilo")))
    document = try CommandEngine.applying([.insertBlock(block), .insertBlock(untouched)], to: document)

    var bigger = heading; bigger.style.fontSize = 32; bigger.style.foreground = "#2563EB"
    let commands = try document.redefiningNamedStyle(bigger)
    #expect(commands.count == 2)   // definitions + the one tagged block
    let updated = try CommandEngine.applying(commands, to: document)
    #expect(updated.namedStyle("heading1")?.style.fontSize == 32)
    guard case .text(let result) = updated.blocks.first(where: { $0.id == block.id })?.content else { Issue.record("text"); return }
    #expect(result.runs.allSatisfy { $0.style.fontSize == 32 })
    #expect(result.runs.first?.style.foreground == "#FF0000")            // manual colour kept
    #expect(result.runs.contains { $0.style.foreground == "#2563EB" })   // default colour followed
    #expect(updated.blocks.first(where: { $0.id == untouched.id }) == untouched)
    // Round trip through JSON, as persistence does.
    #expect(try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(updated)) == updated)
}

@Test func namedStylesAreValidatedAndOptionalInOldDocuments() throws {
    let document = CanvasDocument(title: "Velho")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
    json.removeValue(forKey: "namedStyles")
    let decoded = try JSONDecoder().decode(CanvasDocument.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.namedStyles.isEmpty && decoded.effectiveNamedStyles.count == NamedStyle.builtIn.count)
    let duplicate = NamedStyle(id: "x", name: "X", style: .init())
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.setNamedStyles([duplicate, duplicate])], to: document) }
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.setNamedStyles([.init(id: "y", name: " ", style: .init())])], to: document) }
    #expect(throws: DocumentError.self) { try document.redefiningNamedStyle(.init(id: "missing", name: "M", style: .init())) }
    let custom = NamedStyle(id: "legal", name: "Cláusula", style: .init(fontSize: 16))
    let withCustom = try CommandEngine.applying([.setNamedStyles([custom])], to: document)
    #expect(withCustom.effectiveNamedStyles.last == custom)
}

@Test func redefiningAStyleMarksItsStoriesForReflow() throws {
    var document = CanvasDocument(title: "Reflow")
    var block = CanvasBlock(content: .text(RichText("Cabeçalho").applyingNamedStyle(heading, utf16Range: 0..<0)))
    block.textFlowID = block.id
    document = try CommandEngine.applying([.insertBlock(block)], to: document)
    var bigger = heading; bigger.style.fontSize = 40
    let updated = try CommandEngine.applying(try document.redefiningNamedStyle(bigger), to: document)
    #expect(updated.storiesWithTextChanges(since: document) == [block.id])
    #expect(updated.storiesWithTextChanges(since: updated).isEmpty)
}
