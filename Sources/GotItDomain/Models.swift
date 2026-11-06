import Foundation

public struct CanvasDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var revision: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var defaultStyle: BlockStyle
    public var blocks: [CanvasBlock]
    public var assets: [Asset]
    public var relations: [BlockRelation]

    public init(id: UUID = UUID(), title: String, defaultStyle: BlockStyle = .init(), now: Date = Date()) {
        self.id = id
        self.title = title
        self.revision = 0
        self.createdAt = now
        self.updatedAt = now
        self.defaultStyle = defaultStyle
        self.blocks = []
        self.assets = []
        self.relations = []
    }

    public func children(of parentID: UUID? = nil) -> [CanvasBlock] {
        blocks.filter { $0.parentID == parentID }.sorted { $0.order < $1.order }
    }

    /// Note defaults → outer containers → inner containers → block overrides.
    public func resolvedStyle(for blockID: UUID) throws -> BlockStyle {
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [BlockStyle] = []
        var visited: Set<UUID> = []
        var current: UUID? = blockID
        while let id = current {
            guard visited.insert(id).inserted else { throw DocumentError.invalid("Parent cycle") }
            guard let block = byID[id] else { throw DocumentError.missingBlock(id) }
            chain.append(block.style)
            current = block.parentID
        }
        return chain.reversed().reduce(defaultStyle) { $0.merging($1) }
    }
}

public struct CanvasBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var parentID: UUID?
    /// Sibling ordering; gaps are allowed. A batch can reorder several blocks atomically.
    public var order: Int
    public var layout: BlockLayout
    public var style: BlockStyle
    public var content: BlockContent

    public init(id: UUID = UUID(), parentID: UUID? = nil, order: Int = 0,
                layout: BlockLayout = .init(), style: BlockStyle = .init(), content: BlockContent) {
        self.id = id
        self.parentID = parentID
        self.order = order
        self.layout = layout
        self.style = style
        self.content = content
    }
}

public enum LayoutMode: String, Codable, Sendable { case flow, absolute, anchored }

public struct LogicalRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 320, height: Double = 80) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct BlockLayout: Codable, Equatable, Sendable {
    public var mode: LayoutMode
    /// Logical points, independent of screen scale and zoom; relative to parent/anchor.
    public var frame: LogicalRect
    public var anchorID: UUID?
    public var zIndex: Int

    public init(mode: LayoutMode = .flow, frame: LogicalRect = .init(), anchorID: UUID? = nil, zIndex: Int = 0) {
        self.mode = mode; self.frame = frame; self.anchorID = anchorID; self.zIndex = zIndex
    }
}

public enum TextAlignment: String, Codable, Sendable { case leading, center, trailing, justified }

/// nil inherits; false explicitly overrides an inherited true value.
public struct BlockStyle: Codable, Equatable, Sendable {
    public var fontName: String?
    public var fontSize: Double?
    public var bold: Bool?
    public var italic: Bool?
    public var foreground: String?
    public var background: String?
    public var alignment: TextAlignment?

    public init(fontName: String? = nil, fontSize: Double? = nil, bold: Bool? = nil,
                italic: Bool? = nil, foreground: String? = nil, background: String? = nil,
                alignment: TextAlignment? = nil) {
        self.fontName = fontName; self.fontSize = fontSize; self.bold = bold; self.italic = italic
        self.foreground = foreground; self.background = background; self.alignment = alignment
    }

    public func merging(_ overrides: BlockStyle) -> BlockStyle {
        BlockStyle(fontName: overrides.fontName ?? fontName, fontSize: overrides.fontSize ?? fontSize,
                   bold: overrides.bold ?? bold, italic: overrides.italic ?? italic,
                   foreground: overrides.foreground ?? foreground, background: overrides.background ?? background,
                   alignment: overrides.alignment ?? alignment)
    }
}

public struct TextRun: Codable, Equatable, Sendable {
    public var text: String
    public var style: BlockStyle
    public init(_ text: String, style: BlockStyle = .init()) { self.text = text; self.style = style }
}

public struct RichText: Codable, Equatable, Sendable {
    public var runs: [TextRun]
    public init(runs: [TextRun]) { self.runs = runs }
    public init(_ text: String) { self.runs = [TextRun(text)] }
    public var plainText: String { runs.map(\.text).joined() }
}

public enum ShapeKind: String, Codable, Sendable { case rectangle, ellipse, line, arrow }

public struct Shape: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    public var stroke: String
    public var fill: String?
    public var lineWidth: Double
    public init(kind: ShapeKind, stroke: String = "#000000", fill: String? = nil, lineWidth: Double = 1) {
        self.kind = kind; self.stroke = stroke; self.fill = fill; self.lineWidth = lineWidth
    }
}

public struct AssetReference: Codable, Equatable, Sendable {
    public var hash: String
    public var caption: String?
    public init(hash: String, caption: String? = nil) { self.hash = hash; self.caption = caption }
}

public enum BlockContent: Codable, Equatable, Sendable {
    case text(RichText)
    case container
    case image(AssetReference)
    case drawing(AssetReference)
    case pdf(AssetReference)
    case audio(AssetReference)
    case video(AssetReference)
    case shape(Shape)

    public var assetHash: String? {
        switch self {
        case .image(let ref), .drawing(let ref), .pdf(let ref), .audio(let ref), .video(let ref): ref.hash
        default: nil
        }
    }
}

/// Metadata only. Importing, hashing and managing the physical bytes belong to stage 3.
public struct Asset: Codable, Equatable, Sendable {
    public var hash: String
    public var mediaType: String
    public var byteCount: Int64
    public var derivatives: [AssetDerivative]
    public init(hash: String, mediaType: String, byteCount: Int64, derivatives: [AssetDerivative] = []) {
        self.hash = hash; self.mediaType = mediaType; self.byteCount = byteCount; self.derivatives = derivatives
    }
}

public struct AssetDerivative: Codable, Equatable, Sendable {
    public var role: String
    public var hash: String
    public var mediaType: String
    public var byteCount: Int64
    public init(role: String, hash: String, mediaType: String, byteCount: Int64) {
        self.role = role; self.hash = hash; self.mediaType = mediaType; self.byteCount = byteCount
    }
}

public enum RelationKind: String, Codable, Sendable { case link, connector, annotation }

public struct BlockRelation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var targetID: UUID
    public var kind: RelationKind
    public init(id: UUID = UUID(), sourceID: UUID, targetID: UUID, kind: RelationKind) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.kind = kind
    }
}
