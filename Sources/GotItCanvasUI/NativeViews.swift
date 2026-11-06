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
    static func attributed(_ rich: RichText, base: BlockStyle) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for run in rich.runs {
            let style = base.merging(run.style)
            var font = style.fontName.flatMap { UIFont(name: $0, size: style.fontSize ?? 18) } ?? UIFont.systemFont(ofSize: style.fontSize ?? 18)
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
            let style = BlockStyle(fontName: font?.fontName, fontSize: font.map { Double($0.pointSize) },
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
    var onMenu: (() -> UIMenu)?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.onMenu?() })
    }
    private func maskPath(_ kind: ShapeKind?, in area: CGRect) -> UIBezierPath {
        switch kind {
        case .ellipse: return UIBezierPath(ovalIn: area)
        case .diamond: return polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.midY), .init(x: area.midX, y: area.maxY), .init(x: area.minX, y: area.midY)])
        case .triangle: return polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.maxY), .init(x: area.minX, y: area.maxY)])
        default: return UIBezierPath(rect: area)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let block else { return }
        switch block.content {
        case .shape(let shape):
            let area = bounds.insetBy(dx: shape.lineWidth / 2, dy: shape.lineWidth / 2)
            let path: UIBezierPath
            switch shape.kind {
            case .ellipse: path = UIBezierPath(ovalIn: area)
            case .rectangle: path = UIBezierPath(rect: area)
            case .diamond:
                path = polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.midY), .init(x: area.midX, y: area.maxY), .init(x: area.minX, y: area.midY)])
            case .triangle: path = polygon([CGPoint(x: area.midX, y: area.minY), .init(x: area.maxX, y: area.maxY), .init(x: area.minX, y: area.maxY)])
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
            UIColor(hex: "#F8FAFC").setFill(); UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12).fill()
            let previewFrame = CGRect(x: 8, y: 8, width: max(1, bounds.width - 16), height: max(1, bounds.height - 66))
            if let preview = note?.preview { preview.draw(in: previewFrame) }
            else { UIColor.white.setFill(); UIBezierPath(rect: previewFrame).fill() }
            let title = note?.title ?? "Nota indisponível"
            (title as NSString).draw(in: CGRect(x: 10, y: bounds.height - 52, width: bounds.width - 20, height: 24), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.black])
            if let note { (note.createdAt.formatted(date: .abbreviated, time: .shortened) as NSString).draw(in: CGRect(x: 10, y: bounds.height - 27, width: bounds.width - 20, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]) }
            accessibilityLabel = title
        case .pdf:
            if let asset { asset.draw(in: bounds) } else { placeholder("PDF indisponível") }
        case .audio: placeholder("Áudio")
        case .video: placeholder("Vídeo")
        case .drawing: placeholder("Desenho PencilKit")
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
#endif
