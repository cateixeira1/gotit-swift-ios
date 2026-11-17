import Testing
import Foundation
import GotItDomain
@testable import GotItCanvas

private func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ content: BlockContent = .shape(.init(kind: .rectangle)), order: Int) -> CanvasBlock {
    CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(x: x, y: y, width: w, height: h)), content: content)
}

@Test func anEmptyPageTakesTheTopLeftCorner() {
    let spot = Placement.firstFreeSpot(width: 120, height: 120, on: CanvasDocument(title: "P"))
    #expect(spot == CanvasPoint(x: 24, y: 24))
}

@Test func newObjectsGoBesideOrBelowWhatIsThereWithoutOverlapping() {
    var page = CanvasDocument(title: "P")
    page.blocks = [block(24, 24, 300, 200, order: 0)]
    // Room to the right of the first block on the same row.
    #expect(Placement.firstFreeSpot(width: 120, height: 120, on: page) == CanvasPoint(x: 24 + 300 + 8, y: 24))
    // Too wide for the row: below it.
    #expect(Placement.firstFreeSpot(width: 400, height: 120, on: page) == CanvasPoint(x: 24, y: 24 + 200 + 8))
}

@Test func emptyTextBoxesAndTheDrawingLayerAreFreeSpace() {
    var page = CanvasDocument(title: "P")
    page.blocks = [block(24, 24, 540, 44, .text(RichText("")), order: 0),
                   block(0, 0, page.canvas.size.width, page.canvas.size.height, .drawing(.init(hash: "h")), order: 1)]
    #expect(Placement.firstFreeSpot(width: 120, height: 120, on: page) == CanvasPoint(x: 24, y: 24))
    page.blocks[0].content = .text(RichText("Título"))
    #expect(Placement.firstFreeSpot(width: 120, height: 120, on: page) == CanvasPoint(x: 24, y: 24 + 44 + 8))
}

@Test func aFullPageStillGetsTheObjectAtTheCorner() {
    var page = CanvasDocument(title: "P")
    page.blocks = [block(0, 0, page.canvas.size.width, page.canvas.size.height, .text(RichText("cheia")), order: 0)]
    #expect(Placement.firstFreeSpot(width: 120, height: 120, on: page) == CanvasPoint(x: 24, y: 24))
}

@Test func aTranscriptGoesRightThenLeftThenBelowThenAbove() throws {
    func page(_ objects: [LogicalRect]) throws -> CanvasDocument {
        var document = CanvasDocument(title: "Lado")
        for (index, frame) in objects.enumerated() {
            var block = CanvasBlock(layout: .init(mode: .absolute, frame: frame), content: .shape(.init(kind: .rectangle)))
            block.order = index
            document = try CommandEngine.applying([.insertBlock(block)], to: document)
        }
        return document
    }
    let audio = LogicalRect(x: 200, y: 300, width: 160, height: 60)
    // Room on the right.
    #expect(Placement.beside(audio, width: 150, height: 100, on: try page([audio])) == CanvasPoint(x: 372, y: 300))
    // Something on the right: left.
    #expect(Placement.beside(audio, width: 150, height: 100, on: try page([audio, .init(x: 380, y: 280, width: 100, height: 100)])) == CanvasPoint(x: 38, y: 300))
    // Both sides taken: below.
    let both = try page([audio, .init(x: 380, y: 280, width: 100, height: 100), .init(x: 20, y: 280, width: 150, height: 100)])
    #expect(Placement.beside(audio, width: 150, height: 100, on: both) == CanvasPoint(x: 200, y: 372))
    // Sides and below taken: above.
    let three = try page([audio, .init(x: 380, y: 280, width: 100, height: 100), .init(x: 20, y: 280, width: 150, height: 100), .init(x: 150, y: 380, width: 300, height: 200)])
    #expect(Placement.beside(audio, width: 150, height: 100, on: three) == CanvasPoint(x: 200, y: 188))
    // Too wide for any side: below, pulled back onto the page.
    let edge = LogicalRect(x: 400, y: 100, width: 160, height: 60)
    #expect(Placement.beside(edge, width: 420, height: 100, on: try page([edge])) == CanvasPoint(x: CanvasSize.a4.width - 428, y: 172))
}
