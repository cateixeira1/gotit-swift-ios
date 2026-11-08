import Testing
import Foundation
import GotItDomain
@testable import GotItCanvas

private func sample(_ points: [(Double, Double)], times: [Double]? = nil, start: Double = 100, release: Double? = nil) -> InkSample {
    let times = times ?? points.indices.map { Double($0) * 0.02 }
    return InkSample(points: points.map { CanvasPoint(x: $0.0, y: $0.1) }, times: times, startedAt: start,
                     releasedAt: release ?? start + (times.last ?? 0) + 0.02)
}

@Test func tapsAreShortAndStillStrokesAreNot() {
    let tap = sample([(100, 100), (101, 101), (102, 100)], times: [0, 0.04, 0.08])
    #expect(InkIntent.isTap(tap, screenScale: 0.62))
    // A short letter stroke at the iPhone's fit-to-width zoom is not a tap.
    let stroke = sample([(100, 100), (108, 112), (118, 126)], times: [0, 0.05, 0.1])
    #expect(!InkIntent.isTap(stroke, screenScale: 0.62))
    // A long press is not a tap either.
    #expect(!InkIntent.isTap(sample([(100, 100), (101, 100)], times: [0, 0.6]), screenScale: 0.62))
}

@Test func holdingAtTheEndIsMeasuredFromTheLastMovement() {
    // Moves for 0.3 s, then rests; released 0.5 s after the last movement.
    let moving = (0..<16).map { (Double($0) * 10, 0.0) }
    let held = sample(moving, times: (0..<16).map { Double($0) * 0.02 }, start: 10, release: 10 + 0.3 + 0.5)
    #expect(abs(InkIntent.holdDuration(held, screenScale: 1) - 0.5) < 0.03)
    let quick = sample(moving, times: (0..<16).map { Double($0) * 0.02 }, start: 10, release: 10 + 0.32)
    #expect(InkIntent.holdDuration(quick, screenScale: 1) < InkIntent.holdToSnap)
}

@Test func aDotRightAfterWritingIsPartOfTheWriting() {
    let letter = sample([(100, 100), (104, 150), (108, 160)], start: 50)
    let dot = sample([(105, 82), (105, 83)], times: [0, 0.05], start: 51)
    #expect(InkIntent.tapBelongsToWriting(dot, recent: [letter]))
    // Far away or long after: an intentional tap.
    #expect(!InkIntent.tapBelongsToWriting(sample([(400, 500), (400, 501)], times: [0, 0.05], start: 51), recent: [letter]))
    #expect(!InkIntent.tapBelongsToWriting(sample([(105, 82), (105, 83)], times: [0, 0.05], start: 60), recent: [letter]))
}

@Test func loopsBesideHandwritingAreLetters() {
    let o = LogicalRect(x: 200, y: 100, width: 50, height: 50)
    let previous = sample([(120, 100), (140, 150), (160, 105), (180, 150)])          // a "w" to the left
    #expect(InkIntent.isNextToWriting(o, neighbours: [previous]))
    let otherLine = sample([(120, 300), (140, 350), (160, 305), (180, 350)])
    #expect(!InkIntent.isNextToWriting(o, neighbours: [otherLine]))
    // Converted "o" followed at once by the next letter: revert to ink.
    let next = sample([(260, 105), (280, 150), (300, 110)], start: 101)
    #expect(InkIntent.continuesWriting(after: o, convertedAt: 100, with: next))
    // A small label beside a big box is not "the rest of the word".
    let box = LogicalRect(x: 200, y: 100, width: 220, height: 150)
    let label = sample([(440, 160), (450, 185), (460, 165)], start: 101)
    #expect(!InkIntent.continuesWriting(after: box, convertedAt: 100, with: label))
}

@Test func strokesThatTouchFormGroups() {
    let boxes = [LogicalRect(x: 0, y: 0, width: 50, height: 50), .init(x: 55, y: 0, width: 50, height: 50), .init(x: 400, y: 0, width: 50, height: 50)]
    #expect(InkIntent.groups(boxes, padding: 8) == [[0, 1], [2]])
}
