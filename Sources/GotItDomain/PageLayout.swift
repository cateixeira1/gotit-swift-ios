import Foundation

/// Page margins in points. The text of a note lives inside them; objects may go anywhere.
public struct PageMargins: Codable, Equatable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double
    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static func centimeters(_ value: Double) -> Double { value * 72 / 2.54 }
    /// Notes created before margins existed: 24 pt all round.
    public static let legacy = PageMargins(top: 24, bottom: 24, left: 24, right: 24)
    /// Word's "Normal" margins in Portuguese (Brazil): 2,5 cm top and bottom, 3 cm left and right.
    /// On A4 this leaves a 15 × 24,7 cm text area, like a new Word document.
    public static let word = PageMargins(top: centimeters(2.5), bottom: centimeters(2.5), left: centimeters(3), right: centimeters(3))
}

public enum BandAlignment: String, Codable, Sendable, CaseIterable { case leading, center, trailing }

/// A header or footer: a strip along the top or bottom edge of every page, holding a picture
/// (a letterhead, a logo) and/or a line of text. The note's text stays out of it; objects may go
/// into it (the editor warns while they do).
public struct PageBand: Codable, Equatable, Sendable {
    /// Height measured from the page edge, in points.
    public var height: Double
    public var text: String
    /// Asset hash of the picture, registered in the document.
    public var image: String?
    public var alignment: BandAlignment
    public init(height: Double = PageMargins.centimeters(2), text: String = "", image: String? = nil, alignment: BandAlignment = .center) {
        self.height = height; self.text = text; self.image = image; self.alignment = alignment
    }
}

/// Page numbers drawn on every page (in the footer or header strip, or its margin).
public struct PageNumbering: Codable, Equatable, Sendable {
    public enum Place: String, Codable, Sendable, CaseIterable { case footer, header }
    public enum Format: String, Codable, Sendable, CaseIterable { case number, pageOfTotal, dashes }
    public var place: Place
    public var alignment: BandAlignment
    public var format: Format
    /// Number shown on the first numbered page.
    public var startAt: Int
    /// The first page (a cover) shows no number; numbering still counts it.
    public var skipFirstPage: Bool
    public init(place: Place = .footer, alignment: BandAlignment = .center, format: Format = .number, startAt: Int = 1, skipFirstPage: Bool = false) {
        self.place = place; self.alignment = alignment; self.format = format; self.startAt = startAt; self.skipFirstPage = skipFirstPage
    }

    /// Text for the page at `index` (0-based) of `count` pages; nil where no number is shown.
    public func label(index: Int, count: Int) -> String? {
        guard index >= 0, index < count, !(skipFirstPage && index == 0) else { return nil }
        let number = startAt + index, last = startAt + count - 1
        switch format {
        case .number: return "\(number)"
        case .pageOfTotal: return "Página \(number) de \(last)"
        case .dashes: return "– \(number) –"
        }
    }
}

public extension CanvasSettings {
    /// Margins in force (older notes have none stored: 24 pt).
    var pageMargins: PageMargins { margins ?? .legacy }

    /// Strip of the header on a page, if the note has one.
    var headerRect: LogicalRect? { header.map { LogicalRect(x: 0, y: 0, width: size.width, height: $0.height) } }
    /// Strip of the footer on a page, if the note has one.
    var footerRect: LogicalRect? { footer.map { LogicalRect(x: 0, y: size.height - $0.height, width: size.width, height: $0.height) } }

    /// Where the text of the note goes on every page: inside the margins and clear of the
    /// header and footer (a header taller than the top margin pushes the text down, as in Word).
    var textArea: LogicalRect {
        let m = pageMargins
        let top = max(m.top, (header?.height ?? 0) + 6), bottom = max(m.bottom, (footer?.height ?? 0) + 6)
        return LogicalRect(x: m.left, y: top, width: max(40, size.width - m.left - m.right), height: max(44, size.height - top - bottom))
    }

    /// Where the page number is drawn on a page.
    var pageNumberRect: LogicalRect? {
        guard let numbers = pageNumbers else { return nil }
        let m = pageMargins
        switch numbers.place {
        case .footer:
            let height = footer?.height ?? m.bottom
            return LogicalRect(x: m.left, y: size.height - height, width: max(1, size.width - m.left - m.right), height: height)
        case .header:
            let height = header?.height ?? m.top
            return LogicalRect(x: m.left, y: 0, width: max(1, size.width - m.left - m.right), height: height)
        }
    }

    /// Header and footer strips a block's frame runs into (to warn while it is being placed).
    func bandsInvaded(by frame: LogicalRect) -> [LogicalRect] {
        [headerRect, footerRect].compactMap { $0 }.filter { band in
            frame.x < band.x + band.width && band.x < frame.x + frame.width && frame.y < band.y + band.height && band.y < frame.y + frame.height
        }
    }

    func validateLayout() throws {
        if let m = margins {
            guard [m.top, m.bottom, m.left, m.right].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  m.left + m.right < size.width - 40, m.top + m.bottom < size.height - 44 else { throw DocumentError.invalid("Invalid page margins") }
        }
        for band in [header, footer].compactMap({ $0 }) {
            guard band.height.isFinite, band.height > 0, band.height <= size.height / 3 else { throw DocumentError.invalid("Invalid header or footer height") }
        }
        if let numbers = pageNumbers, !(0...100_000).contains(numbers.startAt) { throw DocumentError.invalid("Invalid first page number") }
        try paper?.validate()
    }

    /// Pictures used by the header and footer.
    var bandAssetHashes: [String] { [header?.image, footer?.image].compactMap { $0 } }
}

/// The look of the paper: plain, a notebook (yellow, ruled, brown top), squared (grid lines) or
/// a checkerboard of white and light grey squares. Squares are always square; `size` is their side
/// (or the line spacing of the notebook) in points.
public struct PaperStyle: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case plain, notebook, grid, checker }
    public var kind: Kind
    public var size: Double
    public init(kind: Kind, size: Double = PageMargins.centimeters(0.5)) { self.kind = kind; self.size = size }
    public static let minimumSize = PageMargins.centimeters(0.3)
    public static let maximumSize = PageMargins.centimeters(2)
    public static let notebookLine = PageMargins.centimeters(0.8)
    public static let notebookTop = PageMargins.centimeters(1.2)
}

/// The writing lines of notebook paper: bands `spacing` tall whose tops are at
/// `origin + k × spacing` (k ≥ 0); the blue rules are the bottoms of the bands. Text on such paper
/// is laid out one band per line (two or more for large type), sitting on the rule.
public struct RuledLines: Equatable, Sendable {
    public var origin: Double
    public var spacing: Double
    public init(origin: Double, spacing: Double) { self.origin = origin; self.spacing = spacing }

    /// How far below `top` the next band starts (0 when `top` is a band top already).
    public func offset(below top: Double) -> Double {
        guard spacing > 0, top.isFinite else { return 0 }
        if top <= origin { return origin - top }
        let rest = (top - origin).truncatingRemainder(dividingBy: spacing)
        return rest < 0.01 || spacing - rest < 0.01 ? 0 : spacing - rest
    }
    /// Top of the band that contains `y` (the line the finger is on).
    public func bandTop(containing y: Double) -> Double {
        guard spacing > 0, y > origin else { return origin }
        return origin + ((y - origin) / spacing).rounded(.down) * spacing
    }
    /// Bands a line of type takes: one up to about the band's height, more for larger type.
    public func bands(forFontSize size: Double) -> Int {
        guard spacing > 0, size.isFinite, size > 0 else { return 1 }
        return max(1, Int((size * 1.05 / spacing).rounded(.up)))
    }
}

public extension CanvasSettings {
    /// Lines that text follows: present when the whole note is on notebook paper.
    var ruledLines: RuledLines? {
        paper?.kind == .notebook ? RuledLines(origin: PaperStyle.notebookTop, spacing: PaperStyle.notebookLine) : nil
    }

    /// A simple note: half an A4 sheet (A5, about the width of a phone at full size), yellow ruled
    /// paper, the text starting on the second line below the binding and a red margin on the left.
    static func simpleNote() -> CanvasSettings {
        var settings = CanvasSettings(size: CanvasSize(width: 148 * 72 / 25.4, height: 210 * 72 / 25.4), recognizeDiagrams: false, solveEquations: false)
        settings.margins = PageMargins(top: PaperStyle.notebookTop + PaperStyle.notebookLine * 0.5, bottom: PageMargins.centimeters(1),
                                       left: PageMargins.centimeters(1.6), right: PageMargins.centimeters(1))
        settings.paper = PaperStyle(kind: .notebook)
        settings.simpleNote = true
        return settings
    }
}

public extension CanvasDocument {
    /// Text that follows the paper's lines: the note's own text (story boxes at the page's top
    /// level) when the whole note is ruled. Text inside shapes, tables and free boxes keeps its size.
    func followsRuledLines(_ blockID: UUID) -> Bool {
        guard canvas.ruledLines != nil, let block = blocks.first(where: { $0.id == blockID }),
              block.parentID == nil, block.textFlowID != nil, case .text = block.content else { return false }
        return true
    }
}

/// Paper on part of one page.
public struct PaperFill: Codable, Equatable, Sendable {
    public enum Region: String, Codable, Sendable, CaseIterable { case full, topHalf, bottomHalf }
    public var style: PaperStyle
    public var region: Region
    public init(style: PaperStyle, region: Region = .full) { self.style = style; self.region = region }

    public func rect(on size: CanvasSize) -> LogicalRect {
        switch region {
        case .full: LogicalRect(x: 0, y: 0, width: size.width, height: size.height)
        case .topHalf: LogicalRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottomHalf: LogicalRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

public extension CanvasDocument {
    /// What to paint on a page, bottom first: the note's paper over the whole page, then the
    /// page's own paper (whole or half).
    func paperFills(on pageID: UUID) -> [PaperFill] {
        var fills: [PaperFill] = []
        if let note = canvas.paper, note.kind != .plain { fills.append(PaperFill(style: note)) }
        if let own = pages.first(where: { $0.id == pageID })?.paper { fills.append(own) }
        return fills
    }
}

extension PaperStyle {
    func validate() throws {
        guard size.isFinite, size >= PaperStyle.minimumSize - 1e-9, size <= PaperStyle.maximumSize + 1e-9 else { throw DocumentError.invalid("Invalid paper square size") }
    }
}
