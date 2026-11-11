import Foundation

public enum DocumentKind: String, Codable, Sendable { case note, web }
public enum CanvasUnit: String, Codable, Sendable { case pixels, centimeters, inches }

public struct CanvasSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public static let a4 = CanvasSize(width: 210 * 72 / 25.4, height: 297 * 72 / 25.4)
    /// Canonical dimensions are points (1/72 inch), independent of display scale.
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public init(width: Double, height: Double, unit: CanvasUnit, pixelsPerInch: Double = 96) throws {
        guard pixelsPerInch.isFinite, pixelsPerInch > 0 else { throw DocumentError.invalid("Invalid pixel density") }
        let factor = Self.factor(unit, pixelsPerInch: pixelsPerInch)
        self.init(width: width * factor, height: height * factor)
        try validate()
    }
    public func dimensions(in unit: CanvasUnit, pixelsPerInch: Double = 96) throws -> CanvasSize {
        guard pixelsPerInch.isFinite, pixelsPerInch > 0 else { throw DocumentError.invalid("Invalid pixel density") }
        try validate()
        let factor = Self.factor(unit, pixelsPerInch: pixelsPerInch)
        return CanvasSize(width: width / factor, height: height / factor)
    }
    public func validate() throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw DocumentError.invalid("Invalid canvas dimensions") }
    }
    private static func factor(_ unit: CanvasUnit, pixelsPerInch: Double) -> Double {
        switch unit { case .pixels: 72 / pixelsPerInch; case .centimeters: 72 / 2.54; case .inches: 72 }
    }
}

public struct CanvasSettings: Codable, Equatable, Sendable {
    public var size: CanvasSize
    public var displayUnit: CanvasUnit
    /// Document pixel convention, not the iPhone screen's hardware pixels.
    public var pixelsPerInch: Double
    public var textAvoidsObjects: Bool
    public var recognizeDiagrams: Bool
    public var solveEquations: Bool
    /// Text margins; nil in notes made before they existed (24 pt all round, see `pageMargins`).
    public var margins: PageMargins?
    public var header: PageBand?
    public var footer: PageBand?
    public var pageNumbers: PageNumbering?
    public init(size: CanvasSize = .a4, displayUnit: CanvasUnit = .centimeters,
                pixelsPerInch: Double = 96, textAvoidsObjects: Bool = true,
                recognizeDiagrams: Bool = true, solveEquations: Bool = true,
                margins: PageMargins? = nil, header: PageBand? = nil, footer: PageBand? = nil, pageNumbers: PageNumbering? = nil) {
        self.size = size; self.displayUnit = displayUnit; self.pixelsPerInch = pixelsPerInch
        self.textAvoidsObjects = textAvoidsObjects; self.recognizeDiagrams = recognizeDiagrams; self.solveEquations = solveEquations
        self.margins = margins; self.header = header; self.footer = footer; self.pageNumbers = pageNumbers
    }
}

public struct CanvasPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum TextWrapMode: String, Codable, Sendable { case inherit, bounds, contour, topAndBottom, none }

public struct ObjectPresentation: Codable, Equatable, Sendable {
    public var wrap: TextWrapMode
    public var textPadding: Double
    public var rotationRadians: Double
    /// Crop in original image coordinates, normalized to 0...1. Original bytes never change.
    public var imageCrop: LogicalRect?
    /// Clips an image or sticker to a closed shape (ellipse, diamond, triangle, rectangle).
    /// Absent in older documents, which decode as unclipped.
    public var imageMask: ShapeKind?
    public init(wrap: TextWrapMode = .inherit, textPadding: Double = 8, rotationRadians: Double = 0,
                imageCrop: LogicalRect? = nil, imageMask: ShapeKind? = nil) {
        self.wrap = wrap; self.textPadding = textPadding; self.rotationRadians = rotationRadians
        self.imageCrop = imageCrop; self.imageMask = imageMask
    }
}

public enum ConnectorRouting: String, Codable, Sendable { case straight, orthogonal }
public struct ConnectorStyle: Codable, Equatable, Sendable {
    public var color: String
    public var width: Double
    public var arrowAtEnd: Bool
    public var routing: ConnectorRouting
    public init(color: String = "#334155", width: Double = 2, arrowAtEnd: Bool = true, routing: ConnectorRouting = .straight) {
        self.color = color; self.width = width; self.arrowAtEnd = arrowAtEnd; self.routing = routing
    }
}

/// A Teia card references a note. Name, preview and creation date are resolved live.
/// Missing notes remain visible as unresolved cards; a reference never owns the target.
public struct NoteReference: Codable, Equatable, Sendable {
    public var documentID: UUID
    public init(documentID: UUID) { self.documentID = documentID }
}

public enum TextBaseline: String, Codable, Sendable { case normal, superscript, `subscript` }

public enum TextListKind: String, Codable, Sendable { case none, bullet, numbered }
public struct ParagraphFormat: Codable, Equatable, Sendable {
    public var lineSpacing: Double
    public var paragraphSpacing: Double
    public var headIndent: Double
    public var firstLineIndent: Double
    public var list: TextListKind
    public init(lineSpacing: Double = 0, paragraphSpacing: Double = 0, headIndent: Double = 0, firstLineIndent: Double = 0, list: TextListKind = .none) {
        self.lineSpacing = lineSpacing; self.paragraphSpacing = paragraphSpacing
        self.headIndent = headIndent; self.firstLineIndent = firstLineIndent; self.list = list
    }
}

public struct InkStroke: Codable, Equatable, Sendable {
    public var points: [CanvasPoint]
    public var color: String
    public var width: Double
    public init(points: [CanvasPoint], color: String = "#334155", width: Double = 2) {
        self.points = points; self.color = color; self.width = width
    }
}
