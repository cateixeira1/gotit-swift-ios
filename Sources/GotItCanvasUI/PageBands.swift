#if canImport(UIKit)
import UIKit
import GotItDomain

/// The header, footer and page number of one page, drawn behind everything on it.
@MainActor final class PageBandsView: UIView {
    var settings = CanvasSettings() { didSet { if settings != oldValue { setNeedsDisplay() } } }
    var pageIndex = 0 { didSet { if pageIndex != oldValue { setNeedsDisplay() } } }
    var pageCount = 1 { didSet { if pageCount != oldValue { setNeedsDisplay() } } }
    var image: (String) -> UIImage? = { _ in nil }
    /// Paper painted under everything (notebook, squares, checkerboard).
    var fills: [PaperFill] = [] { didSet { if fills != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false; contentMode = .redraw
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Number shown on this page (for tests and accessibility).
    var numberLabel: String? { settings.pageNumbers?.label(index: pageIndex, count: pageCount) }

    override func draw(_ rect: CGRect) {
        Self.draw(settings, pageIndex: pageIndex, pageCount: pageCount, image: image, fills: fills)
    }

    /// Draws into the current context, in page coordinates (also used for page thumbnails).
    static func draw(_ settings: CanvasSettings, pageIndex: Int, pageCount: Int, image: (String) -> UIImage?, fills: [PaperFill] = []) {
        for fill in fills { paint(fill, settings: settings) }
        let m = settings.pageMargins
        if let header = settings.header, let strip = settings.headerRect { draw(header, in: strip, inset: m, image: image) }
        if let footer = settings.footer, let strip = settings.footerRect { draw(footer, in: strip, inset: m, image: image) }
        if let label = settings.pageNumbers?.label(index: pageIndex, count: pageCount), let place = settings.pageNumberRect, let numbers = settings.pageNumbers {
            let font = UIFont.systemFont(ofSize: 11)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor(hex: "#4B5563")])
            let size = text.size()
            let x: CGFloat
            switch numbers.alignment {
            case .leading: x = place.x
            case .center: x = place.x + (place.width - size.width) / 2
            case .trailing: x = place.x + place.width - size.width
            }
            text.draw(at: CGPoint(x: x, y: place.y + (place.height - size.height) / 2))
        }
    }

    /// Paper in its region: notebook (yellow, ruled, red margin, brown top), squares or checkerboard.
    static func paint(_ fill: PaperFill, settings: CanvasSettings) {
        let r = fill.rect(on: settings.size)
        let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.clip(to: rect)
        let step = CGFloat(max(PaperStyle.minimumSize, fill.style.size))
        switch fill.style.kind {
        case .plain:
            UIColor.white.setFill(); context.fill(rect)
        case .notebook:
            UIColor(hex: "#FFF3AE").setFill(); context.fill(rect)
            let top = rect.minY == 0 ? CGFloat(PaperStyle.notebookTop) : 0
            let line = CGFloat(PaperStyle.notebookLine)
            UIColor(hex: "#9DBEDD").setStroke()
            let rules = UIBezierPath(); rules.lineWidth = 0.7
            var y = rect.minY + top + line
            while y < rect.maxY { rules.move(to: CGPoint(x: rect.minX, y: y)); rules.addLine(to: CGPoint(x: rect.maxX, y: y)); y += line }
            rules.stroke()
            let marginX = CGFloat(settings.textArea.x) - 10
            UIColor(hex: "#E06666").setStroke()
            let margin = UIBezierPath(); margin.lineWidth = 0.9
            margin.move(to: CGPoint(x: marginX, y: rect.minY + top)); margin.addLine(to: CGPoint(x: marginX, y: rect.maxY))
            margin.move(to: CGPoint(x: marginX - 3, y: rect.minY + top)); margin.addLine(to: CGPoint(x: marginX - 3, y: rect.maxY))
            margin.stroke()
            if top > 0 {
                // The brown binding at the top of a legal pad, with a darker edge.
                UIColor(hex: "#7A4A2B").setFill(); context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: top))
                UIColor(hex: "#5C361E").setFill(); context.fill(CGRect(x: rect.minX, y: rect.minY + top - 2, width: rect.width, height: 2))
            }
        case .grid:
            UIColor.white.setFill(); context.fill(rect)
            UIColor(hex: "#CFD7E1").setStroke()
            let grid = UIBezierPath(); grid.lineWidth = 0.5
            var x = rect.minX
            while x <= rect.maxX { grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
            var y = rect.minY
            while y <= rect.maxY { grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
            grid.stroke()
        case .checker:
            UIColor.white.setFill(); context.fill(rect)
            UIColor(hex: "#ECEFF3").setFill()
            var row = 0, y = rect.minY
            while y < rect.maxY {
                var x = rect.minX + CGFloat(row % 2) * step
                while x < rect.maxX { context.fill(CGRect(x: x, y: y, width: step, height: step)); x += 2 * step }
                y += step; row += 1
            }
        }
        context.restoreGState()
    }

    /// Picture fitted in the strip (between the side margins), text below it or centred alone.
    private static func draw(_ band: PageBand, in strip: LogicalRect, inset m: PageMargins, image: (String) -> UIImage?) {
        let area = CGRect(x: m.left, y: strip.y + 6, width: max(1, strip.width - m.left - m.right), height: max(1, strip.height - 12))
        var textArea = area
        if let hash = band.image, let picture = image(hash), picture.size.width > 0, picture.size.height > 0 {
            let room = band.text.isEmpty ? area : CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - 16)
            let scale = min(room.width / picture.size.width, room.height / picture.size.height)
            let size = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            let x: CGFloat
            switch band.alignment {
            case .leading: x = room.minX
            case .center: x = room.midX - size.width / 2
            case .trailing: x = room.maxX - size.width
            }
            picture.draw(in: CGRect(x: x, y: room.midY - size.height / 2, width: size.width, height: size.height))
            textArea = CGRect(x: area.minX, y: area.maxY - 16, width: area.width, height: 16)
        }
        guard !band.text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = band.alignment == .leading ? .left : band.alignment == .center ? .center : .right
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: band.text, attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor(hex: "#4B5563"), .paragraphStyle: paragraph])
        let height = text.boundingRect(with: CGSize(width: textArea.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height
        text.draw(with: CGRect(x: textArea.minX, y: textArea.midY - min(height, textArea.height) / 2, width: textArea.width, height: min(height, textArea.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

/// While an object is moved or resized into the header or footer: a light grey dashed line at the
/// strip's edge and a short notice. Both go away when the object leaves the strip or is let go.
@MainActor final class BandGuidesView: UIView {
    private let lines = CAShapeLayer()
    let notice = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear
        lines.strokeColor = UIColor(white: 0.72, alpha: 1).cgColor
        lines.fillColor = nil; lines.lineWidth = 1; lines.lineDashPattern = [6, 4]
        layer.addSublayer(lines)
        notice.font = .systemFont(ofSize: 12, weight: .medium); notice.textColor = .white
        notice.backgroundColor = UIColor(white: 0.25, alpha: 0.85); notice.textAlignment = .center
        notice.layer.cornerRadius = 10; notice.clipsToBounds = true
        notice.accessibilityIdentifier = "bandInvasionNotice"
        addSubview(notice)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the edges of the strips `frame` runs into; hides everything when it runs into none.
    func show(for frame: LogicalRect, settings: CanvasSettings) {
        let invaded = settings.bandsInvaded(by: frame)
        guard !invaded.isEmpty else { hide(); return }
        let path = UIBezierPath()
        var names: [String] = []
        for band in invaded {
            let header = band.y == 0
            let y = header ? band.y + band.height : band.y
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y))
            names.append(header ? "o cabeçalho" : "o rodapé")
        }
        lines.frame = bounds; lines.path = path.cgPath
        notice.text = "Este bloco está invadindo \(names.joined(separator: " e "))"
        let size = notice.intrinsicContentSize
        let header = invaded.contains { $0.y == 0 }
        let y = header ? (invaded.first { $0.y == 0 }.map { $0.height + 10 } ?? 10) : (invaded.first { $0.y > 0 }.map { $0.y - size.height - 18 } ?? 10)
        notice.frame = CGRect(x: (bounds.width - size.width - 24) / 2, y: y, width: size.width + 24, height: size.height + 8)
        isHidden = false
    }

    func hide() { isHidden = true; lines.path = nil }
}

/// Paper drawing for previews outside the editor (the paper picker).
@MainActor public enum PaperPreviewDrawing {
    public static func draw(_ style: PaperStyle, settings: CanvasSettings) {
        PageBandsView.paint(PaperFill(style: style, region: .topHalf), settings: settings)
    }
}
#endif
