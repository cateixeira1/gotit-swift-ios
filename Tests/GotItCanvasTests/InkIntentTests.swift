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

private func outline(_ corners: [(Double, Double)], start: Double = 100) -> InkSample {
    var points: [(Double, Double)] = []
    for (a, b) in zip(corners, corners.dropFirst()) {
        for step in 0..<12 { let t = Double(step) / 12; points.append((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)) }
    }
    points.append(corners.last!)
    return sample(points, start: start)
}

@Test func aBoxBesideDrawnInSeveralStrokesIsNotWriting() {
    // The candidate (a circle) and, on the same line, a box drawn as "Γ" + "⅃".
    let circle = LogicalRect(x: 0, y: 0, width: 120, height: 120)
    let top = outline([(150, 120), (150, 0), (300, 0)])
    let bottom = outline([(300, 0), (300, 120), (150, 120)], start: 101)
    #expect(InkIntent.isNextToWriting(circle, neighbours: [top, bottom]))                 // stroke by stroke: looks like writing
    #expect(!InkIntent.isNextToWriting(circle, neighbourGroups: [[top, bottom]]))         // together: a figure
    // Real writing beside it still counts.
    let word = sample([(150, 10), (170, 110), (190, 20), (210, 110), (230, 15)])
    #expect(InkIntent.isNextToWriting(circle, neighbourGroups: [[word]]))
}

@Test func whatFollowsAFigureDecidesWhetherItStays() {
    // A second box beside the first, even rough or only half drawn, keeps the first one.
    #expect(InkIntent.followerIsFigure([outline([(150, 0), (300, 4), (296, 120), (152, 118), (150, 6)])]))
    #expect(InkIntent.followerIsFigure([outline([(150, 120), (150, 0), (300, 0)]), outline([(300, 0), (300, 120), (150, 120)], start: 101)]))
    // A letter does not: the circle was an "o".
    #expect(!InkIntent.followerIsFigure([sample([(150, 10), (160, 110), (175, 60), (190, 110)])]))
}

@Test func linesFromFigureToFigureAreConnectorsButBoxSidesAreNot() {
    let left = outline([(0, 0), (100, 0), (100, 80), (0, 80), (0, 0)])
    let right = outline([(300, 0), (400, 0), (400, 80), (300, 80), (300, 0)], start: 101)
    // A slightly wavy line from the left box to the right box.
    let wave: [(Double, Double)] = (0...20).map { (i: Int) -> (Double, Double) in
        let x = 104 + Double(i) * 9.6
        return (x, 40 + 6 * sin(Double(i) / 3))
    }
    let line = sample(wave, start: 102)
    #expect(InkIntent.connectorStrokes([left, right, line], figures: [], padding: 8, tolerance: 20) == [2])
    // The same line between two shapes already on the page.
    let figures = [LogicalRect(x: 0, y: 0, width: 100, height: 80), .init(x: 300, y: 0, width: 100, height: 80)]
    #expect(InkIntent.connectorStrokes([line], figures: figures, padding: 8, tolerance: 20) == [0])
    // The sides of a box drawn in four strokes end on the same figure: not connectors.
    let sides = [outline([(0, 0), (200, 0)]), outline([(200, 0), (200, 120)], start: 101), outline([(200, 120), (0, 120)], start: 102), outline([(0, 120), (0, 0)], start: 103)]
    #expect(InkIntent.connectorStrokes(sides, figures: [], padding: 8, tolerance: 20).isEmpty)
    // A line ending in empty paper is not a connector.
    #expect(InkIntent.connectorStrokes([line], figures: [figures[0]], padding: 8, tolerance: 20).isEmpty)
}

@Test func aWavyLineBetweenTwoShapesBecomesAStraightConnector() throws {
    var document = CanvasDocument(title: "D")
    let a = CanvasBlock(order: 0, layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: 100, height: 80)), content: .shape(.init(kind: .rectangle)))
    let b = CanvasBlock(order: 1, layout: .init(mode: .absolute, frame: .init(x: 300, y: 10, width: 100, height: 80)), content: .shape(.init(kind: .ellipse)))
    document.blocks = [a, b]
    let wavy = (0...20).map { i in CanvasPoint(x: 96 + Double(i) * 10, y: 40 + 7 * sin(Double(i) / 3)) }
    #expect(ShapeRecognizer.isConnectorStroke(wavy))
    #expect(ShapeRecognizer.recognize([wavy], intent: .automatic)?.kind != .line)          // too wavy for a free line
    let line = RecognizedShape(kind: .line, frame: .init(x: 96, y: 33, width: 200, height: 14), originalPoints: wavy)
    let commands = try #require(try DiagramCommands.insert(line, in: document, stroke: "#FF0000", lineWidth: 3, allowFreeLines: false, connectionTolerance: 30))
    guard case .setRelation(let relation) = commands.first else { Issue.record("Expected a connector"); return }
    #expect(relation.sourceID == a.id); #expect(relation.targetID == b.id)
    #expect(relation.style?.color == "#FF0000")
    // Drawn as a straight segment between the two shapes, whatever the stroke looked like.
    let path = ConnectorGeometry.path(from: try #require(try CanvasLayoutEngine.frames(in: document)[a.id]),
                                      to: try #require(try CanvasLayoutEngine.frames(in: document)[b.id]), routing: .straight)
    #expect(path.count == 2)
    // A back-and-forth scribble is never a connector.
    #expect(!ShapeRecognizer.isConnectorStroke([.init(x: 100, y: 40), .init(x: 300, y: 40), .init(x: 120, y: 44), .init(x: 300, y: 48)]))
}
