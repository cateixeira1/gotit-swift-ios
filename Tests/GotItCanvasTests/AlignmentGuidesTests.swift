import Testing
import GotItDomain
@testable import GotItCanvas

@Test func middlesLineUpAndSnap() {
    let other = LogicalRect(x: 100, y: 100, width: 100, height: 60)        // middle (150, 130)
    let page = CanvasSize(width: 600, height: 800)
    // 4 pt to the right of the other's vertical middle, far from any horizontal one.
    let moving = LogicalRect(x: 124, y: 400, width: 60, height: 40)         // middle (154, 420)
    let snap = AlignmentGuides.snap(moving, to: [other], page: page)
    #expect(snap.offset == CanvasPoint(x: -4, y: 0))
    #expect(snap.lines == [.init(start: .init(x: 150, y: 100), end: .init(x: 150, y: 440))])
    // Both middles at once.
    let both = AlignmentGuides.snap(.init(x: 122, y: 113, width: 60, height: 40), to: [other], page: page)
    #expect(both.offset == CanvasPoint(x: -2, y: -3) && both.lines.count == 2)
    // The page's middle counts too.
    #expect(AlignmentGuides.snap(.init(x: 268, y: 600, width: 60, height: 40), to: [], page: page).offset == CanvasPoint(x: 2, y: 0))
    // Too far: nothing.
    #expect(AlignmentGuides.snap(.init(x: 140, y: 400, width: 60, height: 40), to: [other], page: page) == .none)
}
