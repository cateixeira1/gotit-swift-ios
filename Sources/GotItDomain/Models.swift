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
    public var kind: DocumentKind
    public var canvas: CanvasSettings
    public var pages: [CanvasPage]
    /// Named styles changed or added in this note; built-ins not listed keep their defaults.
    public var namedStyles: [NamedStyle]

    public init(id: UUID = UUID(), title: String, defaultStyle: BlockStyle = .init(), now: Date = Date(), kind: DocumentKind = .note, canvas: CanvasSettings = .init()) {
        self.id = id
        self.title = title
        self.revision = 0
        self.createdAt = now
        self.updatedAt = now
        self.defaultStyle = defaultStyle
        self.blocks = []
        self.assets = []
        self.relations = []
        self.kind = kind
        self.canvas = canvas
        self.pages = [CanvasPage(id: id, title: "Página 1")]
        self.namedStyles = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, revision, createdAt, updatedAt, defaultStyle, blocks, assets, relations, kind, canvas, pages, namedStyles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        revision = try c.decode(Int64.self, forKey: .revision)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        defaultStyle = try c.decode(BlockStyle.self, forKey: .defaultStyle)
        blocks = try c.decode([CanvasBlock].self, forKey: .blocks)
        assets = try c.decode([Asset].self, forKey: .assets)
        relations = try c.decode([BlockRelation].self, forKey: .relations)
        kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .note
        canvas = try c.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? .init()
        pages = try c.decodeIfPresent([CanvasPage].self, forKey: .pages) ?? [CanvasPage(id: id, title: "Página 1")]
        namedStyles = try c.decodeIfPresent([NamedStyle].self, forKey: .namedStyles) ?? []
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
    /// Nil inherits the parent page, or the first page for legacy root blocks.
    public var pageID: UUID?
    /// Fragments with the same ID form one continuous text story, ordered by page.
    public var textFlowID: UUID?
    /// Sibling ordering; gaps are allowed. A batch can reorder several blocks atomically.
    public var order: Int
    public var layout: BlockLayout
    public var style: BlockStyle
    public var content: BlockContent
    public var presentation: ObjectPresentation?
    public var effectivePresentation: ObjectPresentation { presentation ?? .init() }

    public init(id: UUID = UUID(), parentID: UUID? = nil, order: Int = 0,
                layout: BlockLayout = .init(), style: BlockStyle = .init(), content: BlockContent, presentation: ObjectPresentation? = nil, pageID: UUID? = nil, textFlowID: UUID? = nil) {
        self.id = id
        self.parentID = parentID
        self.pageID = pageID
        self.textFlowID = textFlowID
        self.order = order
        self.layout = layout
        self.style = style
        self.content = content
        self.presentation = presentation
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
    public var underline: Bool?
    public var strikethrough: Bool?
    public var baseline: TextBaseline?
    public var link: String?
    public var paragraph: ParagraphFormat?
    /// Identifier of the named style (Título, Corpo...) this text was formatted with. A tag only:
    /// the concrete attributes above stay authoritative, so text renders identically without it.
    public var namedStyle: String?

    public init(fontName: String? = nil, fontSize: Double? = nil, bold: Bool? = nil,
                italic: Bool? = nil, foreground: String? = nil, background: String? = nil,
                alignment: TextAlignment? = nil, underline: Bool? = nil, strikethrough: Bool? = nil,
                baseline: TextBaseline? = nil, link: String? = nil, paragraph: ParagraphFormat? = nil,
                namedStyle: String? = nil) {
        self.fontName = fontName; self.fontSize = fontSize; self.bold = bold; self.italic = italic
        self.foreground = foreground; self.background = background; self.alignment = alignment
        self.underline = underline; self.strikethrough = strikethrough; self.baseline = baseline; self.link = link
        self.paragraph = paragraph; self.namedStyle = namedStyle
    }

    public func merging(_ overrides: BlockStyle) -> BlockStyle {
        BlockStyle(fontName: overrides.fontName ?? fontName, fontSize: overrides.fontSize ?? fontSize,
                   bold: overrides.bold ?? bold, italic: overrides.italic ?? italic,
                   foreground: overrides.foreground ?? foreground, background: overrides.background ?? background,
                   alignment: overrides.alignment ?? alignment, underline: overrides.underline ?? underline,
                   strikethrough: overrides.strikethrough ?? strikethrough,
                   baseline: overrides.baseline ?? baseline, link: overrides.link ?? link, paragraph: overrides.paragraph ?? paragraph,
                   namedStyle: overrides.namedStyle ?? namedStyle)
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

public enum ShapeKind: String, Codable, Sendable {
    case rectangle, ellipse, diamond, triangle, line, arrow
    /// A paper note stuck on the page, with a text inside; `fill` is the paper colour.
    case stickyNote
    /// A desk-calendar sticker showing one day (`Shape.date`).
    case calendar
    /// A card holding the transcription of an audio (its text is the child block).
    case transcript
}
public extension ShapeKind {
    /// Shapes with an inside: usable as image masks and as text-wrap contours.
    static let closedMasks: [ShapeKind] = [.rectangle, .ellipse, .diamond, .triangle]
}

public struct Shape: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    public var stroke: String
    public var fill: String?
    public var lineWidth: Double
    public var originalStroke: InkStroke?
    /// Corners as fractions of the frame (0...1), for a triangle of any form. Nil: upright, apex centred.
    public var vertices: [CanvasPoint]?
    /// Day shown by a calendar sticker, "yyyy-MM-dd".
    public var date: String?
    /// A transcription card folded down to a small square (its text hidden); nil when open.
    public var folded: FoldedCard?
    public init(kind: ShapeKind, stroke: String = "#000000", fill: String? = nil, lineWidth: Double = 1, originalStroke: InkStroke? = nil,
                vertices: [CanvasPoint]? = nil, date: String? = nil, folded: FoldedCard? = nil) {
        self.kind = kind; self.stroke = stroke; self.fill = fill; self.lineWidth = lineWidth
        self.originalStroke = originalStroke; self.vertices = vertices; self.date = date; self.folded = folded
    }
    /// The triangle's corners as fractions of its frame.
    public var triangleCorners: [CanvasPoint] {
        if let vertices, vertices.count == 3, vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) { return vertices }
        return [.init(x: 0.5, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
    }
}

/// Where a folded card was open and where it was folded: opening it again restores the open
/// size, moved by as much as the folded square was moved meanwhile.
public struct FoldedCard: Codable, Equatable, Sendable {
    public var expanded: LogicalRect
    public var folded: LogicalRect
    public init(expanded: LogicalRect, folded: LogicalRect) { self.expanded = expanded; self.folded = folded }
}

public struct AssetReference: Codable, Equatable, Sendable {
    public var hash: String
    public var caption: String?
    /// Drawings only: strokes added later, each saved as its own small asset and laid over `hash`
    /// in order, so a new stroke writes only itself instead of the whole page again.
    public var parts: [String]?
    public init(hash: String, caption: String? = nil, parts: [String]? = nil) {
        self.hash = hash; self.caption = caption; self.parts = parts
    }
    /// The base asset followed by the parts.
    public var allHashes: [String] { [hash] + (parts ?? []) }
}

/// A drawing keeps at most this many parts; the next save writes the whole drawing again.
public enum DrawingParts {
    public static let limit = 24
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
    case sticker(AssetReference)
    case noteReference(NoteReference)
    case ink(InkStroke)
    case table(CanvasTable)

    public var allowsChildren: Bool {
        switch self {
        case .container: true
        case .shape(let shape): shape.kind != .line && shape.kind != .arrow && shape.kind != .calendar
        default: false
        }
    }

    public var assetHash: String? {
        switch self {
        case .image(let ref), .drawing(let ref), .pdf(let ref), .audio(let ref), .video(let ref), .sticker(let ref): ref.hash
        default: nil
        }
    }
    /// Every asset the block needs (a drawing's base and its parts).
    public var assetHashes: [String] {
        switch self {
        case .drawing(let ref): ref.allHashes
        default: assetHash.map { [$0] } ?? []
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
    public var style: ConnectorStyle?
    public var originalStroke: InkStroke?
    public init(id: UUID = UUID(), sourceID: UUID, targetID: UUID, kind: RelationKind, style: ConnectorStyle? = nil, originalStroke: InkStroke? = nil) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.kind = kind
        self.style = style
        self.originalStroke = originalStroke
    }
}
