#if canImport(UIKit)
import SwiftUI
import UIKit
import PencilKit

public enum CanvasTool: String, CaseIterable, Identifiable {
    case select, pen, monoline, fountainPen, marker, pencil, eraser
    public var id: Self { self }
    public var isDrawing: Bool { self != .select }
    public var title: String {
        switch self {
        case .select: "Selecionar"
        case .pen: "Caneta"
        case .monoline: "Monoline"
        case .fountainPen: "Tinteiro"
        case .marker: "Marcador"
        case .pencil: "Lápis"
        case .eraser: "Borracha"
        }
    }
    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .monoline: "pencil.line"
        case .fountainPen: "pencil.tip.crop.circle"
        case .marker: "highlighter"
        case .pencil: "pencil"
        case .eraser: "eraser"
        }
    }
    func nativeTool(color: UIColor, width: CGFloat, vectorEraser: Bool) -> any PKTool {
        if self == .eraser { return PKEraserTool(vectorEraser ? .vector : .bitmap) }
        let kind: PKInkingTool.InkType
        switch self {
        case .monoline: kind = .monoline
        case .fountainPen: kind = .fountainPen
        case .marker: kind = .marker
        case .pencil: kind = .pencil
        default: kind = .pen
        }
        let range = kind.validWidthRange
        return PKInkingTool(kind, color: color, width: min(range.upperBound, max(range.lowerBound, width)))
    }
}

public enum TextEditingAction {
    case bold, italic, underline, strike, font(String), fontSize(CGFloat)
    case alignment(NSTextAlignment), highlight(UIColor?), foreground(UIColor)
    case bulletList, numberedList, removeList, indent(CGFloat), lineSpacing(CGFloat), link, find
    case insertText, fitPage, zoom(CGFloat), finish
}

/// Keeps the selected UITextView and its text range alive while native toolbar buttons act on it.
@Observable @MainActor
public final class EditorSession {
    public var hasTextSelection = false
    @ObservationIgnored var handler: ((TextEditingAction) -> Void)?
    public init() {}
    public func perform(_ action: TextEditingAction) { handler?(action) }
}

@MainActor
final class PageRuler: UIView {
    var zoom: CGFloat = 1
    var offset: CGFloat = 0
    var pointsPerUnit: CGFloat = 72 / 2.54
    var unitName = "cm"
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .secondarySystemBackground; isAccessibilityElement = true; accessibilityLabel = "Régua da página" }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), zoom > 0 else { return }
        let unitPixels = pointsPerUnit * zoom
        let majorStep = max(1, ceil(36 / unitPixels))
        let step = unitPixels * majorStep / 5
        guard step.isFinite, step > 0 else { return }
        let first = max(0, Int(floor(offset / step)))
        let last = max(first, Int(ceil((offset + bounds.width) / step)))
        context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
        for index in first...last {
            let x = CGFloat(index) * step - offset
            let major = index % 5 == 0
            context.move(to: CGPoint(x: x, y: bounds.height))
            context.addLine(to: CGPoint(x: x, y: bounds.height - (major ? 9 : 4)))
            if major {
                let value = CGFloat(index) * majorStep / 5
                (String(format: "%.0f", value) as NSString).draw(at: CGPoint(x: x + 3, y: 1), withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: UIColor.secondaryLabel])
            }
        }
        context.strokePath()
        accessibilityValue = unitName
    }
}
#endif
