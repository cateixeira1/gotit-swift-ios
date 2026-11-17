import Foundation
import GotItDomain

/// Guides while an object is dragged, as in Canva: when its middle lines up with the middle of
/// another object (or of the page), a black line shows the alignment and the object snaps to it.
public enum AlignmentGuides {
    /// A guide line on the page, from `start` to `end`.
    public struct Line: Equatable, Sendable {
        public var start: CanvasPoint
        public var end: CanvasPoint
    }

    public struct Snap: Equatable, Sendable {
        /// How far to move the dragged object so its middle lines up exactly.
        public var offset: CanvasPoint
        public var lines: [Line]
        public static let none = Snap(offset: .init(x: 0, y: 0), lines: [])
    }

    /// `threshold`: how close (in page points) the middles must be to snap.
    public static func snap(_ moving: LogicalRect, to others: [LogicalRect], page: CanvasSize, threshold: Double = 6) -> Snap {
        let pageRect = LogicalRect(x: 0, y: 0, width: page.width, height: page.height)
        let targets = others + [pageRect]
        let mx = moving.x + moving.width / 2, my = moving.y + moving.height / 2

        // Nearest middle on each axis within the threshold.
        func nearest(_ value: Double, _ middle: (LogicalRect) -> Double) -> Double? {
            targets.map(middle).filter { abs($0 - value) <= threshold }.min { abs($0 - value) < abs($1 - value) }
        }
        let x = nearest(mx) { $0.x + $0.width / 2 }, y = nearest(my) { $0.y + $0.height / 2 }
        let offset = CanvasPoint(x: x.map { $0 - mx } ?? 0, y: y.map { $0 - my } ?? 0)
        let snapped = LogicalRect(x: moving.x + offset.x, y: moving.y + offset.y, width: moving.width, height: moving.height)

        var lines: [Line] = []
        if let x {
            // From the topmost to the bottommost of the objects sharing this middle (the page's
            // middle draws across the whole page).
            let aligned = targets.filter { abs($0.x + $0.width / 2 - x) < 0.5 } + [snapped]
            let top = aligned.map(\.y).min() ?? 0, bottom = aligned.map { $0.y + $0.height }.max() ?? page.height
            lines.append(Line(start: .init(x: x, y: top), end: .init(x: x, y: bottom)))
        }
        if let y {
            let aligned = targets.filter { abs($0.y + $0.height / 2 - y) < 0.5 } + [snapped]
            let left = aligned.map(\.x).min() ?? 0, right = aligned.map { $0.x + $0.width }.max() ?? page.width
            lines.append(Line(start: .init(x: left, y: y), end: .init(x: right, y: y)))
        }
        return Snap(offset: offset, lines: lines)
    }
}
