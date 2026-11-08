import Foundation
import GotItDomain

public struct RecognizedShape: Equatable, Sendable {
    public var kind: ShapeKind
    /// Upright frame; the figure is drawn rotated by `rotationRadians` about its centre.
    public var frame: LogicalRect
    public var originalPoints: [CanvasPoint]
    public var rotationRadians: Double
    public init(kind: ShapeKind, frame: LogicalRect, originalPoints: [CanvasPoint], rotationRadians: Double = 0) {
        self.kind = kind; self.frame = frame; self.originalPoints = originalPoints; self.rotationRadians = rotationRadians
    }
}

/// Single-stroke entry point kept for callers that only have one stroke. Ambiguous strokes return nil.
/// This recognizes geometry, not handwriting or mathematical notation.
public enum DiagramRecognizer {
    public static func recognize(_ points: [CanvasPoint], intent: ShapeIntent = .automatic) -> RecognizedShape? {
        ShapeRecognizer.recognize([points], intent: intent)
    }
}

public enum DiagramCommands {
    public static func insertStroke(_ points: [CanvasPoint], in document: CanvasDocument) throws -> [DocumentCommand] {
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw DocumentError.invalid("Invalid stroke") }
        if document.canvas.recognizeDiagrams, let recognized = DiagramRecognizer.recognize(points),
           let commands = try insert(recognized, in: document) { return commands }
        let minX = points.map(\.x).min()!, minY = points.map(\.y).min()!
        let frame = LogicalRect(x: minX, y: minY, width: max(1, points.map(\.x).max()! - minX), height: max(1, points.map(\.y).max()! - minY))
        let ink = InkStroke(points: points.map { .init(x: $0.x - minX, y: $0.y - minY) })
        let order = (document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
        return [.insertBlock(CanvasBlock(order: order, layout: .init(mode: .absolute, frame: frame), content: .ink(ink)))]
    }

    /// Commands for a recognized figure. A line between two shapes becomes a connector; a line
    /// elsewhere becomes a line shape only when `allowFreeLines` (a deliberate gesture), else nil.
    public static func insert(_ recognized: RecognizedShape, in document: CanvasDocument, stroke: String? = nil,
                              lineWidth: Double? = nil, allowFreeLines: Bool = true) throws -> [DocumentCommand]? {
        let points = recognized.originalPoints
        if recognized.kind == .line {
            if var relation = try connection(for: points, document: document) {
                relation.originalStroke = InkStroke(points: points)
                if let stroke { relation.style = .init(color: stroke, width: lineWidth ?? 2) }
                return [.setRelation(relation)]
            }
            guard allowFreeLines else { return nil }
        }
        let order = (document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
        var commands = insertNode(kind: recognized.kind, frame: recognized.frame, order: order)
        if case .insertBlock(var block) = commands[0], case .shape(var shape) = block.content {
            let minX = points.map(\.x).min() ?? 0, minY = points.map(\.y).min() ?? 0
            shape.originalStroke = InkStroke(points: points.map { .init(x: $0.x - minX, y: $0.y - minY) })
            if let stroke { shape.stroke = stroke }
            if let lineWidth { shape.lineWidth = lineWidth }
            block.content = .shape(shape)
            if recognized.rotationRadians != 0 {
                var presentation = block.effectivePresentation; presentation.rotationRadians = recognized.rotationRadians
                block.presentation = presentation
            }
            commands[0] = .insertBlock(block)
        }
        return commands
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
