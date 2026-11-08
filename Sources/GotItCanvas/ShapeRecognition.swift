import Foundation
import GotItDomain

/// How clearly the user asked for a shape.
public enum ShapeIntent: Sendable {
    /// An ordinary stroke. Only clean, unambiguous figures convert, so handwriting survives.
    case automatic
    /// The finger or pencil rested at the end of the stroke ("draw and hold", as in Apple Notes).
    /// Rough figures snap, including open ones and ones drawn with several strokes.
    case deliberate
}

/// Recognizes rough hand-drawn figures by their convex hull instead of by point-to-template
/// distance. The ratios used (largest inscribed triangle and quadrilateral against the hull, hull
/// against its minimum-area rectangle) do not change when a figure is stretched, so a tall,
/// crooked box scores like a neat square. Approach after Fonseca & Jorge, CALI (2002).
public enum ShapeRecognizer {
    struct Thresholds {
        var minimumSize: Double          // largest side of the figure, logical points
        var closure: Double              // gap between the ends, as a fraction of the diagonal
        var junction: Double             // gap between strokes of one figure, fraction of diagonal
        var retrace: Double              // stroke length / hull perimeter (scribbles are long)
        var solidity: Double             // area enclosed by the stroke / hull area (loops cancel out)
        var triangle: Double             // largest triangle / hull
        var quad: Double                 // largest quadrilateral / hull
        var ellipseQuad: ClosedRange<Double>
        var ellipseFill: ClosedRange<Double>
        var vertexTolerance: Double      // corner distance to the template, fraction of the box
        var lineDeviation: Double        // fraction of the line length
        var coverage: Double             // share of the stroke inside the closed part (spirals fail)
    }
    static func thresholds(_ intent: ShapeIntent) -> Thresholds {
        switch intent {
        case .automatic:
            .init(minimumSize: 36, closure: 0.2, junction: 0.16, retrace: 1.15, solidity: 0.72, triangle: 0.8, quad: 0.85,
                  ellipseQuad: 0.5...0.79, ellipseFill: 0.7...0.89, vertexTolerance: 0.3, lineDeviation: 0.035, coverage: 0.72)
        case .deliberate:
            .init(minimumSize: 16, closure: 0.32, junction: 0.25, retrace: 1.65, solidity: 0.55, triangle: 0.74, quad: 0.79,
                  ellipseQuad: 0.45...0.84, ellipseFill: 0.62...0.93, vertexTolerance: 0.38, lineDeviation: 0.07, coverage: 0.55)
        }
    }

    /// Strokes are in drawing order; several strokes are joined end to end into one outline.
    public static func recognize(_ strokes: [[CanvasPoint]], intent: ShapeIntent) -> RecognizedShape? {
        let strokes = strokes.filter { $0.count >= 2 }
        guard !strokes.isEmpty, strokes.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return nil }
        let limits = thresholds(intent)
        let all = strokes.flatMap { $0 }
        let box = bounds(all)
        let diagonal = hypot(box.width, box.height)
        guard max(box.width, box.height) >= limits.minimumSize else { return nil }
        if strokes.count == 1, let line = line(strokes[0], limits: limits) { return line }
        guard let joined = strokes.count == 1 ? strokes[0] : chain(strokes, maximumGap: limits.junction * diagonal) else { return nil }
        let path = resample(joined, count: 96)
        let original = strokes.count == 1 ? strokes[0] : joined
        func triangleShape(_ corners: [CanvasPoint]) -> RecognizedShape {
            let fitted = fitTriangle(corners)
            return .init(kind: .triangle, frame: fitted.frame, originalPoints: original, rotationRadians: fitted.rotation, vertices: fitted.vertices)
        }
        // Three straight sides with one corner left open: the open corner is where the first and the
        // last side meet when extended. Tried whenever the outline does not close cleanly.
        func openCorner() -> RecognizedShape? { openTriangle(path, limits: limits).map(triangleShape) }
        guard let span = closedSpan(path, tolerance: limits.closure * diagonal),
              Double(span.tail - span.head + 1) >= Double(path.count) * limits.coverage,
              intent == .deliberate || leftoversContinueTheOutline(path, head: span.head, tail: span.tail) else { return openCorner() }
        let loop = Array(path[span.head...span.tail])
        let hull = convexHull(loop)
        guard hull.count >= 3 else { return nil }
        let hullArea = area(hull), hullPerimeter = perimeter(hull, closed: true)
        let rect = minimumAreaRectangle(hull)
        guard hullArea > 0, rect.area > 0, min(rect.width, rect.height) >= max(6, 0.1 * max(rect.width, rect.height)) else { return nil }
        guard perimeter(loop, closed: true) / hullPerimeter <= limits.retrace else { return nil }
        let triangle = largestPolygon(hull, vertices: 3)
        let triangleRatio = triangle.area / hullArea
        // Crooked sides (bowed in or out) lower the area ratios; the outline still follows the three
        // sides of the triangle closely, which an ellipse, a box or a letter does not.
        func crookedSides() -> RecognizedShape? {
            guard triangleRatio >= 0.6, abs(signedArea(loop)) / hullArea >= limits.solidity - 0.14,
                  followsTriangle(loop, triangle.points, tolerance: intent == .deliberate ? 0.2 : 0.17) else { return openCorner() }
            return triangleShape(triangle.points)
        }
        guard abs(signedArea(loop)) / hullArea >= limits.solidity else { return crookedSides() }
        let quad = largestPolygon(hull, vertices: 4)
        let quadRatio = quad.area / hullArea, fill = hullArea / rect.area
        let frame = LogicalRect(x: box.minX, y: box.minY, width: box.width, height: box.height)

        if triangleRatio >= limits.triangle { return triangleShape(triangle.points) }
        if quadRatio >= limits.quad {
            let normalized = quad.points.map { normalize($0, in: box) }
            let axis = templateError(normalized, [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
            let diamond = templateError(normalized, [.init(x: 0.5, y: 0), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1), .init(x: 0, y: 0.5)])
            if diamond <= limits.vertexTolerance * 0.8, diamond < axis * 0.8 {
                return .init(kind: .diamond, frame: frame, originalPoints: original)
            }
            // A box drawn at an angle keeps its angle instead of being forced upright: its hull fills
            // a tilted rectangle and its corners are close to right angles (unlike a skewed box).
            let turned = rotatedFrame(rect)
            if abs(turned.rotation) >= 0.2, fill >= 0.9, maximumCornerDeviation(quad.points) <= 0.35 {
                return .init(kind: .rectangle, frame: turned.frame, originalPoints: original, rotationRadians: turned.rotation)
            }
            if axis <= limits.vertexTolerance + 0.08, axis < diamond { return .init(kind: .rectangle, frame: frame, originalPoints: original) }
            return crookedSides()
        }
        if limits.ellipseQuad.contains(quadRatio), limits.ellipseFill.contains(fill), triangleRatio <= 0.62 {
            let turned = rotatedFrame(rect)
            let aspect = max(rect.width, rect.height) / min(rect.width, rect.height)
            if aspect < 1.2 || abs(turned.rotation) < 0.2 { return .init(kind: .ellipse, frame: frame, originalPoints: original) }
            return .init(kind: .ellipse, frame: turned.frame, originalPoints: original, rotationRadians: turned.rotation)
        }
        return crookedSides()
    }

    /// Every point of the outline lies near one side of the triangle, within `tolerance` of that
    /// side's length, and every side is visited (a bulge of a few percent is a crooked line; the
    /// arc of an ellipse between two corners bows out by about 30 % of the chord).
    static func followsTriangle(_ loop: [CanvasPoint], _ corners: [CanvasPoint], tolerance: Double) -> Bool {
        guard corners.count == 3 else { return false }
        let sides = [(corners[0], corners[1]), (corners[1], corners[2]), (corners[2], corners[0])]
        let lengths = sides.map { distance($0.0, $0.1) }
        guard lengths.allSatisfy({ $0 > 0 }) else { return false }
        for i in 0..<3 {
            let p = corners[i], q = corners[(i + 1) % 3], r = corners[(i + 2) % 3]
            let u = (q.x - p.x, q.y - p.y), v = (r.x - p.x, r.y - p.y)
            let angle = abs(atan2(u.0 * v.1 - u.1 * v.0, u.0 * v.0 + u.1 * v.1))
            guard angle >= 0.21, angle <= 2.8 else { return false }
        }
        var visited = [0, 0, 0], bulge = [0.0, 0.0, 0.0]
        let centroid = CanvasPoint(x: corners.map(\.x).reduce(0, +) / 3, y: corners.map(\.y).reduce(0, +) / 3)
        for point in loop {
            let distances = sides.map { segmentDistance(point, $0.0, $0.1) }
            let nearest = distances.indices.min { distances[$0] < distances[$1] }!
            guard distances[nearest] <= tolerance * lengths[nearest] else { return false }
            visited[nearest] += 1
            // Outward: on the other side of the edge from the centroid.
            let (a, b) = sides[nearest]
            let side = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let inner = (b.x - a.x) * (centroid.y - a.y) - (b.y - a.y) * (centroid.x - a.x)
            if side * inner < 0 { bulge[nearest] = max(bulge[nearest], distances[nearest] / lengths[nearest]) }
        }
        guard visited.allSatisfy({ $0 >= loop.count / 12 }) else { return false }
        // Two sides bowing out together are the round top of an arch, not two crooked lines.
        guard bulge.filter({ $0 > 0.1 }).count < 2 else { return false }
        // Each corner is a real turn of the pen, not the smooth top of an arc (a half disc has two
        // corners and a rounded third).
        let n = loop.count, window = max(2, n / 12)
        for corner in corners {
            let index = loop.indices.min { distance(loop[$0], corner) < distance(loop[$1], corner) }!
            let before = loop[(index - window + n) % n], here = loop[index], after = loop[(index + window) % n]
            let u = (here.x - before.x, here.y - before.y), v = (after.x - here.x, after.y - here.y)
            let turn = abs(atan2(u.0 * v.1 - u.1 * v.0, u.0 * v.0 + u.1 * v.1))
            guard turn >= 0.6 else { return false }
        }
        return true
    }

    // MARK: Lines

    /// A stroke that goes from one place to another without turning back (straight, or gently
    /// curved): what a connector between two figures looks like when drawn by hand. Looser than a
    /// free line, because landing on two figures already says what it is.
    public static func isConnectorStroke(_ points: [CanvasPoint]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return false }
        let length = perimeter(points, closed: false), span = distance(first, last)
        guard span >= 12, length > 0, span / length >= 0.75 else { return false }
        let deviation = points.map { segmentDistance($0, first, last) }.max() ?? .infinity
        return deviation <= 0.25 * span
    }

    private static func line(_ points: [CanvasPoint], limits: Thresholds) -> RecognizedShape? {
        guard let first = points.first, let last = points.last else { return nil }
        let length = perimeter(points, closed: false), span = distance(first, last)
        guard span >= max(24, limits.minimumSize * 0.75), span / length >= 0.9 else { return nil }
        let deviation = points.map { segmentDistance($0, first, last) }.max() ?? .infinity
        guard deviation <= limits.lineDeviation * span else { return nil }
        let box = bounds(points)
        return .init(kind: .line, frame: .init(x: box.minX, y: box.minY, width: box.width, height: box.height), originalPoints: points)
    }

    // MARK: Outline

    /// Joins strokes into one path, nearest ends first. Fails when a gap is too wide to be one figure.
    static func chain(_ strokes: [[CanvasPoint]], maximumGap: Double) -> [CanvasPoint]? {
        var remaining = strokes
        guard let longest = remaining.indices.max(by: { perimeter(remaining[$0], closed: false) < perimeter(remaining[$1], closed: false) }) else { return nil }
        var path = remaining.remove(at: longest)
        while !remaining.isEmpty {
            var best: (index: Int, gap: Double, atEnd: Bool, reversed: Bool)?
            for (index, stroke) in remaining.enumerated() {
                let options: [(Double, Bool, Bool)] = [
                    (distance(path.last!, stroke.first!), true, false), (distance(path.last!, stroke.last!), true, true),
                    (distance(path.first!, stroke.last!), false, false), (distance(path.first!, stroke.first!), false, true)
                ]
                for (gap, atEnd, reversed) in options where best == nil || gap < best!.gap { best = (index, gap, atEnd, reversed) }
            }
            guard let pick = best, pick.gap <= maximumGap else { return nil }
            var piece = remaining.remove(at: pick.index)
            if pick.reversed { piece.reverse() }
            path = pick.atEnd ? path + piece : piece + path
        }
        return path
    }

    /// The closed part of a stroke: trims the overshoot past the start and closes a small gap.
    static func closedLoop(_ points: [CanvasPoint], tolerance: Double) -> [CanvasPoint]? {
        closedSpan(points, tolerance: tolerance).map { Array(points[$0.head...$0.tail]) }
    }
    static func closedSpan(_ points: [CanvasPoint], tolerance: Double) -> (head: Int, tail: Int)? {
        let count = points.count
        guard count >= 8 else { return nil }
        let headEnd = Int(Double(count) * 0.3), tailStart = Int(Double(count) * 0.7)
        var best = (head: 0, tail: count - 1, gap: distance(points[0], points[count - 1]))
        for head in 0..<headEnd {
            for tail in tailStart..<count {
                let gap = distance(points[head], points[tail])
                if gap < best.gap { best = (head, tail, gap) }
            }
        }
        return best.gap <= tolerance ? (best.head, best.tail) : nil
    }

    /// An overshoot keeps going the way the outline started; the stem of an "a" or "d" turns back.
    /// Pieces left outside the closed part must be short or continue the outline.
    static func leftoversContinueTheOutline(_ points: [CanvasPoint], head: Int, tail: Int) -> Bool {
        let total = perimeter(points, closed: false)
        guard total > 0 else { return true }
        func direction(_ a: CanvasPoint, _ b: CanvasPoint) -> (Double, Double)? {
            let d = distance(a, b); return d > 0 ? ((b.x - a.x) / d, (b.y - a.y) / d) : nil
        }
        let step = 4
        if tail < points.count - 1, perimeter(Array(points[tail...]), closed: false) > 0.08 * total,
           let leftover = direction(points[tail], points.last!),
           let start = direction(points[head], points[min(tail, head + step)]),
           leftover.0 * start.0 + leftover.1 * start.1 < 0.3 { return false }
        if head > 0, perimeter(Array(points[...head]), closed: false) > 0.08 * total,
           let leftover = direction(points[0], points[head]),
           let end = direction(points[max(head, tail - step)], points[tail]),
           leftover.0 * end.0 + leftover.1 * end.1 < 0.3 { return false }
        return true
    }

    /// A triangle drawn with one corner left open (the stroke stops short of where it started, or
    /// starts after it): exactly three straight sides, the first and the last of which, extended,
    /// meet close to their ends. Parallel ends (z, N), curved strokes and two-sided strokes (∠, 7)
    /// fail, so letters stay ink.
    static func openTriangle(_ path: [CanvasPoint], limits: Thresholds) -> [CanvasPoint]? {
        let box = bounds(path)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 0 else { return nil }
        let indices = simplifiedIndices(path, tolerance: 0.06 * diagonal)
        guard indices.count == 4 else { return nil }
        let corners = indices.map { path[$0] }
        let (start, b, c, end) = (corners[0], corners[1], corners[2], corners[3])
        // Each side is straight: the drawn points stay close to it.
        for side in 0..<3 {
            let from = corners[side], to = corners[side + 1]
            let length = distance(from, to)
            guard length >= 0.15 * diagonal else { return nil }
            let wobble = path[indices[side]...indices[side + 1]].map { segmentDistance($0, from, to) }.max() ?? 0
            guard wobble <= (intentIsLoose(limits) ? 0.16 : 0.12) * length else { return nil }
        }
        guard let corner = intersection(start, b, c, end) else { return nil }
        // The open corner lies ahead of both loose ends, and not far from them.
        let first = distance(start, b), last = distance(c, end)
        let missingFirst = distance(corner, start), missingLast = distance(corner, end)
        let reach = intentIsLoose(limits) ? 0.5 : 0.4
        guard distance(corner, b) >= first * 0.98, distance(corner, c) >= last * 0.98,
              missingFirst <= reach * distance(corner, b), missingLast <= reach * distance(corner, c),
              missingFirst + missingLast > 0 else { return nil }
        let triangle = [corner, b, c]
        // A real triangle: no corner flatter than 160° or sharper than 12°.
        for i in 0..<3 {
            let p = triangle[i], q = triangle[(i + 1) % 3], r = triangle[(i + 2) % 3]
            let u = (q.x - p.x, q.y - p.y), v = (r.x - p.x, r.y - p.y)
            let angle = abs(atan2(u.0 * v.1 - u.1 * v.0, u.0 * v.0 + u.1 * v.1))
            guard angle >= 0.21, angle <= 2.8 else { return nil }
        }
        return triangle
    }
    private static func intentIsLoose(_ limits: Thresholds) -> Bool { limits.closure > 0.25 }

    /// Where line ab meets line cd; nil when they are (nearly) parallel.
    static func intersection(_ a: CanvasPoint, _ b: CanvasPoint, _ c: CanvasPoint, _ d: CanvasPoint) -> CanvasPoint? {
        let r = (b.x - a.x, b.y - a.y), s = (d.x - c.x, d.y - c.y)
        let denominator = r.0 * s.1 - r.1 * s.0
        let scale = hypot(r.0, r.1) * hypot(s.0, s.1)
        guard scale > 0, abs(denominator) / scale > 0.17 else { return nil }      // more than about 10° apart
        let t = ((c.x - a.x) * s.1 - (c.y - a.y) * s.0) / denominator
        return .init(x: a.x + t * r.0, y: a.y + t * r.1)
    }

    /// Ramer–Douglas–Peucker: indices of the corners of a path, keeping its first and last points.
    static func simplifiedIndices(_ points: [CanvasPoint], tolerance: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, worst = 0.0
            for index in (first + 1)..<last {
                let d = segmentDistance(points[index], points[first], points[last])
                if d > worst { worst = d; farthest = index }
            }
            if worst > tolerance { keep[farthest] = true; stack.append((first, farthest)); stack.append((farthest, last)) }
        }
        return points.indices.filter { keep[$0] }
    }

    // MARK: Classification helpers

    /// Any triangle, made clean. A side within about 11° of horizontal or vertical is made exactly
    /// horizontal or vertical (the base), and an apex close to the
    /// middle or to an end of the base moves there (isosceles, right triangle). The result is an
    /// upright frame turned by at most 45° with the corners as fractions of it, so text inside a
    /// pointing-down triangle is not upside down.
    static func fitTriangle(_ corners: [CanvasPoint]) -> (frame: LogicalRect, rotation: Double, vertices: [CanvasPoint]) {
        func sub(_ a: CanvasPoint, _ b: CanvasPoint) -> CanvasPoint { .init(x: a.x - b.x, y: a.y - b.y) }
        func dot(_ a: CanvasPoint, _ b: CanvasPoint) -> Double { a.x * b.x + a.y * b.y }
        let sides = [(0, 1, 2), (1, 2, 0), (2, 0, 1)]
        let quarter = Double.pi / 2
        func axisError(_ side: (Int, Int, Int)) -> Double {
            let a = corners[side.0], b = corners[side.1]
            let angle = atan2(b.y - a.y, b.x - a.x)
            return abs(angle - (angle / quarter).rounded() * quarter)
        }
        func length(_ side: (Int, Int, Int)) -> Double { distance(corners[side.0], corners[side.1]) }
        // A side drawn nearly level or upright becomes exactly so (the longest such side is the base,
        // so a right triangle keeps both legs straight); otherwise the longest side is the base.
        let level = sides.filter { axisError($0) < 0.2 }
        let base = (level.isEmpty ? sides : level).max { length($0) < length($1) }!
        var p = corners[base.0], q = corners[base.1]
        let c = corners[base.2]
        var span = max(distance(p, q), 1e-9)
        var u = CanvasPoint(x: (q.x - p.x) / span, y: (q.y - p.y) / span)
        // "Up" in the triangle's own frame points at the apex: (sin θ, −cos θ) for a base at angle θ.
        if dot(sub(c, p), .init(x: u.y, y: -u.x)) < 0 { swap(&p, &q); u = .init(x: -u.x, y: -u.y) }
        var angle = atan2(u.y, u.x)
        let nearestAxis = (angle / quarter).rounded() * quarter
        if abs(angle - nearestAxis) < 0.2 { angle = nearestAxis }
        u = .init(x: cos(angle), y: sin(angle))
        let up = CanvasPoint(x: sin(angle), y: -cos(angle))
        span = max(dot(sub(q, p), u), 1e-9)
        let height = max(dot(sub(c, p), up), 1e-9)
        // Where the apex stands along the base (outside 0...1 for an obtuse triangle on a short base).
        var apex = dot(sub(c, p), u) / span
        if abs(apex - 0.5) < 0.1 { apex = 0.5 } else if abs(apex) < 0.1 { apex = 0 } else if abs(apex - 1) < 0.1 { apex = 1 }
        // The clean triangle on the page: base from p along u, apex `height` above it.
        let bottomLeft = p
        let bottomRight = CanvasPoint(x: p.x + span * u.x, y: p.y + span * u.y)
        let top = CanvasPoint(x: p.x + apex * span * u.x + height * up.x, y: p.y + apex * span * u.y + height * up.y)
        let clean = [top, bottomRight, bottomLeft]
        // Express it in a frame turned by the residual angle only (within ±45°).
        var turn = angle - (angle / quarter).rounded() * quarter
        if abs(turn) < 1e-9 { turn = 0 }
        let cosT = cos(-turn), sinT = sin(-turn)
        let local = clean.map { CanvasPoint(x: $0.x * cosT - $0.y * sinT, y: $0.x * sinT + $0.y * cosT) }
        let box = bounds(local)
        let width = max(box.width, 1e-9), tall = max(box.height, 1e-9)
        let vertices = local.map { CanvasPoint(x: (($0.x - box.minX) / width * 1e6).rounded() / 1e6, y: (($0.y - box.minY) / tall * 1e6).rounded() / 1e6) }
        let mid = CanvasPoint(x: box.midX, y: box.midY)
        let center = CanvasPoint(x: mid.x * cos(turn) - mid.y * sin(turn), y: mid.x * sin(turn) + mid.y * cos(turn))
        return (.init(x: center.x - width / 2, y: center.y - tall / 2, width: width, height: tall), turn, vertices)
    }

    /// Largest distance between matched corners, trying every rotation and direction of the cycle.
    static func templateError(_ points: [CanvasPoint], _ template: [CanvasPoint]) -> Double {
        guard points.count == template.count else { return .infinity }
        let n = points.count
        var best = Double.infinity
        for direction in [1, -1] {
            for shift in 0..<n {
                let error = (0..<n).map { i in distance(points[i], template[((direction * i + shift) % n + n) % n]) }.max()!
                best = min(best, error)
            }
        }
        return best
    }

    /// Largest difference from 90° among the quadrilateral's corners, in radians.
    static func maximumCornerDeviation(_ quad: [CanvasPoint]) -> Double {
        (0..<quad.count).map { i in
            let a = quad[(i + quad.count - 1) % quad.count], b = quad[i], c = quad[(i + 1) % quad.count]
            let u = (a.x - b.x, a.y - b.y), v = (c.x - b.x, c.y - b.y)
            let angle = abs(atan2(u.0 * v.1 - u.1 * v.0, u.0 * v.0 + u.1 * v.1))
            return abs(angle - .pi / 2)
        }.max() ?? .pi
    }

    /// Converts a minimum-area rectangle into an upright frame plus a rotation within ±45°.
    private static func rotatedFrame(_ rect: OrientedRectangle) -> (frame: LogicalRect, rotation: Double) {
        var angle = rect.angle, width = rect.width, height = rect.height
        while angle > .pi / 4 { angle -= .pi / 2; swap(&width, &height) }
        while angle <= -.pi / 4 { angle += .pi / 2; swap(&width, &height) }
        return (.init(x: rect.center.x - width / 2, y: rect.center.y - height / 2, width: width, height: height), angle)
    }

    // MARK: Geometry

    struct Box {
        var minX, minY, width, height: Double
        var midX: Double { minX + width / 2 }
        var midY: Double { minY + height / 2 }
    }
    struct OrientedRectangle {
        var center: CanvasPoint
        var width, height, angle: Double
        var area: Double { width * height }
    }

    static func bounds(_ points: [CanvasPoint]) -> Box {
        let xs = points.map(\.x), ys = points.map(\.y)
        return Box(minX: xs.min()!, minY: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    private static func normalize(_ p: CanvasPoint, in box: Box) -> CanvasPoint {
        .init(x: (p.x - box.minX) / max(box.width, 1e-9), y: (p.y - box.minY) / max(box.height, 1e-9))
    }
    static func distance(_ a: CanvasPoint, _ b: CanvasPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func segmentDistance(_ p: CanvasPoint, _ a: CanvasPoint, _ b: CanvasPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return distance(p, .init(x: a.x + t * dx, y: a.y + t * dy))
    }
    static func perimeter(_ points: [CanvasPoint], closed: Bool) -> Double {
        guard points.count > 1 else { return 0 }
        var total = zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        if closed { total += distance(points.last!, points.first!) }
        return total
    }
    static func signedArea(_ points: [CanvasPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }
    static func area(_ points: [CanvasPoint]) -> Double { abs(signedArea(points)) }

    /// Evenly spaced points along the path, so dense slow segments do not outweigh fast ones.
    static func resample(_ points: [CanvasPoint], count: Int) -> [CanvasPoint] {
        let total = perimeter(points, closed: false)
        guard total > 0, points.count > 1 else { return points }
        let step = total / Double(count - 1)
        var result = [points[0]], carried = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            guard segment > 0 else { continue }
            var position = step - carried
            while position <= segment + 1e-9 {
                let t = position / segment
                result.append(.init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                position += step
            }
            carried = segment - (position - step)
        }
        while result.count < count { result.append(points.last!) }
        return Array(result.prefix(count))
    }

    /// Andrew's monotone chain.
    static func convexHull(_ points: [CanvasPoint]) -> [CanvasPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: CanvasPoint, _ a: CanvasPoint, _ b: CanvasPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CanvasPoint] = [], upper: [CanvasPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Rotating calipers: the smallest enclosing rectangle has one side on a hull edge.
    static func minimumAreaRectangle(_ hull: [CanvasPoint]) -> OrientedRectangle {
        var best = OrientedRectangle(center: .init(x: 0, y: 0), width: 0, height: 0, angle: 0)
        var bestArea = Double.infinity
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let angle = atan2(b.y - a.y, b.x - a.x)
            let c = cos(-angle), s = sin(-angle)
            let rotated = hull.map { CanvasPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
            let box = bounds(rotated)
            guard box.width * box.height < bestArea else { continue }
            bestArea = box.width * box.height
            let mid = CanvasPoint(x: box.midX, y: box.midY)
            let center = CanvasPoint(x: mid.x * cos(angle) - mid.y * sin(angle), y: mid.x * sin(angle) + mid.y * cos(angle))
            best = .init(center: center, width: box.width, height: box.height, angle: angle)
        }
        return best
    }

    /// Largest triangle or quadrilateral with corners on the hull (hull order keeps it convex).
    static func largestPolygon(_ points: [CanvasPoint], vertices: Int) -> (area: Double, points: [CanvasPoint]) {
        var hull = points
        if hull.count > 64 {
            let stride = Double(hull.count) / 64
            hull = (0..<64).map { hull[Int(Double($0) * stride)] }
        }
        let n = hull.count
        guard n >= vertices else { return (area(hull), hull) }
        let xs = hull.map(\.x), ys = hull.map(\.y)
        func triangle(_ a: Int, _ b: Int, _ c: Int) -> Double {
            abs((xs[b] - xs[a]) * (ys[c] - ys[a]) - (ys[b] - ys[a]) * (xs[c] - xs[a])) / 2
        }
        var bestArea = 0.0, best = Array(0..<vertices)
        if vertices == 3 {
            for i in 0..<n { for j in (i + 1)..<n { for k in (j + 1)..<n {
                let value = triangle(i, j, k)
                if value > bestArea { bestArea = value; best = [i, j, k] }
            } } }
        } else {
            for i in 0..<n { for j in (i + 1)..<n { for k in (j + 1)..<n {
                let first = triangle(i, j, k)
                for l in (k + 1)..<n {
                    let value = first + triangle(i, k, l)
                    if value > bestArea { bestArea = value; best = [i, j, k, l] }
                }
            } } }
        }
        return (bestArea, best.map { hull[$0] })
    }
}
