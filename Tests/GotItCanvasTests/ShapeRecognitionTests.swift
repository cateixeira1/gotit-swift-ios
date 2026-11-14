import Testing
import Foundation
import GotItDomain
@testable import GotItCanvas

/// Deterministic noise so failures reproduce.
private struct Noise {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1      // -1...1
    }
}

/// Polyline through `corners` (closed by repeating the first), with wobble and jitter like a finger.
private func handDrawn(_ corners: [CanvasPoint], seed: UInt64, jitter: Double = 1.5, bow: Double = 0.04,
                       overshoot: Double = 0, gap: Double = 0) -> [CanvasPoint] {
    var noise = Noise(state: seed)
    var points: [CanvasPoint] = []
    let loop = corners + [corners[0]]
    for i in 0..<(loop.count - 1) {
        let a = loop[i], b = loop[i + 1]
        let length = hypot(b.x - a.x, b.y - a.y)
        let normal = CanvasPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
        let curve = bow * length * noise.next()
        let steps = max(6, Int(length / 6))
        for step in 0..<steps {
            let t = Double(step) / Double(steps)
            let offset = curve * sin(.pi * t)
            points.append(.init(x: a.x + (b.x - a.x) * t + normal.x * offset + jitter * noise.next(),
                                y: a.y + (b.y - a.y) * t + normal.y * offset + jitter * noise.next()))
        }
    }
    // `gap`: length left open at the end, in points (segments are sampled about every 6 pt).
    if gap > 0 { points.removeLast(min(points.count - 10, Int(gap / 6))) }
    if overshoot > 0 {
        let extra = Int(Double(points.count) * overshoot)
        points += points.prefix(extra).map { .init(x: $0.x + 2, y: $0.y + 2) }
    }
    return points
}

private func ellipse(center: CanvasPoint, rx: Double, ry: Double, rotation: Double = 0, seed: UInt64,
                     sweep: Double = 2 * .pi, jitter: Double = 1.5) -> [CanvasPoint] {
    var noise = Noise(state: seed)
    return (0...80).map { i in
        let t = sweep * Double(i) / 80
        let wobble = 1 + 0.035 * noise.next()
        let x = rx * cos(t) * wobble, y = ry * sin(t) * wobble
        return .init(x: center.x + x * cos(rotation) - y * sin(rotation) + jitter * noise.next(),
                     y: center.y + x * sin(rotation) + y * cos(rotation) + jitter * noise.next())
    }
}

private func segment(_ a: CanvasPoint, _ b: CanvasPoint, seed: UInt64) -> [CanvasPoint] {
    var noise = Noise(state: seed)
    return (0...30).map { i in
        let t = Double(i) / 30
        return .init(x: a.x + (b.x - a.x) * t + 1.2 * noise.next(), y: a.y + (b.y - a.y) * t + 1.2 * noise.next())
    }
}

// MARK: Rough figures that must convert

@Test func crookedBoxesLikeTheDeviceScreenshotBecomeRectangles() throws {
    // Corners read from the photo the user sent (in screen pixels): skewed sides, uneven corners.
    let boxes: [[CanvasPoint]] = [
        [.init(x: 185, y: 568), .init(x: 336, y: 566), .init(x: 342, y: 697), .init(x: 185, y: 742)],
        [.init(x: 382, y: 625), .init(x: 520, y: 628), .init(x: 488, y: 750), .init(x: 398, y: 765)],
        [.init(x: 607, y: 620), .init(x: 803, y: 638), .init(x: 770, y: 775), .init(x: 600, y: 806)],
        [.init(x: 222, y: 1246), .init(x: 528, y: 1210), .init(x: 520, y: 1380), .init(x: 230, y: 1460)],
        [.init(x: 665, y: 1275), .init(x: 993, y: 1243), .init(x: 1014, y: 1385), .init(x: 665, y: 1440)],
        [.init(x: 188, y: 1600), .init(x: 490, y: 1555), .init(x: 480, y: 1750), .init(x: 188, y: 1790)],
        [.init(x: 400, y: 1805), .init(x: 625, y: 1797), .init(x: 646, y: 2030), .init(x: 452, y: 2090)],
    ]
    for (index, corners) in boxes.enumerated() {
        let stroke = handDrawn(corners, seed: UInt64(index + 1), overshoot: 0.06)
        let shape = try #require(ShapeRecognizer.recognize([stroke], intent: .automatic), "box \(index + 1)")
        #expect(shape.kind == .rectangle, "box \(index + 1)")
        #expect(abs(shape.rotationRadians) < 0.01, "box \(index + 1)")
    }
}

@Test func boxWithAGapOrDrawnInTwoStrokesBecomesARectangle() throws {
    let corners = [CanvasPoint(x: 0, y: 0), .init(x: 200, y: 6), .init(x: 196, y: 130), .init(x: 4, y: 124)]
    let open = handDrawn(corners, seed: 7, gap: 22)
    #expect(ShapeRecognizer.recognize([open], intent: .automatic)?.kind == .rectangle)
    // "Γ" then "⅃", the way many people draw a box.
    let first = segment(.init(x: 4, y: 124), .init(x: 0, y: 0), seed: 1) + segment(.init(x: 0, y: 0), .init(x: 200, y: 6), seed: 2)
    let second = segment(.init(x: 203, y: 2), .init(x: 196, y: 130), seed: 3) + segment(.init(x: 196, y: 130), .init(x: 8, y: 126), seed: 4)
    #expect(ShapeRecognizer.recognize([first, second], intent: .automatic)?.kind == .rectangle)
    // A "U" plus a separate lid (the second box in the photo).
    let cup = segment(.init(x: 0, y: 0), .init(x: 16, y: 140), seed: 5) + segment(.init(x: 16, y: 140), .init(x: 106, y: 125), seed: 6)
        + segment(.init(x: 106, y: 125), .init(x: 138, y: 3), seed: 8)
    let lid = segment(.init(x: 21, y: 0), .init(x: 138, y: 3), seed: 9)
    #expect(ShapeRecognizer.recognize([cup, lid], intent: .automatic)?.kind == .rectangle)
}

@Test func circlesEllipsesTrianglesAndDiamonds() throws {
    #expect(ShapeRecognizer.recognize([ellipse(center: .init(x: 100, y: 100), rx: 60, ry: 58, seed: 3)], intent: .automatic)?.kind == .ellipse)
    let wide = try #require(ShapeRecognizer.recognize([ellipse(center: .init(x: 200, y: 100), rx: 120, ry: 55, seed: 4)], intent: .automatic))
    #expect(wide.kind == .ellipse)
    #expect(wide.frame.width > wide.frame.height * 1.8)
    let tilted = try #require(ShapeRecognizer.recognize([ellipse(center: .init(x: 200, y: 200), rx: 120, ry: 50, rotation: 0.5, seed: 5)], intent: .automatic))
    #expect(tilted.kind == .ellipse)
    #expect(abs(tilted.rotationRadians - 0.5) < 0.12)

    let up = try #require(ShapeRecognizer.recognize([handDrawn([.init(x: 90, y: 0), .init(x: 170, y: 140), .init(x: 0, y: 136)], seed: 11, overshoot: 0.05)], intent: .automatic))
    #expect(up.kind == .triangle); #expect(up.rotationRadians == 0)
    let down = try #require(ShapeRecognizer.recognize([handDrawn([.init(x: 0, y: 0), .init(x: 160, y: 6), .init(x: 84, y: 130)], seed: 12)], intent: .automatic))
    // Pointing down is drawn by its corners, not by turning it upside down (its text stays upright).
    #expect(down.kind == .triangle); #expect(down.rotationRadians == 0)
    #expect(down.vertices?.contains { $0.y == 1 && abs($0.x - 0.5) < 1e-6 } == true)

    let diamond = try #require(ShapeRecognizer.recognize([handDrawn([.init(x: 100, y: 0), .init(x: 200, y: 70), .init(x: 104, y: 140), .init(x: 0, y: 66)], seed: 13)], intent: .automatic))
    #expect(diamond.kind == .diamond)

    let turned = try #require(ShapeRecognizer.recognize([handDrawn([.init(x: 40, y: 0), .init(x: 220, y: 84), .init(x: 178, y: 175), .init(x: 0, y: 92)], seed: 14)], intent: .automatic))
    #expect(turned.kind == .rectangle)
    #expect(abs(turned.rotationRadians - atan2(84, 180)) < 0.12)
}

@Test func holdingAtTheEndSnapsRougherFigures() throws {
    // A box with very uneven corners and a wide gap: kept as ink normally, snapped on hold.
    let rough = handDrawn([.init(x: 0, y: 0), .init(x: 150, y: 20), .init(x: 128, y: 120), .init(x: 10, y: 140)], seed: 21, bow: 0.1, gap: 55)
    #expect(ShapeRecognizer.recognize([rough], intent: .deliberate)?.kind == .rectangle)
    // A small box (below the automatic size) still snaps on hold.
    let small = handDrawn([.init(x: 0, y: 0), .init(x: 28, y: 0), .init(x: 28, y: 22), .init(x: 0, y: 22)], seed: 22, jitter: 0.6)
    #expect(ShapeRecognizer.recognize([small], intent: .automatic) == nil)
    #expect(ShapeRecognizer.recognize([small], intent: .deliberate)?.kind == .rectangle)
    // A free straight line only becomes a line shape on hold.
    let line = segment(.init(x: 0, y: 0), .init(x: 220, y: 40), seed: 23)
    #expect(ShapeRecognizer.recognize([line], intent: .deliberate)?.kind == .line)
}

// MARK: Handwriting and scribbles that must stay ink

private func letter(_ name: String, at origin: CanvasPoint, size: Double, seed: UInt64) -> [CanvasPoint] {
    func p(_ x: Double, _ y: Double) -> CanvasPoint { .init(x: origin.x + x * size, y: origin.y + y * size) }
    var noise = Noise(state: seed)
    func arc(_ cx: Double, _ cy: Double, _ r: Double, from: Double, to: Double, steps: Int = 30) -> [CanvasPoint] {
        (0...steps).map { i in
            let t = from + (to - from) * Double(i) / Double(steps)
            return p(cx + r * cos(t) + 0.01 * noise.next(), cy + r * sin(t) + 0.01 * noise.next())
        }
    }
    func line(_ a: (Double, Double), _ b: (Double, Double), steps: Int = 12) -> [CanvasPoint] {
        (0...steps).map { i in let t = Double(i) / Double(steps); return p(a.0 + (b.0 - a.0) * t + 0.008 * noise.next(), a.1 + (b.1 - a.1) * t + 0.008 * noise.next()) }
    }
    switch name {
    case "e": return line((0.05, 0.5), (0.95, 0.5)) + arc(0.5, 0.5, 0.45, from: 0, to: -1.75 * .pi)
    case "c": return arc(0.5, 0.5, 0.45, from: -0.25 * .pi, to: -1.75 * .pi)
    case "u": return line((0.05, 0), (0.05, 0.7)) + arc(0.45, 0.7, 0.4, from: .pi, to: 0) + line((0.85, 0.7), (0.85, 0)) + line((0.85, 0), (0.9, 1))
    case "S": return arc(0.5, 0.27, 0.27, from: -0.1 * .pi, to: -1.5 * .pi) + arc(0.5, 0.75, 0.25, from: -0.5 * .pi, to: 0.9 * .pi)
    case "z": return line((0, 0), (1, 0)) + line((1, 0), (0, 1)) + line((0, 1), (1, 1))
    case "m": return line((0, 1), (0, 0.2)) + arc(0.25, 0.3, 0.25, from: .pi, to: 2 * .pi) + line((0.5, 0.3), (0.5, 1)) + arc(0.75, 0.3, 0.25, from: .pi, to: 2 * .pi) + line((1, 0.3), (1, 1))
    case "2": return arc(0.5, 0.3, 0.3, from: -0.9 * .pi, to: 0.2 * .pi) + line((0.78, 0.42), (0.05, 1)) + line((0.05, 1), (0.95, 1))
    case "l": return line((0.4, 0), (0.45, 1))
    case "a": return arc(0.45, 0.55, 0.4, from: -0.2 * .pi, to: -2.15 * .pi) + line((0.82, 0.25), (0.88, 1))
    case "d": return arc(0.4, 0.62, 0.36, from: -0.15 * .pi, to: -2.1 * .pi) + line((0.74, 0), (0.78, 1))
    case "g": return arc(0.45, 0.35, 0.33, from: -0.2 * .pi, to: -2.1 * .pi) + line((0.76, 0.2), (0.76, 1)) + arc(0.45, 1, 0.31, from: 0, to: 0.9 * .pi)
    case "6": return arc(0.5, 0.65, 0.33, from: -0.75 * .pi, to: 1.25 * .pi) + arc(0.75, 0.6, 0.6, from: -0.6 * .pi, to: -0.95 * .pi)
    case "D": return line((0.1, 0), (0.1, 1)) + arc(0.1, 0.5, 0.5, from: 0.5 * .pi, to: -0.5 * .pi)
    case "scribble":
        return (0...120).map { i in let t = Double(i) / 120 * 8 * .pi; return p(0.5 + 0.45 * sin(t * 1.3), 0.5 + 0.45 * cos(t * 0.7)) }
    case "spiral":
        return (0...120).map { i in let t = Double(i) / 120 * 5 * .pi; let r = 0.05 + 0.09 * t / .pi; return p(0.5 + r * cos(t), 0.5 + r * sin(t)) }
    default: return []
    }
}

@Test func handwritingAndScribblesStayInk() {
    let names = ["e", "c", "u", "S", "z", "m", "2", "l", "scribble", "spiral", "a", "d", "g", "6", "D"]
    for (index, name) in names.enumerated() {
        for size in [50.0, 90.0] {
            let stroke = letter(name, at: .init(x: 40, y: 40), size: size, seed: UInt64(100 + index))
            let result = ShapeRecognizer.recognize([stroke], intent: .automatic)
            #expect(result == nil || result?.kind == .line && name == "l", "\(name) at \(size)pt became \(String(describing: result?.kind))")
        }
    }
}

@Test func strokesTooFarApartAreNotOneFigure() {
    let left = segment(.init(x: 0, y: 0), .init(x: 0, y: 120), seed: 31)
    let right = segment(.init(x: 300, y: 0), .init(x: 300, y: 120), seed: 32)
    #expect(ShapeRecognizer.recognize([left, right], intent: .automatic) == nil)
    #expect(ShapeRecognizer.recognize([left, right], intent: .deliberate) == nil)
}

@Test func recognizedShapesKeepTheirAngleAndOriginalStroke() throws {
    let points = handDrawn([.init(x: 40, y: 0), .init(x: 220, y: 84), .init(x: 178, y: 175), .init(x: 0, y: 92)], seed: 14)
    let shape = try #require(ShapeRecognizer.recognize([points], intent: .automatic))
    let commands = try #require(try DiagramCommands.insert(shape, in: .init(title: "D"), stroke: "#FF0000", lineWidth: 4))
    let document = try CommandEngine.applying(commands, to: .init(title: "D"))
    let block = try #require(document.blocks.first { $0.parentID == nil })
    #expect(abs(block.effectivePresentation.rotationRadians - shape.rotationRadians) < 1e-9)
    guard case .shape(let drawn) = block.content else { Issue.record("Expected a shape"); return }
    #expect(drawn.stroke == "#FF0000"); #expect(drawn.lineWidth == 4)
    #expect(drawn.originalStroke?.points.count == points.count)
    // A free line is not inserted unless the gesture was deliberate.
    let line = try #require(ShapeRecognizer.recognize([segment(.init(x: 0, y: 0), .init(x: 220, y: 40), seed: 23)], intent: .deliberate))
    #expect(try DiagramCommands.insert(line, in: .init(title: "D"), allowFreeLines: false) == nil)
}

/// Rates over many random rough figures and letters; the printed numbers are the ones reported.
@Test func recognitionRatesOnRandomRoughFigures() {
    var noise = Noise(state: 2026)
    func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * (noise.next() + 1) / 2 }
    let trials = 300
    var boxes = 0, boxWrong = 0, circles = 0, circleWrong = 0, triangles = 0, letters = 0, lettersTotal = 0
    for trial in 0..<trials {
        let w = r(90...320), h = r(70...240), k = 0.12   // corners moved up to 12% of the side
        let corners = [CanvasPoint(x: r(-k...k) * w, y: r(-k...k) * h), .init(x: w + r(-k...k) * w, y: r(-k...k) * h),
                       .init(x: w + r(-k...k) * w, y: h + r(-k...k) * h), .init(x: r(-k...k) * w, y: h + r(-k...k) * h)]
        let box = handDrawn(corners, seed: UInt64(trial + 1000), bow: r(0...0.06), overshoot: r(0...0.12), gap: r(0...0.08) * (w + h))
        switch ShapeRecognizer.recognize([box], intent: .automatic)?.kind { case .rectangle: boxes += 1; case nil: break; default: boxWrong += 1 }
        let circle = ellipse(center: .init(x: 200, y: 200), rx: r(50...160), ry: r(50...160), seed: UInt64(trial + 2000), sweep: 2 * .pi * r(0.95...1.12))
        switch ShapeRecognizer.recognize([circle], intent: .automatic)?.kind { case .ellipse: circles += 1; case nil: break; default: circleWrong += 1 }
        let tri = handDrawn([.init(x: w / 2 + r(-0.15...0.15) * w, y: 0), .init(x: w, y: h + r(-8...8)), .init(x: 0, y: h + r(-8...8))],
                            seed: UInt64(trial + 3000), bow: r(0...0.05), overshoot: r(0...0.1))
        if ShapeRecognizer.recognize([tri], intent: .automatic)?.kind == .triangle { triangles += 1 }
        for (index, name) in ["e", "c", "u", "S", "z", "m", "2", "a", "d", "g", "6", "D"].enumerated() {
            let size = r(40...120)
            let stroke = letter(name, at: .init(x: 0, y: 0), size: size, seed: UInt64(trial * 31 + index))
            lettersTotal += 1
            if let kind = ShapeRecognizer.recognize([stroke], intent: .automatic)?.kind, kind != .line { letters += 1 }
        }
    }
    print("RATES boxes \(boxes)/\(trials) (wrong kind \(boxWrong)), circles \(circles)/\(trials) (wrong kind \(circleWrong)), " +
          "triangles \(triangles)/\(trials), letters turned into shapes \(letters)/\(lettersTotal)")
    #expect(Double(boxes) / Double(trials) >= 0.9)
    #expect(Double(circles) / Double(trials) >= 0.9)
    #expect(Double(triangles) / Double(trials) >= 0.85)
    #expect(boxWrong + circleWrong <= trials / 50)
    #expect(Double(letters) / Double(lettersTotal) <= 0.03)
}

// MARK: Triangles of any form

private func side(_ a: CanvasPoint, _ b: CanvasPoint, bow: Double, noise: inout Noise, from: Double = 0, to: Double = 1) -> [CanvasPoint] {
    let length = hypot(b.x - a.x, b.y - a.y)
    let normal = CanvasPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
    let curve = bow * length * noise.next()
    let steps = max(6, Int(length / 6))
    return (0...steps).compactMap { step in
        let t = Double(step) / Double(steps)
        guard t >= from - 1e-9, t <= to + 1e-9 else { return nil }
        let offset = curve * sin(.pi * t)
        return .init(x: a.x + (b.x - a.x) * t + normal.x * offset + 1.5 * noise.next(), y: a.y + (b.y - a.y) * t + normal.y * offset + 1.5 * noise.next())
    }
}

@Test func rightAndLopsidedTrianglesKeepTheirForm() throws {
    var noise = Noise(state: 41)
    // A right triangle: the corner stays a right angle and on the left.
    let right = side(.init(x: 0, y: 0), .init(x: 0, y: 160), bow: 0.02, noise: &noise) + side(.init(x: 0, y: 160), .init(x: 220, y: 158), bow: 0.02, noise: &noise)
        + side(.init(x: 220, y: 158), .init(x: 2, y: 2), bow: 0.02, noise: &noise)
    let shape = try #require(ShapeRecognizer.recognize([right], intent: .automatic))
    #expect(shape.kind == .triangle); #expect(shape.rotationRadians == 0)
    let corners = try #require(shape.vertices)
    #expect(corners.contains(.init(x: 0, y: 0))); #expect(corners.contains(.init(x: 0, y: 1))); #expect(corners.contains(.init(x: 1, y: 1)))
    // Apex at a third of the base: kept there, not moved to the middle.
    let lopsided = side(.init(x: 60, y: 0), .init(x: 200, y: 150), bow: 0.02, noise: &noise) + side(.init(x: 200, y: 150), .init(x: 0, y: 150), bow: 0.02, noise: &noise)
        + side(.init(x: 0, y: 150), .init(x: 60, y: 2), bow: 0.02, noise: &noise)
    let apex = try #require(ShapeRecognizer.recognize([lopsided], intent: .automatic)?.vertices?.first { $0.y == 0 })
    #expect(abs(apex.x - 0.3) < 0.05)
}

@Test func trianglesWithAnOpenCornerOrCrookedSides() {
    var noise = Noise(state: 99)
    func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * (noise.next() + 1) / 2 }
    var counts: [String: Int] = [:], wrong = 0
    let trials = 300
    for trial in 0..<trials {
        let w = r(90...300), h = r(80...240), tilt = r(-0.15...0.15)
        func turn(_ p: CanvasPoint) -> CanvasPoint { .init(x: p.x * cos(tilt) - p.y * sin(tilt) + 200, y: p.x * sin(tilt) + p.y * cos(tilt) + 200) }
        let apex = turn(.init(x: r(0...1) * w, y: 0)), right = turn(.init(x: w, y: h)), left = turn(.init(x: 0, y: h))
        var n = Noise(state: UInt64(trial + 77))
        let bow = r(0...0.06)
        let cases: [(String, [[CanvasPoint]])] = [
            ("any form", [side(apex, right, bow: bow, noise: &n) + side(right, left, bow: bow, noise: &n) + side(left, apex, bow: bow, noise: &n)]),
            ("stops short of the start", [side(apex, right, bow: bow, noise: &n) + side(right, left, bow: bow, noise: &n) + side(left, apex, bow: bow, noise: &n, to: r(0.7...0.9))]),
            ("both ends short", [side(apex, right, bow: bow, noise: &n, from: r(0.05...0.15)) + side(right, left, bow: bow, noise: &n) + side(left, apex, bow: bow, noise: &n, to: r(0.85...0.95))]),
            ("corner open between two strokes", [side(apex, right, bow: bow, noise: &n, to: r(0.75...0.9)), side(right, left, bow: bow, noise: &n, from: r(0.0...0.1)) + side(left, apex, bow: bow, noise: &n)]),
            ("crooked sides", [side(apex, right, bow: r(0.08...0.14), noise: &n) + side(right, left, bow: r(0.05...0.12), noise: &n) + side(left, apex, bow: r(0.08...0.14), noise: &n)]),
            ("three strokes", [side(apex, right, bow: bow, noise: &n), side(right, left, bow: bow, noise: &n), side(left, apex, bow: bow, noise: &n)]),
        ]
        for (name, strokes) in cases {
            switch ShapeRecognizer.recognize(strokes, intent: .automatic)?.kind {
            case .triangle: counts[name, default: 0] += 1
            case nil: break
            default: wrong += 1
            }
        }
    }
    print("TRIANGLES " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)/\(trials)" }.joined(separator: ", ") + ", other kind \(wrong)")
    for (name, count) in counts { #expect(Double(count) / Double(trials) >= 0.9, "\(name)") }
    #expect(counts.count == 6)
    #expect(wrong == 0)
}

@Test func straightLettersAndArchesAreNotTriangles() {
    var noise = Noise(state: 5)
    func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * (noise.next() + 1) / 2 }
    var letters = 0, arches = 0
    for trial in 0..<300 {
        var n = Noise(state: UInt64(trial + 500))
        let s = r(40...120)
        func strokes(_ pts: [(Double, Double)]) -> [CanvasPoint] {
            (0..<(pts.count - 1)).flatMap { i in side(.init(x: pts[i].0 * s, y: pts[i].1 * s), .init(x: pts[i + 1].0 * s, y: pts[i + 1].1 * s), bow: 0.03, noise: &n) }
        }
        let shapes: [[[CanvasPoint]]] = [
            [strokes([(0, 0), (1, 0), (0, 1), (1, 1)])],                          // Z
            [strokes([(0, 1), (0, 0), (0.8, 1), (0.8, 0)])],                      // N
            [strokes([(0.7, 0), (0, 0.7), (1, 0.7)]), strokes([(0.7, 0.05), (0.7, 1)])],   // 4
            [strokes([(0.7, 1), (0.7, 0), (0, 0.7), (1, 0.7)])],                  // 4 in one stroke
            [strokes([(0, 1), (0.5, 0), (1, 1)]), strokes([(0.25, 0.55), (0.75, 0.55)])],  // A
            [strokes([(0, 0), (0.5, 1), (1, 0)])],                                // V
            [strokes([(0, 0), (0.25, 1), (0.5, 0.3), (0.75, 1), (1, 0)])],        // W
            [strokes([(0, 1), (0.1, 0), (0.5, 0.7), (0.9, 0), (1, 1)])],          // M
            [strokes([(0, 0), (1, 0), (0.4, 1)])],                                // 7
            [strokes([(0.1, 0.2), (0.5, 0), (0.9, 0.2), (0, 1), (1, 1)])],        // 2
        ]
        letters += shapes.filter { ShapeRecognizer.recognize($0, intent: .automatic)?.kind == .triangle }.count
        // A half disc or half ellipse ("D" lying down) has two corners and a round top.
        let w = r(90...300), h = r(80...240)
        let half = (0...60).map { i -> CanvasPoint in let t = .pi * Double(i) / 60; return .init(x: 200 + w / 2 * cos(t), y: 200 - h * sin(t)) }
            + side(.init(x: 200 - w / 2, y: 200), .init(x: 200 + w / 2, y: 200), bow: 0.02, noise: &n)
        if ShapeRecognizer.recognize([half], intent: .automatic)?.kind == .triangle { arches += 1 }
    }
    print("NOT TRIANGLES letters \(letters)/3000, half discs \(arches)/300")
    #expect(letters == 0)
    #expect(arches <= 20)     // only very tall, pointed arches
}

/// The O(n³) search finds the same largest quadrilateral as trying every four corners.
@Test func largestQuadrilateralMatchesTheExhaustiveSearch() {
    var noise = Noise(state: 314)
    for _ in 0..<40 {
        let points = (0..<60).map { _ in CanvasPoint(x: 200 * noise.next(), y: 140 * noise.next()) }
        let hull = ShapeRecognizer.convexHull(points)
        guard hull.count >= 4 else { continue }
        func area(_ a: CanvasPoint, _ b: CanvasPoint, _ c: CanvasPoint) -> Double { abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2 }
        var exhaustive = 0.0
        let n = hull.count
        for i in 0..<n { for j in (i + 1)..<n { for k in (j + 1)..<n { for l in (k + 1)..<n {
            exhaustive = max(exhaustive, area(hull[i], hull[j], hull[k]) + area(hull[i], hull[k], hull[l]))
        } } } }
        #expect(abs(ShapeRecognizer.largestPolygon(hull, vertices: 4).area - exhaustive) < 1e-6)
    }
}
