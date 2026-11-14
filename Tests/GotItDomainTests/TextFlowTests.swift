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

private func shape(on page: UUID, x: Double = 10) -> CanvasBlock {
    CanvasBlock(order: 10, layout: .init(mode: .absolute, frame: .init(x: x, y: 20, width: 100, height: 100)),
                content: .shape(Shape(kind: .rectangle)), pageID: page)
}

@Test func movingInsertingOrRemovingAnObstacleAffectsOnlyStoriesOnThatPage() throws {
    let (base, blocks) = try storyDocument(["um", "dois"])
    let secondPage = try #require(base.pageAssignments()[blocks[1].id])
    let story = blocks[0].id
    let obstacle = shape(on: secondPage)

    let inserted = try CommandEngine.applying([.insertBlock(obstacle)], to: base)
    #expect(inserted.storiesAffectedByObstacleChanges(since: base) == [story])

    var moved = obstacle; moved.layout.frame.x = 300
    let afterMove = try CommandEngine.applying([.replaceBlock(moved)], to: inserted)
    #expect(afterMove.storiesAffectedByObstacleChanges(since: inserted) == [story])

    var rewrapped = obstacle; rewrapped.presentation = ObjectPresentation(wrap: .none)
    let afterRewrap = try CommandEngine.applying([.replaceBlock(rewrapped)], to: inserted)
    #expect(afterRewrap.storiesAffectedByObstacleChanges(since: inserted) == [story])

    let removed = try CommandEngine.applying([.removeSubtree(obstacle.id)], to: inserted)
    #expect(removed.storiesAffectedByObstacleChanges(since: inserted) == [story])
}

@Test func textEditsDrawingsAndUnchangedObstaclesDoNotTriggerReflow() throws {
    let (base, blocks) = try storyDocument(["um", "dois"])
    let page = try #require(base.pageAssignments()[blocks[1].id])
    let obstacle = shape(on: page)
    let withObstacle = try CommandEngine.applying([.insertBlock(obstacle)], to: base)

    var edited = blocks[0]; edited.content = .text(RichText("um texto novo"))
    let afterText = try CommandEngine.applying([.replaceBlock(edited)], to: withObstacle)
    #expect(afterText.storiesAffectedByObstacleChanges(since: withObstacle).isEmpty)

    let inkHash = String(repeating: "a", count: 64)
    let ink = CanvasBlock(order: 11, layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: 50, height: 50)),
                          content: .drawing(AssetReference(hash: inkHash)), pageID: page)
    var withAsset = withObstacle
    withAsset.assets.append(Asset(hash: inkHash, mediaType: "application/x-pencilkit", byteCount: 1))
    let afterInk = try CommandEngine.applying([.insertBlock(ink)], to: withAsset)
    #expect(afterInk.storiesAffectedByObstacleChanges(since: withAsset).isEmpty)

    #expect(withObstacle.storiesAffectedByObstacleChanges(since: withObstacle).isEmpty)
}

@Test func canvasWideWrappingDefaultAffectsEveryStory() throws {
    let (base, blocks) = try storyDocument(["um", "dois"])
    var settings = base.canvas; settings.textAvoidsObjects.toggle()
    let changed = try CommandEngine.applying([.setCanvasSettings(settings)], to: base)
    #expect(changed.storiesAffectedByObstacleChanges(since: base) == [blocks[0].id])
}

@Test func obstacleOnAnotherPageLeavesTheStoryAlone() throws {
    let (base, blocks) = try storyDocument(["um", "dois"])
    let lonePage = CanvasPage(title: "Outra")
    let withPage = try CommandEngine.applying([.appendPage(lonePage)], to: base)
    let elsewhere = try CommandEngine.applying([.insertBlock(shape(on: lonePage.id))], to: withPage)
    #expect(elsewhere.storiesAffectedByObstacleChanges(since: withPage).isEmpty)
    #expect(blocks.count == 2)
}

@Test func resizingAStoryTextBoxAffectsItsStoryButTypingDoesNot() throws {
    let (base, blocks) = try storyDocument(["um", "dois"])
    var resized = blocks[1]; resized.layout.frame.width += 50
    let afterResize = try CommandEngine.applying([.replaceBlock(resized)], to: base)
    #expect(afterResize.storiesAffectedByObstacleChanges(since: base) == [blocks[0].id])
    var typed = blocks[1]; typed.content = .text(RichText("dois e mais"))
    let afterTyping = try CommandEngine.applying([.replaceBlock(typed)], to: base)
    #expect(afterTyping.storiesAffectedByObstacleChanges(since: base).isEmpty)
}
