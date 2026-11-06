import Foundation
import GotItDomain

public struct RecognizedShape: Equatable, Sendable {
    public var kind: ShapeKind
    public var frame: LogicalRect
    public var originalPoints: [CanvasPoint]
}

/// Conservative single-stroke geometric recognition. Ambiguous strokes return nil.
/// This recognizes geometry, not handwriting or mathematical notation.
public enum DiagramRecognizer {
    public static func recognize(_ points: [CanvasPoint]) -> RecognizedShape? {
        guard points.count >= 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, minY = ys.min()!, width = xs.max()! - minX, height = ys.max()! - minY
        let diagonal = hypot(width, height)
        guard diagonal >= 12 else { return nil }
        let frame = LogicalRect(x: minX, y: minY, width: width, height: height)
        let endpointDistance = distance(first, last)
        if endpointDistance > diagonal * 0.8 {
            let maximumError = points.map { segmentDistance($0, first, last) }.max() ?? .infinity
            if maximumError <= diagonal * 0.04 { return .init(kind: .line, frame: frame, originalPoints: points) }
            return nil
        }
        guard endpointDistance <= diagonal * 0.2, width >= 8, height >= 8 else { return nil }
        let normalized = points.map { CanvasPoint(x: ($0.x - minX) / width, y: ($0.y - minY) / height) }
        let rectangle = [CanvasPoint(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
        let diamond = [CanvasPoint(x: 0.5, y: 0), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1), .init(x: 0, y: 0.5)]
        let triangle = [CanvasPoint(x: 0.5, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
        let ellipseError = normalized.map { abs(hypot(($0.x - 0.5) * 2, ($0.y - 0.5) * 2) - 1) / 2 }.reduce(0, +) / Double(points.count)
        let candidates: [(ShapeKind, Double)] = [(.rectangle, polygonError(normalized, rectangle)), (.diamond, polygonError(normalized, diamond)), (.triangle, polygonError(normalized, triangle)), (.ellipse, ellipseError)]
        let sorted = candidates.sorted { $0.1 < $1.1 }
        guard let best = sorted.first, best.1 <= 0.055, sorted[1].1 - best.1 >= 0.012 else { return nil }
        // Bounding dimensions are retained, so a wide rectangle stays wide.
        return .init(kind: best.0, frame: frame, originalPoints: points)
    }

    private static func polygonError(_ points: [CanvasPoint], _ vertices: [CanvasPoint]) -> Double {
        points.map { point in vertices.indices.map { segmentDistance(point, vertices[$0], vertices[($0 + 1) % vertices.count]) }.min()! }.reduce(0, +) / Double(points.count)
    }
    private static func distance(_ a: CanvasPoint, _ b: CanvasPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private static func segmentDistance(_ p: CanvasPoint, _ a: CanvasPoint, _ b: CanvasPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return distance(p, .init(x: a.x + t * dx, y: a.y + t * dy))
    }
}

public enum DiagramCommands {
    public static func insertStroke(_ points: [CanvasPoint], in document: CanvasDocument) throws -> [DocumentCommand] {
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw DocumentError.invalid("Invalid stroke") }
        let minX = points.map(\.x).min()!, minY = points.map(\.y).min()!
        let frame = LogicalRect(x: minX, y: minY, width: max(1, points.map(\.x).max()! - minX), height: max(1, points.map(\.y).max()! - minY))
        let ink = InkStroke(points: points.map { .init(x: $0.x - minX, y: $0.y - minY) })
        let order = (document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
        if document.canvas.recognizeDiagrams, let recognized = DiagramRecognizer.recognize(points) {
            if recognized.kind == .line, var relation = try connection(for: points, document: document) {
                relation.originalStroke = InkStroke(points: points)
                return [.setRelation(relation)]
            }
            var commands = insertNode(kind: recognized.kind, frame: frame, order: order)
            if case .insertBlock(var block) = commands[0], case .shape(var shape) = block.content {
                shape.originalStroke = ink
                block.content = .shape(shape)
                commands[0] = .insertBlock(block)
            }
            return commands
        }
        return [.insertBlock(CanvasBlock(order: order, layout: .init(mode: .absolute, frame: frame), content: .ink(ink)))]
    }

    /// Node and editable text child are one atomic, undoable operation.
    public static func insertNode(kind: ShapeKind, frame: LogicalRect, order: Int, color: String = "#DBEAFE") -> [DocumentCommand] {
        let shape = CanvasBlock(order: order, layout: .init(mode: .absolute, frame: frame), content: .shape(.init(kind: kind, fill: color)))
        guard shape.content.allowsChildren else { return [.insertBlock(shape)] }
        let text = CanvasBlock(parentID: shape.id, layout: .init(mode: .absolute, frame: .init(x: 12, y: 12, width: max(1, frame.width - 24), height: max(1, frame.height - 24))), content: .text(RichText("")))
        return [.insertBlock(shape), .insertBlock(text)]
    }

    public static func connection(for stroke: [CanvasPoint], document: CanvasDocument, tolerance: Double = 24) throws -> BlockRelation? {
        guard let start = stroke.first, let end = stroke.last else { return nil }
        let frames = try CanvasLayoutEngine.frames(in: document)
        func match(_ point: CanvasPoint) -> UUID? {
            let candidates = document.blocks.filter { block in
                guard block.content.allowsChildren, let frame = frames[block.id] else { return false }
                return LogicalRect(x: frame.x - tolerance, y: frame.y - tolerance, width: frame.width + tolerance * 2, height: frame.height + tolerance * 2).contains(point)
            }
            return candidates.count == 1 ? candidates[0].id : nil
        }
        guard let source = match(start), let target = match(end), source != target else { return nil }
        return BlockRelation(sourceID: source, targetID: target, kind: .connector, style: .init())
    }
}
