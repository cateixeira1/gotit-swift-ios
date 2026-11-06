import Foundation
import Testing
@testable import GotItDomain

@Test func droppingLastCharacterKeepsEmojiAndCombiningSequencesWhole() {
    #expect(RichText("ab👍🏽").droppingLastCharacter().plainText == "ab")
    #expect(RichText("cafe\u{301}").droppingLastCharacter().plainText == "caf")
    #expect(RichText("a\n").droppingLastCharacter().plainText == "a")
    #expect(RichText("").droppingLastCharacter().plainText == "")
}

@Test func droppingLastCharacterRemovesEmptiedRunsAndKeepsStyles() {
    let bold = BlockStyle(fontSize: 30)
    let text = RichText(runs: [TextRun("plain"), TextRun("!", style: bold)])
    let shortened = text.droppingLastCharacter()
    #expect(shortened.runs.count == 1)
    #expect(shortened.plainText == "plain")
    // Trailing empty runs do not hide the real last character.
    let withEmpty = RichText(runs: [TextRun("xy"), TextRun("")]).droppingLastCharacter()
    #expect(withEmpty.plainText == "x")
}

@Test func utf16LengthMatchesNSRangeUnits() {
    #expect(RichText("ab👍🏽").utf16Length == 6)
    #expect((RichText("ab👍🏽").plainText as NSString).length == 6)
}

private func storyDocument(_ texts: [String]) throws -> (CanvasDocument, [CanvasBlock]) {
    var document = CanvasDocument(title: "Story")
    var blocks: [CanvasBlock] = []
    var story: UUID?
    for (index, text) in texts.enumerated() {
        var pageID = document.id
        if index > 0 {
            let page = CanvasPage(title: "Continuação", textFlowID: story)
            document = try CommandEngine.applying([.appendPage(page)], to: document)
            pageID = page.id
        }
        var block = CanvasBlock(order: index, content: .text(RichText(text)), pageID: pageID)
        if index == 0 { story = block.id }
        block.textFlowID = story
        blocks.append(block)
        document = try CommandEngine.applying([.insertBlock(block)], to: document)
    }
    return (document, blocks)
}

@Test func backspaceAtStartOfContinuationDeletesLastCharacterOfPreviousFragment() throws {
    let (document, blocks) = try storyDocument(["Primeira página 👍🏽", "segunda"])
    let merge = try #require(document.backspaceAcrossFragments(at: blocks[1].id))
    #expect(merge.replacement.id == blocks[0].id)
    guard case .text(let rich) = merge.replacement.content else { Issue.record("expected text"); return }
    #expect(rich.plainText == "Primeira página ")
    #expect(merge.caret == "Primeira página ".utf16.count)
    // The replacement is a valid edit of the real document.
    let edited = try CommandEngine.applying([.replaceBlock(merge.replacement)], to: document)
    #expect(edited.blocks.first(where: { $0.id == blocks[0].id })?.content == merge.replacement.content)
    #expect(edited.blocks.first(where: { $0.id == blocks[1].id })?.content == blocks[1].content)
}

@Test func backspaceAcrossFragmentsSkipsEmptyPagesAndStopsAtStoryStart() throws {
    let (document, blocks) = try storyDocument(["início", "", "fim"])
    let merge = try #require(document.backspaceAcrossFragments(at: blocks[2].id))
    #expect(merge.replacement.id == blocks[0].id)
    #expect(merge.caret == "iníci".utf16.count)
    #expect(document.backspaceAcrossFragments(at: blocks[0].id) == nil)
}

@Test func backspaceAcrossFragmentsIgnoresBlocksOutsideAStory() throws {
    var document = CanvasDocument(title: "Loose")
    let loose = CanvasBlock(order: 0, content: .text(RichText("solto")))
    document = try CommandEngine.applying([.insertBlock(loose)], to: document)
    #expect(document.backspaceAcrossFragments(at: loose.id) == nil)
    #expect(document.backspaceAcrossFragments(at: UUID()) == nil)
}

@Test func storyFragmentsFollowPageOrderNotInsertionOrder() throws {
    let (document, blocks) = try storyDocument(["um", "dois", "três"])
    var reordered = document
    reordered.blocks.reverse()
    #expect(reordered.textFlowFragments(story: blocks[0].id).map(\.id) == blocks.map(\.id))
}
