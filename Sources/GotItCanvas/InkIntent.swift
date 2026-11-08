import Foundation
import GotItDomain

/// One finished stroke as the intent rules see it: page points, their times, and when the touch
/// started and lifted (seconds since the reference date).
public struct InkSample: Sendable, Equatable {
    public var points: [CanvasPoint]
    /// Seconds since `startedAt`, one per point.
    public var times: [Double]
    public var startedAt: Double
    public var releasedAt: Double
    public init(points: [CanvasPoint], times: [Double], startedAt: Double, releasedAt: Double) {
        self.points = points; self.times = times; self.startedAt = startedAt; self.releasedAt = releasedAt
    }
    public var bounds: LogicalRect {
        guard !points.isEmpty else { return .init(x: 0, y: 0, width: 0, height: 0) }
        let box = ShapeRecognizer.bounds(points)
        return .init(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }
    /// Length of the drawn path.
    public var length: Double { ShapeRecognizer.perimeter(points, closed: false) }
}

/// What a stroke means, decided from how it was drawn and what is around it, so that writing by
/// hand never opens a text box and a tap never leaves a dot.
public enum InkIntent {
    /// Screen points a finger may wobble during a tap.
    public static let tapTravel = 8.0
    /// Seconds a stroke must rest at its end to ask for a shape (as in Apple Notes).
    public static let holdToSnap = 0.4

    /// A touch that barely moved and lifted quickly. `screenScale`: screen points per logical point.
    public static func isTap(_ sample: InkSample, screenScale: Double) -> Bool {
        let box = sample.bounds
        return max(box.width, box.height) * screenScale <= tapTravel && sample.releasedAt - sample.startedAt <= 0.35
    }

    /// Seconds the stroke rested at its last position before lifting.
    public static func holdDuration(_ sample: InkSample, screenScale: Double) -> Double {
        guard let final = sample.points.last, sample.points.count == sample.times.count else { return 0 }
        let tolerance = 5 / max(screenScale, 0.01)
        var restStart = sample.times.last ?? 0
        for index in sample.points.indices.reversed() {
            if ShapeRecognizer.distance(sample.points[index], final) > tolerance { break }
            restStart = sample.times[index]
        }
        return max(0, sample.releasedAt - sample.startedAt - restStart)
    }

    /// A tap right after writing, close to it, is part of the writing: the dot of an i, a period.
    public static func tapBelongsToWriting(_ tap: InkSample, recent: [InkSample]) -> Bool {
        let box = tap.bounds
        let center = CanvasPoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
        return recent.contains { other in
            guard other.releasedAt <= tap.startedAt + 0.01, tap.startedAt - other.releasedAt <= 2.5 else { return false }
            let near = other.bounds, margin = max(20, 0.8 * near.height)
            return center.x >= near.x - margin && center.x <= near.x + near.width + margin &&
                center.y >= near.y - margin && center.y <= near.y + near.height + margin
        }
    }

    /// Strokes whose boxes touch (after padding) belong together: one figure or one word.
    public static func groups(_ boxes: [LogicalRect], padding: Double) -> [[Int]] {
        var parent = Array(boxes.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in boxes.indices { for j in boxes.indices where j > i && touch(boxes[i], boxes[j], padding: padding) { parent[root(j)] = root(i) } }
        return Dictionary(grouping: boxes.indices, by: root).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Handwriting on the same line, beside the candidate: then a loop is a letter, not an ellipse.
    /// Neighbours that are figures themselves (an unconverted box) do not count as writing.
    public static func isNextToWriting(_ candidate: LogicalRect, neighbours: [InkSample]) -> Bool {
        neighbours.contains { other in
            let box = other.bounds
            guard sameLine(candidate, box), box.height <= 2 * max(candidate.height, 1) else { return false }
            if let kind = ShapeRecognizer.recognize([other.points], intent: .automatic)?.kind, kind != .line { return false }
            return true
        }
    }

    /// Writing that continues right beside a figure that was just converted: it was a letter.
    public static func continuesWriting(after shape: LogicalRect, convertedAt: Double, with stroke: InkSample) -> Bool {
        let box = stroke.bounds
        guard stroke.startedAt - convertedAt <= 3, stroke.startedAt >= convertedAt - 0.01 else { return false }
        guard box.height >= 0.35 * shape.height, box.height <= 1.6 * shape.height else { return false }
        return sameLine(shape, box)
    }

    /// Smallest rectangle containing all of `rects`.
    public static func union(_ rects: [LogicalRect]) -> LogicalRect {
        guard let first = rects.first else { return .init(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for r in rects.dropFirst() { minX = min(minX, r.x); minY = min(minY, r.y); maxX = max(maxX, r.x + r.width); maxY = max(maxY, r.y + r.height) }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func sameLine(_ a: LogicalRect, _ b: LogicalRect) -> Bool {
        let overlap = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard overlap >= 0.3 * min(a.height, b.height) else { return false }
        let gap = max(0, max(a.x, b.x) - min(a.x + a.width, b.x + b.width))
        return gap <= 1.2 * max(a.height, b.height)
    }

    private static func touch(_ a: LogicalRect, _ b: LogicalRect, padding: Double) -> Bool {
        a.x - padding <= b.x + b.width && b.x - padding <= a.x + a.width &&
            a.y - padding <= b.y + b.height && b.y - padding <= a.y + a.height
    }
}
