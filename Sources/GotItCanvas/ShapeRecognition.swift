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
        guard let span = closedSpan(path, tolerance: limits.closure * diagonal),
              Double(span.tail - span.head + 1) >= Double(path.count) * limits.coverage,
              intent == .deliberate || leftoversContinueTheOutline(path, head: span.head, tail: span.tail) else { return nil }
        let loop = Array(path[span.head...span.tail])
        let hull = convexHull(loop)
        guard hull.count >= 3 else { return nil }
        let hullArea = area(hull), hullPerimeter = perimeter(hull, closed: true)
        let rect = minimumAreaRectangle(hull)
        guard hullArea > 0, rect.area > 0, min(rect.width, rect.height) >= max(6, 0.1 * max(rect.width, rect.height)) else { return nil }
        guard perimeter(loop, closed: true) / hullPerimeter <= limits.retrace,
              abs(signedArea(loop)) / hullArea >= limits.solidity else { return nil }
        let triangle = largestPolygon(hull, vertices: 3), quad = largestPolygon(hull, vertices: 4)
        let triangleRatio = triangle.area / hullArea, quadRatio = quad.area / hullArea, fill = hullArea / rect.area
        let frame = LogicalRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
        let original = strokes.count == 1 ? strokes[0] : joined

        if triangleRatio >= limits.triangle {
            guard let oriented = orientTriangle(triangle.points, in: box, tolerance: limits.vertexTolerance) else { return nil }
            return .init(kind: .triangle, frame: oriented.frame, originalPoints: original, rotationRadians: oriented.rotation)
        }
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
            return nil
        }
        if limits.ellipseQuad.contains(quadRatio), limits.ellipseFill.contains(fill), triangleRatio <= 0.62 {
            let turned = rotatedFrame(rect)
            let aspect = max(rect.width, rect.height) / min(rect.width, rect.height)
            if aspect < 1.2 || abs(turned.rotation) < 0.2 { return .init(kind: .ellipse, frame: frame, originalPoints: original) }
            return .init(kind: .ellipse, frame: turned.frame, originalPoints: original, rotationRadians: turned.rotation)
        }
        return nil
    }

    // MARK: Lines

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

    // MARK: Classification helpers

    private static func orientTriangle(_ vertices: [CanvasPoint], in box: Box, tolerance: Double) -> (frame: LogicalRect, rotation: Double)? {
        let normalized = vertices.map { normalize($0, in: box) }
        let up = LogicalRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
        let sideways = LogicalRect(x: box.midX - box.height / 2, y: box.midY - box.width / 2, width: box.height, height: box.width)
        // Rotation is clockwise on screen (y grows down), as CGAffineTransform(rotationAngle:) draws it.
        let options: [([CanvasPoint], LogicalRect, Double)] = [
            ([.init(x: 0.5, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)], up, 0),
            ([.init(x: 0.5, y: 1), .init(x: 0, y: 0), .init(x: 1, y: 0)], up, .pi),
            ([.init(x: 1, y: 0.5), .init(x: 0, y: 1), .init(x: 0, y: 0)], sideways, .pi / 2),
            ([.init(x: 0, y: 0.5), .init(x: 1, y: 0), .init(x: 1, y: 1)], sideways, -.pi / 2)
        ]
        let scored = options.map { (templateError(normalized, $0.0), $0.1, $0.2) }.min { $0.0 < $1.0 }!
        return scored.0 <= tolerance ? (scored.1, scored.2) : nil
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
