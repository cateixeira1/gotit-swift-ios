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
    case insertText, insertTable, fitPage, zoom(CGFloat), finish
}

/// A key typed while the caret was moving to another page, replayed once it arrives.
enum QueuedKey: Equatable { case insert(String), deleteBackward }

/// A selection in a story that runs over several pages, in characters of the whole story.
public struct StorySelection: Equatable {
    public var story: UUID
    public var range: NSRange
    public init(story: UUID, range: NSRange) { self.story = story; self.range = range }
}

/// Keeps the selected UITextView and its text range alive while native toolbar buttons act on it.
/// Shared by every page of a note, so it also carries what crosses page boundaries: the caret
/// moving to another page's text box, and whether an Apple Pencil is in use.
@Observable @MainActor
public final class EditorSession {
    public var hasTextSelection = false
    /// The caret belongs in another text box (usually on the next page) that may not exist yet.
    @ObservationIgnored public var pendingFocus: TextFlowFocus? {
        didSet { pendingFocusSince = Date(); if pendingFocus == nil { queuedInput.removeAll() } }
    }
    @ObservationIgnored var pendingFocusSince = Date.distantPast
    /// Keys typed while `pendingFocus` waits; they belong after the caret's new position.
    @ObservationIgnored var queuedInput: [QueuedKey] = []
    /// Moves the caret to a text box on any page right away; false if that box is not on screen yet.
    @ObservationIgnored var focusRouter: ((TextFlowFocus) -> Bool)?
    /// Keeps the caret visible above the keyboard after typing or moving it.
    @ObservationIgnored var revealCaret: (() -> Void)?
    /// Called when drawing input or ink interaction changes, so scrolling can adapt.
    @ObservationIgnored var interactionChanged: (() -> Void)?
    /// An Apple Pencil draws and fingers navigate, tap and select (set on the first Pencil touch,
    /// or by the system setting "Only Draw with Apple Pencil").
    @ObservationIgnored public private(set) var prefersPencil = false
    @ObservationIgnored var handler: ((TextEditingAction) -> Void)?
    /// Text selected across pages (shown with its own highlight and handles); nil otherwise.
    @ObservationIgnored public var storySelection: StorySelection? {
        didSet { if oldValue != storySelection { storySelectionChanged?() } }
    }
    @ObservationIgnored var storySelectionChanged: (() -> Void)?
    /// Where each story fragment sits in its whole story (set by the paged editor).
    @ObservationIgnored var fragmentRanges: [UUID: (story: UUID, range: NSRange)] = [:]
    /// Applies an edit to the story selection (typing over it, deleting, formatting).
    @ObservationIgnored var storyEdit: ((StorySelection, StoryEdit) -> Void)?
    /// Copy, cut, paste and select all from a text box, for a selection across pages.
    @ObservationIgnored var storyCommand: ((Selector, UUID) -> Bool)?
    /// The edit menu for a selection across pages.
    @ObservationIgnored var storyMenu: (() -> UIMenu)?
    /// An object drag started on a page (that page is brought above its neighbours).
    @ObservationIgnored var objectDragBegan: ((CanvasViewController) -> Void)?
    /// For an object dropped at `frame` (in that page's view): the other page under it and the
    /// object's origin there, or nil to keep it on its own page.
    @ObservationIgnored var pageForDrop: ((CanvasViewController, CGRect) -> (page: UUID, origin: CGPoint)?)?
    /// Stories with more than one box: only those use the selection across pages.
    func spansPages(_ story: UUID) -> Bool { fragmentRanges.values.filter { $0.story == story }.count > 1 }
    public init() {
        #if !targetEnvironment(macCatalyst)
        prefersPencil = UIPencilInteraction.prefersPencilOnlyDrawing
        #endif
    }
    public func perform(_ action: TextEditingAction) { handler?(action) }
    func pencilDetected() {
        guard !prefersPencil else { return }
        prefersPencil = true
        interactionChanged?()
    }
    /// A pending caret move that never completed must not swallow typing forever.
    var waitingForFocus: Bool { pendingFocus != nil && Date().timeIntervalSince(pendingFocusSince) < 1 }
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
