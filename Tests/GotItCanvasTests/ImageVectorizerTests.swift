import Foundation
import Testing
import GotItDomain
@testable import GotItCanvas

/// A white (or transparent) canvas with dark paint where `ink` says so.
private func picture(_ width: Int, _ height: Int, paper: UInt8 = 255, alpha: UInt8 = 255, ink: (Double, Double) -> Bool) -> RasterImage {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let i = (y * width + x) * 4
        if ink(Double(x) + 0.5, Double(y) + 0.5) { rgba[i] = 20; rgba[i + 1] = 30; rgba[i + 2] = 140; rgba[i + 3] = 255 }
        else { rgba[i] = paper; rgba[i + 1] = paper; rgba[i + 2] = paper; rgba[i + 3] = alpha }
    } }
    return RasterImage(width: width, height: height, rgba: rgba)
}

private func distance(_ p: CanvasPoint, _ x: Double, _ y: Double) -> Double { hypot(p.x - x, p.y - y) }

@Test func aThickStraightLineBecomesOneStrokeAlongItsMiddle() {
    let image = picture(120, 80) { x, y in x >= 10 && x <= 110 && abs(y - 40) <= 3 }
    let strokes = ImageVectorizer.trace(image)
    #expect(strokes.count == 1)
    guard let line = strokes.first else { return }
    let ends = [line.points.first!, line.points.last!].sorted { $0.x < $1.x }
    #expect(distance(ends[0], 13, 40) < 5 && distance(ends[1], 107, 40) < 5)
    #expect(line.points.allSatisfy { abs($0.y - 40) < 1.5 })
    #expect(abs(line.width - 7) < 2)
    #expect(line.color == "#141E8C")                    // the ink's own colour
    #expect(line.points.count <= 4, "a straight line needs few points")
}

@Test func aSlantedLineIsNotBrokenAtEveryStep() {
    let image = picture(120, 100) { x, y in
        // Distance to the segment (10,10)–(100,80), 2.5 px wide on each side.
        let dx = 90.0, dy = 70.0, t = max(0, min(1, ((x - 10) * dx + (y - 10) * dy) / (dx * dx + dy * dy)))
        return hypot(x - (10 + t * dx), y - (10 + t * dy)) <= 2.5
    }
    let strokes = ImageVectorizer.trace(image)
    #expect(strokes.count == 1)
    #expect(abs((strokes.first?.length ?? 0) - hypot(90, 70)) < 10)
}

@Test func aRingIsOneClosedStroke() {
    let image = picture(100, 100) { x, y in abs(hypot(x - 50, y - 50) - 30) <= 2 }
    let strokes = ImageVectorizer.trace(image)
    #expect(strokes.count == 1)
    guard let ring = strokes.first else { return }
    #expect(distance(ring.points.first!, ring.points.last!.x, ring.points.last!.y) < 2)
    #expect(abs(ring.length - 2 * .pi * 30) < 15)
    #expect(ring.points.allSatisfy { abs(hypot($0.x - 50, $0.y - 50) - 30) < 2.5 })
}

@Test func crossingLinesStayWholeAcrossTheCrossing() {
    let image = picture(100, 100) { x, y in (abs(y - 50) <= 2 && x >= 10 && x <= 90) || (abs(x - 50) <= 2 && y >= 10 && y <= 90) }
    let strokes = ImageVectorizer.trace(image)
    #expect(strokes.count == 2, "each line comes back whole, joined across the crossing")
    #expect(strokes.allSatisfy { abs($0.length - 78) < 8 })
}

@Test func dotsStayAndStrayPixelsGo() {
    let image = picture(60, 60) { x, y in hypot(x - 20, y - 20) <= 3 || (Int(x) == 45 && Int(y) == 45) }
    let strokes = ImageVectorizer.trace(image)
    #expect(strokes.count == 1)
    #expect(strokes.first.map { distance($0.points[0], 20, 20) < 2 } == true)
}

@Test func paperBecomesTransparentAndInkStays() {
    // Slightly grey, noisy paper; a dark mark in the middle.
    var image = picture(64, 64, paper: 236) { x, y in abs(x - 32) < 6 && abs(y - 32) < 6 }
    for i in stride(from: 0, to: image.rgba.count, by: 4) where image.rgba[i] > 200 { image.rgba[i] = UInt8(226 + (i / 4) % 20) }
    let cleaned = ImageVectorizer.removingPaper(image)
    #expect(cleaned.alpha(5 * 64 + 5) == 0)
    #expect(cleaned.alpha(32 * 64 + 32) == 255)
    #expect(cleaned.rgba[(32 * 64 + 32) * 4] == 20, "colours are untouched")
}

@Test func onATransparentBackgroundTheMarksAreFoundToo() {
    let image = picture(80, 60, paper: 0, alpha: 0) { x, y in abs(y - 30) <= 2 && x >= 10 && x <= 70 }
    let strokes = ImageVectorizer.trace(image)
    #expect(strokes.count == 1)
    #expect(ImageVectorizer.trace(picture(40, 40) { _, _ in false }).isEmpty)
}

@Test func aCornerIsNotJoinedStraightThrough() {
    // A "T": the stem meets the bar at a right angle, so the bar stays one stroke and the stem another.
    let image = picture(100, 100) { x, y in (abs(y - 20) <= 2 && x >= 10 && x <= 90) || (abs(x - 50) <= 2 && y >= 20 && y <= 90) }
    let strokes = ImageVectorizer.trace(image).sorted { $0.length > $1.length }
    #expect(strokes.count == 2)
    #expect(strokes.first.map { abs($0.length - 78) < 8 } == true)
}
