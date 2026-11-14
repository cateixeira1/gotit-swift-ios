import Foundation
import GotItDomain

public struct CanvasViewport: Equatable, Sendable {
    public var zoom: Double
    public var offset: CanvasPoint
    public init(zoom: Double = 1, offset: CanvasPoint = .init(x: 0, y: 0)) throws {
        guard zoom.isFinite, zoom > 0, offset.x.isFinite, offset.y.isFinite else { throw DocumentError.invalid("Invalid viewport") }
        self.zoom = zoom; self.offset = offset
    }
    public func screenPoint(from point: CanvasPoint) -> CanvasPoint {
        .init(x: point.x * zoom - offset.x, y: point.y * zoom - offset.y)
    }
    public func canvasPoint(from point: CanvasPoint) -> CanvasPoint {
        .init(x: (point.x + offset.x) / zoom, y: (point.y + offset.y) / zoom)
    }
}

public extension LogicalRect {
    var center: CanvasPoint { .init(x: x + width / 2, y: y + height / 2) }
    func contains(_ point: CanvasPoint) -> Bool { point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height }
    func intersects(_ other: LogicalRect) -> Bool {
        x < other.x + other.width && x + width > other.x && y < other.y + other.height && y + height > other.y
    }
}

public enum CanvasLayoutEngine {
    /// Flow order, parent and anchor dependencies are resolved together, without recursion.
    public static func frames(in document: CanvasDocument) throws -> [UUID: LogicalRect] {
        try DocumentValidator.validate(document)
        let blocks = Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.id, $0) })
        var previousFlow: [UUID: UUID] = [:]
        let membership = document.pageAssignments()
        let groups = Dictionary(grouping: document.blocks, by: { ($0.parentID.map { "parent:\($0)" }) ?? "page:\(membership[$0.id]?.uuidString ?? "missing")" })
        for siblings in groups.values {
            let flow = siblings.filter { $0.layout.mode == .flow }.sorted { $0.order < $1.order }
            for index in flow.indices.dropFirst() { previousFlow[flow[index].id] = flow[index - 1].id }
        }
        var dependencies: [UUID: Int] = [:]
        var dependents: [UUID: [UUID]] = [:]
        for block in document.blocks {
            let required = Set([block.parentID, block.layout.anchorID, previousFlow[block.id]].compactMap { $0 })
            dependencies[block.id] = required.count
            for id in required { dependents[id, default: []].append(block.id) }
        }
        var queue = dependencies.filter { $0.value == 0 }.map(\.key)
        var result: [UUID: LogicalRect] = [:]
        while let id = queue.popLast(), let block = blocks[id] {
            var frame = block.layout.frame
            let base = block.layout.anchorID.flatMap { result[$0] } ?? block.parentID.flatMap { result[$0] }
            frame.x += base?.x ?? 0
            frame.y += base?.y ?? 0
            if let previous = previousFlow[id].flatMap({ result[$0] }) { frame.y = previous.y + previous.height + block.layout.frame.y }
            result[id] = frame
            for dependent in dependents[id, default: []] {
                dependencies[dependent, default: 0] -= 1
                if dependencies[dependent] == 0 { queue.append(dependent) }
            }
        }
        guard result.count == blocks.count else { throw DocumentError.invalid("Flow and anchor dependencies form a cycle") }
        return result
    }

    public static func visibleBlocks(in document: CanvasDocument, viewport: LogicalRect, overscan: Double = 80) throws -> [UUID] {
        let frames = try frames(in: document)
        let expanded = LogicalRect(x: viewport.x - overscan, y: viewport.y - overscan,
                                   width: viewport.width + 2 * overscan, height: viewport.height + 2 * overscan)
        return document.blocks.filter { block in
            guard let frame = frames[block.id] else { return false }
            return rotatedBounds(frame, radians: block.effectivePresentation.rotationRadians).intersects(expanded)
        }.sorted { $0.layout.zIndex == $1.layout.zIndex ? $0.order < $1.order : $0.layout.zIndex < $1.layout.zIndex }.map(\.id)
    }

    public static func rotatedBounds(_ frame: LogicalRect, radians: Double) -> LogicalRect {
        let width = abs(cos(radians)) * frame.width + abs(sin(radians)) * frame.height
        let height = abs(sin(radians)) * frame.width + abs(cos(radians)) * frame.height
        return .init(x: frame.center.x - width / 2, y: frame.center.y - height / 2, width: width, height: height)
    }
}

public struct TextExclusion: Equatable, Sendable {
    public var objectID: UUID
    /// Polygon in the text block's local coordinates, before textContainerInset.
    public var polygon: [CanvasPoint]
}

public enum TextFlowEngine {
    public static func exclusions(for textID: UUID, in document: CanvasDocument) throws -> [TextExclusion] {
        let frames = try CanvasLayoutEngine.frames(in: document)
        guard let textFrame = frames[textID], let text = document.blocks.first(where: { $0.id == textID }),
              case .text = text.content else { throw DocumentError.missingBlock(textID) }
        let byID = Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.id, $0) })
        var ancestors: Set<UUID> = []
        var current = text.parentID
        while let id = current { ancestors.insert(id); current = byID[id]?.parentID }
        let membership = document.pageAssignments()
        return document.blocks.compactMap { object in
            if membership[object.id] != membership[textID] { return nil }
            if object.id == textID || ancestors.contains(object.id) { return nil }
            switch object.content { case .text, .container: return nil; default: break }
            guard let frame = frames[object.id] else { return nil }
            let presentation = object.effectivePresentation
            let mode = presentation.wrap == .inherit ? (document.canvas.textAvoidsObjects ? TextWrapMode.bounds : .none) : presentation.wrap
            guard mode != .none else { return nil }
            let bounds = CanvasLayoutEngine.rotatedBounds(frame, radians: presentation.rotationRadians)
            let padding = presentation.textPadding
            let padded = LogicalRect(x: bounds.x - padding, y: bounds.y - padding,
                                     width: bounds.width + 2 * padding, height: bounds.height + 2 * padding)
            guard padded.intersects(textFrame) else { return nil }
            var polygon: [CanvasPoint]
            if mode == .topAndBottom {
                polygon = corners(.init(x: textFrame.x, y: padded.y, width: textFrame.width, height: padded.height))
            } else if mode == .contour, let kind = contourKind(of: object) {
                let local = LogicalRect(x: frame.x - padding, y: frame.y - padding, width: frame.width + 2 * padding, height: frame.height + 2 * padding)
                switch kind {
                case .ellipse:
                    polygon = (0..<32).map { index in
                        let angle = Double(index) * .pi / 16
                        return CanvasPoint(x: local.center.x + cos(angle) * local.width / 2, y: local.center.y + sin(angle) * local.height / 2)
                    }
                case .diamond:
                    polygon = [.init(x: local.center.x, y: local.y), .init(x: local.x + local.width, y: local.center.y),
                               .init(x: local.center.x, y: local.y + local.height), .init(x: local.x, y: local.center.y)]
                case .triangle:
                    var corners: [CanvasPoint] = [.init(x: 0.5, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
                    if case .shape(let shape) = object.content { corners = shape.triangleCorners }
                    polygon = corners.map { .init(x: local.x + $0.x * local.width, y: local.y + $0.y * local.height) }
                default: polygon = corners(local)
                }
                polygon = polygon.map { rotate($0, around: frame.center, angle: presentation.rotationRadians) }
            } else { polygon = corners(padded) }
            return TextExclusion(objectID: object.id, polygon: polygon.map { .init(x: $0.x - textFrame.x, y: $0.y - textFrame.y) })
        }
    }
    /// Shapes wrap by their outline; images wrap by their mask, if they have one.
    private static func contourKind(of object: CanvasBlock) -> ShapeKind? {
        switch object.content {
        case .shape(let shape): return shape.kind
        case .image, .sticker: return object.effectivePresentation.imageMask
        default: return nil
        }
    }
    private static func corners(_ rect: LogicalRect) -> [CanvasPoint] {
        [.init(x: rect.x, y: rect.y), .init(x: rect.x + rect.width, y: rect.y),
         .init(x: rect.x + rect.width, y: rect.y + rect.height), .init(x: rect.x, y: rect.y + rect.height)]
    }
    private static func rotate(_ point: CanvasPoint, around center: CanvasPoint, angle: Double) -> CanvasPoint {
        let x = point.x - center.x, y = point.y - center.y
        return .init(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
    }
}

public enum ConnectorGeometry {
    public static func path(from source: LogicalRect, to target: LogicalRect, routing: ConnectorRouting = .straight) -> [CanvasPoint] {
        let start = boundary(of: source, towards: target.center), end = boundary(of: target, towards: source.center)
        if routing == .orthogonal {
            let middleX = (start.x + end.x) / 2
            return [start, .init(x: middleX, y: start.y), .init(x: middleX, y: end.y), end]
        }
        return [start, end]
    }
    private static func boundary(of rect: LogicalRect, towards target: CanvasPoint) -> CanvasPoint {
        let dx = target.x - rect.center.x, dy = target.y - rect.center.y
        guard dx != 0 || dy != 0 else { return rect.center }
        let scale = min(dx == 0 ? Double.infinity : rect.width / (2 * abs(dx)), dy == 0 ? Double.infinity : rect.height / (2 * abs(dy)))
        return .init(x: rect.center.x + dx * scale, y: rect.center.y + dy * scale)
    }
}
