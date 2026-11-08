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
