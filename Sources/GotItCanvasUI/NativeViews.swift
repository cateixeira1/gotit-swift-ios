#if canImport(UIKit)
import UIKit
import GotItDomain
import GotItCanvas

extension NSAttributedString.Key {
    /// Carries BlockStyle.namedStyle through UITextView edits; typing continues the style.
    static let gotItNamedStyle = NSAttributedString.Key("GotItNamedStyle")
}

@MainActor
enum TextBridge {
    /// The system font's internal names (".SFUI-Regular" and the like) must not be looked up by
    /// name: CoreText substitutes another font (its log names Times New Roman), so text saved in
    /// the system font came back with other widths and line breaks. Text in the system font
    /// therefore stores no font name, and such names in older documents mean the system font.
    static func font(named name: String?, size: CGFloat) -> UIFont {
        guard let name, !name.hasPrefix("."), let font = UIFont(name: name, size: size) else { return .systemFont(ofSize: size) }
        return font
    }
    static func storedName(of font: UIFont?) -> String? {
        guard let name = font?.fontName, !name.hasPrefix(".") else { return nil }
        return name
    }

    static func attributed(_ rich: RichText, base: BlockStyle) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for run in rich.runs {
            let style = base.merging(run.style)
            var font = TextBridge.font(named: style.fontName, size: style.fontSize ?? 18)
            var traits = font.fontDescriptor.symbolicTraits
            if style.bold == true { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
            if style.italic == true { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            let paragraph = NSMutableParagraphStyle()
            if let format = style.paragraph {
                paragraph.lineSpacing = format.lineSpacing; paragraph.paragraphSpacing = format.paragraphSpacing
                paragraph.headIndent = format.headIndent; paragraph.firstLineHeadIndent = format.firstLineIndent
                if format.list != .none { paragraph.textLists = [NSTextList(markerFormat: format.list == .bullet ? .disc : .decimal, options: 0)] }
            }
            switch style.alignment {
            case .center: paragraph.alignment = .center
            case .trailing: paragraph.alignment = .right
            case .justified: paragraph.alignment = .justified
            default: paragraph.alignment = .natural
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(hex: style.foreground ?? "#111827"), .paragraphStyle: paragraph]
            if let background = style.background { attributes[.backgroundColor] = UIColor(hex: background) }
            if style.underline == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = style.link, !link.isEmpty { attributes[.link] = link }
            if style.baseline == .superscript { attributes[.baselineOffset] = font.pointSize * 0.35 }
            if style.baseline == .subscript { attributes[.baselineOffset] = -font.pointSize * 0.2 }
            if let named = style.namedStyle { attributes[.gotItNamedStyle] = named }
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return output
    }

    /// Text on notebook paper: every line of a paragraph takes whole bands of the paper (one, or
    /// more for large type) with no space added between lines, so each line sits on a rule (TextKit
    /// puts the extra height of a fixed line above the letters). Paragraph spacing becomes whole
    /// lines. Returns whether anything changed (callers avoid rewriting text being typed).
    @discardableResult
    static func rule(_ text: NSMutableAttributedString, lines: RuledLines) -> Bool {
        let string = text.string as NSString
        var changed = false, location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var size: CGFloat = 0
            text.enumerateAttribute(.font, in: paragraph) { value, _, _ in size = max(size, (value as? UIFont)?.pointSize ?? 18) }
            let first = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
            let wanted = ruled(first, fontSize: size, lines: lines)
            var matches = true
            text.enumerateAttribute(.paragraphStyle, in: paragraph) { value, _, stop in
                if (value as? NSParagraphStyle) != wanted { matches = false; stop.pointee = true }
            }
            if !matches { text.addAttribute(.paragraphStyle, value: wanted, range: paragraph); changed = true }
            location = NSMaxRange(paragraph)
        }
        return changed
    }

    /// `style` with the fixed line height of type of `fontSize` on the paper's lines.
    static func ruled(_ style: NSParagraphStyle, fontSize: CGFloat, lines: RuledLines) -> NSParagraphStyle {
        let band = CGFloat(lines.spacing)
        let height = CGFloat(lines.bands(forFontSize: Double(fontSize))) * band
        if style.minimumLineHeight == height, style.maximumLineHeight == height, style.lineSpacing == 0, style.lineHeightMultiple == 0,
           style.paragraphSpacingBefore == 0, (style.paragraphSpacing / band).rounded() * band == style.paragraphSpacing { return style }
        let fixed = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        fixed.minimumLineHeight = height; fixed.maximumLineHeight = height
        fixed.lineSpacing = 0; fixed.lineHeightMultiple = 0; fixed.paragraphSpacingBefore = 0
        fixed.paragraphSpacing = (style.paragraphSpacing / band).rounded() * band
        return fixed
    }

    /// Typing attributes that continue on the paper's lines.
    static func ruledTyping(_ attributes: [NSAttributedString.Key: Any], lines: RuledLines) -> [NSAttributedString.Key: Any] {
        var typing = attributes
        let size = (attributes[.font] as? UIFont)?.pointSize ?? 18
        typing[.paragraphStyle] = ruled(attributes[.paragraphStyle] as? NSParagraphStyle ?? .default, fontSize: size, lines: lines)
        return typing
    }

    /// The text of a block as shown on its page: on ruled paper, laid out on the lines.
    static func shown(_ rich: RichText, block id: UUID, in document: CanvasDocument) -> NSAttributedString {
        let text = attributed(rich, base: (try? document.resolvedStyle(for: id)) ?? .init())
        guard document.followsRuledLines(id), let lines = document.canvas.ruledLines else { return text }
        let mutable = NSMutableAttributedString(attributedString: text)
        rule(mutable, lines: lines)
        return mutable
    }

    static func richText(_ text: NSAttributedString) -> RichText {
        var runs: [TextRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let font = attributes[.font] as? UIFont
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let alignment: TextAlignment
            switch paragraph?.alignment { case .center: alignment = .center; case .right: alignment = .trailing; case .justified: alignment = .justified; default: alignment = .leading }
            let offset = (attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
            let link = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            let list: TextListKind = paragraph?.textLists.first.map { $0.markerFormat == .decimal ? .numbered : .bullet } ?? .none
            let format = ParagraphFormat(lineSpacing: Double(paragraph?.lineSpacing ?? 0), paragraphSpacing: Double(paragraph?.paragraphSpacing ?? 0),
                                         headIndent: Double(paragraph?.headIndent ?? 0), firstLineIndent: Double(paragraph?.firstLineHeadIndent ?? 0), list: list)
            let style = BlockStyle(fontName: TextBridge.storedName(of: font), fontSize: font.map { Double($0.pointSize) },
                bold: font?.fontDescriptor.symbolicTraits.contains(.traitBold), italic: font?.fontDescriptor.symbolicTraits.contains(.traitItalic),
                foreground: (attributes[.foregroundColor] as? UIColor)?.hex, background: (attributes[.backgroundColor] as? UIColor)?.hex,
                alignment: alignment, underline: ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0,
                strikethrough: ((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0,
                baseline: offset == 0 ? .normal : (offset > 0 ? .superscript : .subscript), link: link, paragraph: format,
                namedStyle: attributes[.gotItNamedStyle] as? String)
            runs.append(TextRun(text.attributedSubstring(from: range).string, style: style))
        }
        return RichText(runs: runs)
    }
}

/// Draws a table the same way at any frame size: the grid is scaled to the view bounds.
@MainActor enum TableRendering {
    /// Cell text is justified unless the user picks another alignment for it.
    static func base(header: Bool) -> BlockStyle { BlockStyle(fontSize: 16, bold: header ? true : nil, foreground: "#111827", alignment: .justified) }

    static func draw(_ table: CanvasTable, in bounds: CGRect) {
        let sx = bounds.width / max(1, table.width), sy = bounds.height / max(1, table.height)
        for row in 0..<table.rowCount {
            for column in 0..<table.columnCount {
                let f = table.frame(row: row, column: column)
                let rect = CGRect(x: f.x * sx, y: f.y * sy, width: f.width * sx, height: f.height * sy)
                let header = table.headerRow && row == 0
                if let background = table.cells[row][column].background { UIColor(hex: background).setFill(); UIRectFill(rect) }
                else if header { UIColor(hex: "#F3F4F6").setFill(); UIRectFill(rect) }
                let text = TextBridge.attributed(table.cells[row][column].text, base: base(header: header))
                text.draw(with: rect.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
        }
        guard table.borderWidth > 0 else { return }
        let path = UIBezierPath()
        var x = 0.0
        for edge in [0.0] + table.columnWidths {
            x += edge
            path.move(to: CGPoint(x: x * sx, y: 0)); path.addLine(to: CGPoint(x: x * sx, y: bounds.height))
        }
        var y = 0.0
        for edge in [0.0] + table.rowHeights {
            y += edge
            path.move(to: CGPoint(x: 0, y: y * sy)); path.addLine(to: CGPoint(x: bounds.width, y: y * sy))
        }
        UIColor(hex: table.borderColor).setStroke(); path.lineWidth = table.borderWidth; path.stroke()
    }
}

extension UIColor {
    convenience init(hex: String) {
        let text = String(hex.dropFirst())
        let value = UInt64(text, radix: 16) ?? 0
        let rgba = text.count == 8 ? value : (value << 8) | 255
        self.init(red: CGFloat((rgba >> 24) & 255) / 255, green: CGFloat((rgba >> 16) & 255) / 255,
                  blue: CGFloat((rgba >> 8) & 255) / 255, alpha: CGFloat(rgba & 255) / 255)
    }
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }
}

@MainActor
final class CanvasObjectView: UIView, UIContextMenuInteractionDelegate {
    var id: UUID?
    var block: CanvasBlock?
    var asset: UIImage?
    var note: NoteCardPresentation?
    /// Audio blocks: length, position (0…1) and whether it is playing.
    var audioDuration: TimeInterval?
    var audioProgress: Double = 0 { didSet { if audioProgress != oldValue { setNeedsDisplay() } } }
    var audioPlaying = false { didSet { if audioPlaying != oldValue { setNeedsDisplay() } } }
    var onMenu: (() -> UIMenu)?
    /// Where the context menu was invoked, in this view's coordinates (tables use it to
    /// know which row/column the menu acts on).
    var menuLocation: CGPoint?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        menuLocation = location
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.onMenu?() })
    }
    private func maskPath(_ kind: ShapeKind?, in area: CGRect) -> UIBezierPath {
        switch kind {
        case .ellipse: return UIBezierPath(ovalIn: area)
        case .diamond: return polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.midY), .init(x: area.midX, y: area.maxY), .init(x: area.minX, y: area.midY)])
        case .triangle: return polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.maxY), .init(x: area.minX, y: area.maxY)])
        default: return UIBezierPath(rect: area)
        }
    }
    private func corners(_ fractions: [CanvasPoint], in area: CGRect) -> [CGPoint] {
        fractions.map { CGPoint(x: area.minX + $0.x * area.width, y: area.minY + $0.y * area.height) }
    }

    override func draw(_ rect: CGRect) {
        guard let block else { return }
        switch block.content {
        case .shape(let shape):
            if shape.kind == .stickyNote { StickerArt.drawStickyNote(in: bounds, color: UIColor(hex: shape.fill ?? "#FFF27A")); accessibilityLabel = "Post-it"; return }
            if shape.kind == .calendar {
                let day = Stickers.day(from: shape.date) ?? Date()
                StickerArt.drawCalendar(in: bounds, day: day)
                accessibilityLabel = "Calendário, " + day.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "pt_BR")))
                return
            }
            if shape.kind == .transcript {
                let icon = UIImage(systemName: "waveform.and.person.filled") ?? UIImage(systemName: "text.bubble")
                if shape.folded != nil {
                    // Folded: a small rounded square with the icon; a tap opens it again.
                    let card = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: min(14, bounds.width / 4))
                    UIColor(hex: shape.fill ?? "#F5F7FB").setFill(); card.fill()
                    UIColor(hex: shape.stroke).setStroke(); card.lineWidth = 1; card.stroke()
                    let side = min(bounds.width, bounds.height) * 0.42
                    icon?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side * 0.5, width: side, height: side * 0.9))
                    let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold))
                    chevron?.withTintColor(.systemIndigo.withAlphaComponent(0.7), renderingMode: .alwaysOriginal)
                        .draw(at: CGPoint(x: bounds.midX - 4, y: bounds.maxY - 13))
                    accessibilityLabel = "Transcrição recolhida"; accessibilityHint = "Toque para abrir"
                    return
                }
                // Card with a header: speech-bubble icon and "Transcrição"; the text is the child block.
                // A tap on the header folds it (the chevron on the right says so).
                let card = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 12)
                UIColor(hex: shape.fill ?? "#F5F7FB").setFill(); card.fill()
                UIColor(hex: shape.stroke).setStroke(); card.lineWidth = 1; card.stroke()
                icon?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 12, y: 9, width: 18, height: 16))
                NSAttributedString(string: "Transcrição", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.systemIndigo])
                    .draw(at: CGPoint(x: 36, y: 9))
                let chevron = UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
                chevron?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: bounds.maxX - 26, y: 10))
                UIColor(hex: "#DDE3EC").setFill(); UIBezierPath(rect: CGRect(x: 12, y: 30, width: bounds.width - 24, height: 1)).fill()
                accessibilityLabel = "Transcrição"; accessibilityHint = "Toque no cabeçalho para recolher"
                return
            }
            let area = bounds.insetBy(dx: shape.lineWidth / 2, dy: shape.lineWidth / 2)
            let path: UIBezierPath
            switch shape.kind {
            case .ellipse: path = UIBezierPath(ovalIn: area)
            case .rectangle, .stickyNote, .calendar, .transcript: path = UIBezierPath(rect: area)
            case .diamond:
                path = polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.midY), .init(x: area.midX, y: area.maxY), .init(x: area.minX, y: area.midY)])
            case .triangle: path = polygon(corners(shape.triangleCorners, in: area))
            case .line, .arrow:
                path = UIBezierPath()
                let first = shape.originalStroke?.points.first ?? .init(x: 0, y: 0)
                let last = shape.originalStroke?.points.last ?? .init(x: bounds.width, y: bounds.height)
                let sx = bounds.width / max(1, shape.originalStroke?.points.map(\.x).max() ?? bounds.width)
                let sy = bounds.height / max(1, shape.originalStroke?.points.map(\.y).max() ?? bounds.height)
                path.move(to: CGPoint(x: first.x * sx, y: first.y * sy)); path.addLine(to: CGPoint(x: last.x * sx, y: last.y * sy))
            }
            if let fill = shape.fill, shape.kind != .line, shape.kind != .arrow { UIColor(hex: fill).setFill(); path.fill() }
            UIColor(hex: shape.stroke).setStroke(); path.lineWidth = shape.lineWidth; path.stroke()
            accessibilityLabel = "Forma \(shape.kind.rawValue)"
        case .ink(let stroke):
            let path = UIBezierPath()
            let sx = bounds.width / max(1, stroke.points.map(\.x).max() ?? bounds.width)
            let sy = bounds.height / max(1, stroke.points.map(\.y).max() ?? bounds.height)
            for (index, point) in stroke.points.enumerated() {
                if index == 0 { path.move(to: .init(x: point.x * sx, y: point.y * sy)) } else { path.addLine(to: .init(x: point.x * sx, y: point.y * sy)) }
            }
            UIColor(hex: stroke.color).setStroke(); path.lineWidth = stroke.width; path.lineCapStyle = .round; path.stroke()
            accessibilityLabel = "Desenho"
        case .image, .sticker:
            if let asset {
                let crop = block.effectivePresentation.imageCrop ?? .init(x: 0, y: 0, width: 1, height: 1)
                guard crop.width > 0, crop.height > 0 else { return }
                UIGraphicsGetCurrentContext()?.saveGState()
                maskPath(block.effectivePresentation.imageMask, in: bounds).addClip()
                asset.draw(in: CGRect(x: -crop.x * bounds.width / crop.width, y: -crop.y * bounds.height / crop.height,
                                      width: bounds.width / crop.width, height: bounds.height / crop.height))
                UIGraphicsGetCurrentContext()?.restoreGState()
            } else { placeholder("Imagem indisponível") }
        case .noteReference:
            // A darker grey card with a visible outline, so it stands out on the white canvas.
            let card = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12)
            UIColor(hex: "#E2E5EA").setFill(); card.fill()
            UIColor(hex: "#8B95A3").setStroke(); card.lineWidth = 1.5; card.stroke()
            let previewFrame = CGRect(x: 8, y: 8, width: max(1, bounds.width - 16), height: max(1, bounds.height - 66))
            if let preview = note?.preview { preview.draw(in: previewFrame) }
            else { UIColor.white.setFill(); UIBezierPath(rect: previewFrame).fill() }
            UIColor(hex: "#AEB6C1").setStroke(); let frame = UIBezierPath(rect: previewFrame); frame.lineWidth = 1; frame.stroke()
            let title = note?.title ?? "Nota indisponível"
            (title as NSString).draw(in: CGRect(x: 10, y: bounds.height - 52, width: bounds.width - 20, height: 24), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.black])
            if let note { (note.createdAt.formatted(date: .abbreviated, time: .shortened) as NSString).draw(in: CGRect(x: 10, y: bounds.height - 27, width: bounds.width - 20, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]) }
            accessibilityLabel = title
        case .pdf:
            if let asset { asset.draw(in: bounds) } else { placeholder("PDF indisponível") }
        case .audio(let reference):
            AudioArt.draw(in: bounds, seed: reference.hash, duration: audioDuration, progress: audioProgress, playing: audioPlaying)
            accessibilityLabel = "Áudio"
            accessibilityValue = audioDuration.map { AudioArt.time($0) }
            accessibilityHint = audioPlaying ? "Toque para pausar" : "Toque para ouvir"
        case .video:
            // First frame (filling the block, rounded), a dark veil and a play button.
            let card = UIBezierPath(roundedRect: bounds, cornerRadius: 10)
            UIGraphicsGetCurrentContext()?.saveGState(); card.addClip()
            if let asset {
                let scale = max(bounds.width / max(1, asset.size.width), bounds.height / max(1, asset.size.height))
                let size = CGSize(width: asset.size.width * scale, height: asset.size.height * scale)
                asset.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            } else { UIColor(hex: "#1F2937").setFill(); card.fill() }
            UIColor.black.withAlphaComponent(0.18).setFill(); card.fill()
            UIGraphicsGetCurrentContext()?.restoreGState()
            let diameter = min(56, min(bounds.width, bounds.height) * 0.4)
            let circle = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            UIColor.white.withAlphaComponent(0.9).setFill(); UIBezierPath(ovalIn: circle).fill()
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: circle.midX - diameter * 0.14, y: circle.midY - diameter * 0.22))
            triangle.addLine(to: CGPoint(x: circle.midX + diameter * 0.24, y: circle.midY))
            triangle.addLine(to: CGPoint(x: circle.midX - diameter * 0.14, y: circle.midY + diameter * 0.22))
            triangle.close(); UIColor(hex: "#111827").setFill(); triangle.fill()
            accessibilityLabel = "Vídeo"; accessibilityHint = "Toque para assistir"
        case .drawing: placeholder("Desenho PencilKit")
        case .table(let table):
            TableRendering.draw(table, in: bounds)
            accessibilityLabel = "Tabela \(table.rowCount) × \(table.columnCount)"
            accessibilityValue = table.plainText
        case .container, .text: break
        }
    }
    private func placeholder(_ title: String) {
        UIColor.systemGray6.setFill(); UIBezierPath(roundedRect: bounds, cornerRadius: 10).fill()
        (title as NSString).draw(in: bounds.insetBy(dx: 12, dy: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.darkGray])
        accessibilityLabel = title
    }
    private func polygon(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() { if index == 0 { path.move(to: point) } else { path.addLine(to: point) } }
        path.close(); return path
    }
}

/// Drawn stickers. The sticky note is paper glued along its top edge, its lower right corner
/// lifting a little; the calendar follows the look of the calendar emoji (red band with the month,
/// binder rings, a big day number), but shows the day the user picks.
@MainActor enum StickerArt {
    static func shade(_ color: UIColor, _ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }
    static func curl(for bounds: CGRect) -> CGFloat { min(bounds.width, bounds.height) * 0.12 }

    static func drawStickyNote(in bounds: CGRect, color: UIColor) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 4, bounds.height > 4 else { return }
        let w = bounds.width, h = bounds.height, c = curl(for: bounds)
        let paper = UIBezierPath()
        paper.move(to: .zero)
        paper.addLine(to: CGPoint(x: w, y: 0))
        paper.addLine(to: CGPoint(x: w, y: h - c))
        paper.addQuadCurve(to: CGPoint(x: w - c, y: h), controlPoint: CGPoint(x: w - c * 0.22, y: h - c * 0.22))
        paper.addLine(to: CGPoint(x: 0, y: h))
        paper.close()
        context.saveGState()
        paper.addClip()
        color.setFill(); UIRectFill(bounds)
        // Light falls from the glued edge: a touch brighter at the top, a touch darker at the bottom.
        let colors = [UIColor.white.withAlphaComponent(0.25).cgColor, UIColor.white.withAlphaComponent(0).cgColor,
                      UIColor.black.withAlphaComponent(0.07).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        // The glued strip is a little more opaque.
        UIColor.black.withAlphaComponent(0.04).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: w, height: h * 0.12))
        context.restoreGState()
        // The back of the lifted corner.
        let fold = UIBezierPath()
        fold.move(to: CGPoint(x: w, y: h - c))
        fold.addQuadCurve(to: CGPoint(x: w - c, y: h), controlPoint: CGPoint(x: w - c * 0.22, y: h - c * 0.22))
        fold.addQuadCurve(to: CGPoint(x: w, y: h - c), controlPoint: CGPoint(x: w - c * 0.9, y: h - c * 0.9))
        shade(color, 0.84).setFill(); fold.fill()
        UIColor.black.withAlphaComponent(0.08).setStroke(); fold.lineWidth = 0.5; fold.stroke()
    }

    /// Shadow under paper glued at the top: thin at the top edge, deeper under the loose bottom.
    static func stickyNoteShadow(for bounds: CGRect) -> UIBezierPath {
        let w = bounds.width, h = bounds.height, c = curl(for: bounds)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 3, y: h * 0.1))
        path.addLine(to: CGPoint(x: w - 3, y: h * 0.1))
        path.addLine(to: CGPoint(x: w - 1, y: h - c * 1.2))
        path.addQuadCurve(to: CGPoint(x: w - c * 1.2, y: h + 2), controlPoint: CGPoint(x: w - c * 0.1, y: h + 1))
        path.addQuadCurve(to: CGPoint(x: 1, y: h + 1), controlPoint: CGPoint(x: w * 0.45, y: h + 5))
        path.close()
        return path
    }

    static func drawCalendar(in bounds: CGRect, day: Date) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 8, bounds.height > 8 else { return }
        let w = bounds.width, h = bounds.height
        let page = CGRect(x: 1, y: h * 0.07, width: w - 2, height: h * 0.93 - 1)
        let body = UIBezierPath(roundedRect: page, cornerRadius: w * 0.12)
        UIColor.white.setFill(); body.fill()
        // Red band with the month.
        let band = CGRect(x: page.minX, y: page.minY, width: page.width, height: page.height * 0.3)
        context.saveGState()
        body.addClip()
        let red = [UIColor(red: 0.96, green: 0.36, blue: 0.31, alpha: 1).cgColor, UIColor(red: 0.84, green: 0.2, blue: 0.17, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: red, locations: [0, 1]) {
            context.addRect(band); context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
        }
        context.restoreGState()
        // A faint line where the page below shows.
        UIColor.black.withAlphaComponent(0.06).setFill()
        UIRectFill(CGRect(x: page.minX + w * 0.06, y: page.maxY - h * 0.035, width: page.width - w * 0.12, height: 1))
        UIColor.black.withAlphaComponent(0.14).setStroke(); body.lineWidth = 1; body.stroke()
        // Binder rings across the top edge.
        for x in [w * 0.3, w * 0.7] {
            let ring = UIBezierPath(roundedRect: CGRect(x: x - w * 0.035, y: 0, width: w * 0.07, height: h * 0.15), cornerRadius: w * 0.035)
            UIColor(red: 0.42, green: 0.45, blue: 0.5, alpha: 1).setFill(); ring.fill()
            UIColor.white.withAlphaComponent(0.35).setFill()
            UIBezierPath(roundedRect: CGRect(x: x - w * 0.018, y: h * 0.01, width: w * 0.018, height: h * 0.11), cornerRadius: w * 0.009).fill()
        }
        let locale = Locale(identifier: "pt_BR")
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.dateFormat = "MMM"
        let month = formatter.string(from: day).replacingOccurrences(of: ".", with: "").uppercased(with: locale)
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: day)
        formatter.dateFormat = "d"
        let number = formatter.string(from: day)
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        func draw(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, centerY: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: centered]
            let height = (text as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(in: CGRect(x: page.minX, y: centerY - height / 2, width: page.width, height: height), withAttributes: attributes)
        }
        draw(month, size: band.height * 0.5, weight: .bold, color: .white, centerY: band.midY + band.height * 0.06)
        let rest = page.height - band.height
        draw(number, size: rest * 0.56, weight: .semibold, color: UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1), centerY: band.maxY + rest * 0.43)
        draw(weekday, size: rest * 0.13, weight: .medium, color: UIColor(red: 0.42, green: 0.45, blue: 0.5, alpha: 1), centerY: band.maxY + rest * 0.83)
    }
}

@MainActor
final class ConnectionView: UIView, UIContextMenuInteractionDelegate {
    var relation: BlockRelation?
    var points: [CanvasPoint] = []
    var onUpdate: ((BlockRelation) -> Void)?
    var onDelete: (() -> Void)?
    var isChronology = false
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; addInteraction(UIContextMenuInteraction(delegate: self)) }
    required init?(coder: NSCoder) { fatalError() }
    private var path: UIBezierPath {
        let path = UIBezierPath()
        for (index, p) in points.enumerated() { if index == 0 { path.move(to: .init(x: p.x, y: p.y)) } else { path.addLine(to: .init(x: p.x, y: p.y)) } }
        return path
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        path.cgPath.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 0).contains(point)
    }
    override func draw(_ rect: CGRect) {
        let style = relation?.style ?? .init()
        let line = path
        if isChronology { line.setLineDash([5, 5], count: 2, phase: 0) }
        UIColor(hex: style.color).setStroke(); line.lineWidth = style.width; line.stroke()
        if style.arrowAtEnd, let end = points.last, let previous = points.dropLast().last {
            let angle = atan2(end.y - previous.y, end.x - previous.x)
            let arrow = UIBezierPath(); arrow.move(to: .init(x: end.x - 10 * cos(angle - .pi / 6), y: end.y - 10 * sin(angle - .pi / 6)))
            arrow.addLine(to: .init(x: end.x, y: end.y)); arrow.addLine(to: .init(x: end.x - 10 * cos(angle + .pi / 6), y: end.y - 10 * sin(angle + .pi / 6)))
            arrow.lineWidth = style.width; arrow.stroke()
        }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self, let relation = self.relation else { return nil }
            let colors = [("Azul", "#2563EB"), ("Verde", "#16A34A"), ("Coral", "#F97316"), ("Preto", "#111827")]
            return UIMenu(children: colors.map { name, color in
                UIAction(title: name) { _ in var changed = relation; var style = changed.style ?? .init(); style.color = color; changed.style = style; self.onUpdate?(changed) }
            } + [UIAction(title: "Excluir conexão", attributes: .destructive) { _ in self.onDelete?() }])
        })
    }
}

/// A recorded or imported audio on the page: a rounded player with a play/pause button, a
/// waveform (drawn from the file's hash, the same every time) that fills as it plays, and the time.
@MainActor enum AudioArt {
    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func draw(in bounds: CGRect, seed: String, duration: TimeInterval?, progress: Double, playing: Bool) {
        let card = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: min(22, bounds.height / 2))
        UIColor(hex: "#EEF2F7").setFill(); card.fill()
        UIColor(hex: "#C5CEDA").setStroke(); card.lineWidth = 1; card.stroke()
        let diameter = min(bounds.height - 16, 40)
        let button = CGRect(x: 10, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        UIColor.systemBlue.setFill(); UIBezierPath(ovalIn: button).fill()
        UIColor.white.setFill()
        if playing {
            let w = diameter * 0.12, h = diameter * 0.4
            UIBezierPath(rect: CGRect(x: button.midX - w * 1.6, y: button.midY - h / 2, width: w, height: h)).fill()
            UIBezierPath(rect: CGRect(x: button.midX + w * 0.6, y: button.midY - h / 2, width: w, height: h)).fill()
        } else {
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: button.midX - diameter * 0.14, y: button.midY - diameter * 0.22))
            triangle.addLine(to: CGPoint(x: button.midX + diameter * 0.24, y: button.midY))
            triangle.addLine(to: CGPoint(x: button.midX - diameter * 0.14, y: button.midY + diameter * 0.22))
            triangle.close(); triangle.fill()
        }
        let label = duration.map { playing || progress > 0 ? time($0 * progress) + " / " + time($0) : time($0) } ?? "Áudio"
        let text = NSAttributedString(string: label, attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: UIColor(hex: "#475569")])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.maxX - size.width - 14, y: bounds.midY - size.height / 2))
        let wave = CGRect(x: button.maxX + 10, y: bounds.minY + 12, width: max(10, bounds.maxX - size.width - 24 - button.maxX - 10), height: bounds.height - 24)
        var value: UInt64 = seed.utf8.reduce(5381) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        let bars = max(4, Int(wave.width / 5))
        for index in 0..<bars {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            let height = wave.height * (0.25 + 0.75 * Double(value >> 40 & 0xFF) / 255)
            let x = wave.minX + CGFloat(index) * wave.width / CGFloat(bars)
            let played = Double(index) / Double(bars) < progress
            (played ? UIColor.systemBlue : UIColor(hex: "#94A3B8")).setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: wave.midY - height / 2, width: 2.5, height: height), cornerRadius: 1.25).fill()
        }
    }
}
#endif
