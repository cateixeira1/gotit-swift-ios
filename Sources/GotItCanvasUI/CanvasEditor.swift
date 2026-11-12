#if canImport(UIKit)
import SwiftUI
import UIKit
import PencilKit
import AVFoundation
import GotItDomain
import GotItCanvas


public struct NoteCardPresentation {
    public var title: String
    public var createdAt: Date
    public var preview: UIImage?
    public init(title: String, createdAt: Date, preview: UIImage? = nil) {
        self.title = title; self.createdAt = createdAt; self.preview = preview
    }
}

/// Native iOS adapter. The host owns persistence, asset decoding and note navigation.
public struct CanvasEditor: UIViewControllerRepresentable {
    public var document: CanvasDocument
    public var tool: CanvasTool
    public var session: EditorSession?
    public var inkColor: UIColor
    public var inkWidth: CGFloat
    public var vectorEraser: Bool
    public var drawingData: (String) -> Data?
    public var onDrawing: (DrawingSave, [DocumentCommand]) -> Void
    public var image: (String) -> UIImage?
    public var note: (UUID) -> NoteCardPresentation?
    public var onTextCommands: ((CanvasBlock, String?, NSRange) -> TextFlowFocus?)?
    /// Backspace at the start of a continuation box: joins it to the previous page's text. The page
    /// projection does not hold other pages' boxes, so the host resolves it on the whole note.
    public var onBackspaceAtStart: ((UUID, String?) -> TextFlowFocus?)?
    public var onCommands: ([DocumentCommand]) -> Void
    public var onOpenPDF: (UUID) -> Void
    public var onOpenNote: (UUID) -> Void
    public var onError: (Error) -> Void
    /// 1-based page number, used for per-page accessibility identifiers in stacked layouts.
    public var pageNumber: Int?
    /// Pages in the note, for "Página 1 de N".
    public var pageCount: Int?
    /// A picture's background was removed: the host stores the new PNG and points the block at it.
    public var onReplaceImage: ((UUID, Data) -> Void)?
    /// "Transcrever" on an audio block: the host writes its text below it.
    public var onTranscribe: ((UUID) -> Void)?
    /// A tap on a video block: the host plays it full screen.
    public var onPlayVideo: ((UUID) -> Void)?

    @MainActor public init(document: CanvasDocument, tool: CanvasTool = .select, session: EditorSession? = nil,
                inkColor: UIColor = .black, inkWidth: CGFloat = 3, vectorEraser: Bool = false,
                drawingData: @escaping (String) -> Data? = { _ in nil },
                onDrawing: @escaping (DrawingSave, [DocumentCommand]) -> Void = { _, _ in },
                image: @escaping (String) -> UIImage? = { _ in nil },
                note: @escaping (UUID) -> NoteCardPresentation? = { _ in nil },
                onTextCommands: ((CanvasBlock, String?, NSRange) -> TextFlowFocus?)? = nil,
                onBackspaceAtStart: ((UUID, String?) -> TextFlowFocus?)? = nil,
                onCommands: @escaping ([DocumentCommand]) -> Void,
                onOpenPDF: @escaping (UUID) -> Void = { _ in },
                onOpenNote: @escaping (UUID) -> Void = { _ in }, onError: @escaping (Error) -> Void = { _ in },
                pageNumber: Int? = nil, onTranscribe: ((UUID) -> Void)? = nil, onPlayVideo: ((UUID) -> Void)? = nil,
                onReplaceImage: ((UUID, Data) -> Void)? = nil) {
        self.pageNumber = pageNumber; self.onReplaceImage = onReplaceImage; self.onTranscribe = onTranscribe; self.onPlayVideo = onPlayVideo
        self.session = session; self.inkColor = inkColor; self.inkWidth = inkWidth; self.vectorEraser = vectorEraser
        self.drawingData = drawingData; self.onDrawing = onDrawing
        self.onOpenPDF = onOpenPDF
        self.onTextCommands = onTextCommands; self.onBackspaceAtStart = onBackspaceAtStart
        self.document = document; self.tool = tool; self.image = image; self.note = note
        self.onCommands = onCommands; self.onOpenNote = onOpenNote; self.onError = onError
    }
    public func makeUIViewController(context: Context) -> CanvasViewController { CanvasViewController(configuration: self) }
    public func updateUIViewController(_ controller: CanvasViewController, context: Context) { controller.configure(self) }
}

/// Backspace at offset 0 of a continuation fragment never reaches `shouldChangeTextIn`
/// (there is nothing to delete inside this view), so the story handles it here. This also
/// covers hardware keyboards. Marked text (IME composition) is never intercepted.
final class FlowTextView: UITextView {
    var backspaceAtStart: (() -> Bool)?
    /// Story boxes grow with their text (pagination sizes them), so they never scroll their own
    /// content. Scrolling here hid the first lines whenever a line arrived before the box grew.
    /// Other text (inside a shape, say) keeps a fixed box and may scroll.
    var pinsContent = false
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = pinsContent ? .zero : newValue }
    }
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(pinsContent ? .zero : contentOffset, animated: pinsContent ? false : animated)
    }
    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0, markedTextRange == nil,
           backspaceAtStart?() == true { return }
        super.deleteBackward()
    }
    /// Ending a composition (choosing a kana candidate, the accent of a dead key on a hardware
    /// keyboard, leaving the box) changes no characters, so UIKit may not report a change; the
    /// editor ignores changes while text is marked, and would keep the composed text unsaved until
    /// the next key. Report it here (duplicates are dropped by the editor).
    /// Copy, cut, paste and select all go to the selection across pages when there is one.
    var storyCommand: ((Selector) -> Bool)?
    override func copy(_ sender: Any?) { if storyCommand?(#selector(copy(_:))) != true { super.copy(sender) } }
    override func cut(_ sender: Any?) { if storyCommand?(#selector(cut(_:))) != true { super.cut(sender) } }
    override func paste(_ sender: Any?) { if storyCommand?(#selector(paste(_:))) != true { super.paste(sender) } }
    override func selectAll(_ sender: Any?) { if storyCommand?(#selector(selectAll(_:))) != true { super.selectAll(sender) } }
    override func unmarkText() {
        let wasMarked = markedTextRange != nil
        super.unmarkText()
        if wasMarked { delegate?.textViewDidChange?(self) }
    }
}

@MainActor
public final class CanvasViewController: UIViewController, UIScrollViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, PKCanvasViewDelegate, UIPopoverPresentationControllerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private var configuration: CanvasEditor
    private let scroll = UIScrollView()
    private let surface = UIView()
    private let ink = PKCanvasView()
    /// Header, footer and page number, behind the page's objects.
    let bands = PageBandsView()
    /// Dashed edge of a header or footer an object is being moved into.
    let bandGuides = BandGuidesView()
    /// Black lines where a dragged object's middle lines up with another's (Canva-like).
    let alignmentLines = CAShapeLayer()
    private var alignmentSnap = AlignmentGuides.Snap.none
    private let alignmentFeedback = UISelectionFeedbackGenerator()
    private let ruler = PageRuler()
    private weak var activeText: UITextView?
    private var applyingDrawing = false
    private var usingTool = false
    /// What the saved drawing holds, stroke by stroke (see `DrawingStorage.fingerprint`), and how
    /// many parts it has: a save that only adds strokes writes just those.
    private var savedStrokes: [String] = []
    private var savedParts = 0
    private var strokesAtStart = 0
    /// Finger tap over the ink layer while an Apple Pencil draws: same meaning as in cursor mode.
    private var inkTap: UITapGestureRecognizer?
    /// Never recognizes anything; it only notices the first Apple Pencil touch.
    private let pencilWatcher = UITapGestureRecognizer()
    /// Blocks seen in the previous render, to select a freshly inserted image or table.
    private var knownBlockIDs: Set<UUID>?
    private var lastTool: CanvasTool?
    /// Strokes whose meaning was already decided (keyed by creation time); loaded strokes count.
    private var classifiedStrokes: Set<Double> = []
    private var toolEndedAt = Date.distantPast
    /// Recent finished strokes: the context that tells writing from figures and dots from taps.
    private var recentInk: [Double: InkSample] = [:]
    /// Strokes waiting for a pause to decide whether they form a figure.
    private var awaitingShape: [Double] = []
    private var shapeCheckGeneration = 0
    /// The last figure made without an explicit gesture; undone if writing continues beside it.
    private var lastConversion: Conversion?
    private typealias Conversion = (shapeID: UUID, strokes: [PKStroke], bounds: LogicalRect, at: Double)
    /// Strokes drawn right beside the last figure. At the next pause they decide: another figure
    /// keeps it (boxes side by side), writing turns it back into ink (the "o" of a word).
    private var suspect: (conversion: Conversion, keys: Set<Double>)?
    /// Document revision when each text view last sent its content. A configuration that is not
    /// newer than that is stale (SwiftUI can re-render before the host's update arrives) and must
    /// not overwrite what the user is typing, or the caret jumps behind the last letters.
    private var sentRevision: [UUID: Int64] = [:]
    /// What each text view last sent, so a repeated report of the same change is not a new edit.
    private var sentText: [UUID: RichText] = [:]
    private var sentSelection: [UUID: NSRange] = [:]
    private var loadedDrawingHash: String?
    private var fitted = false
    private var inkToolSignature = ""
    private var pendingFocusID: UUID?
    private var rendering = false
    private var textPool: [UITextView] = []
    private var objectPool: [CanvasObjectView] = []
    private var selectedObjectID: UUID?
    /// Image being cropped with handles; cleared when the selection moves elsewhere.
    private var croppingID: UUID?
    /// Inline editor for one table cell; lives on the surface, above the table.
    private var cellEditor: UITextView?
    private var editingCell: (block: UUID, row: Int, column: Int)?
    private var selectionOverlay: SelectionHandles?
    /// Row/column picked by tapping its first cell; shows its tint and resize handle.
    private(set) var tableFocus: TableFocus?
    private var tableChrome: TableChrome?
    /// Previous tap on a first cell, to recognise a double tap without delaying single taps.
    private var lastFirstCellTap: (block: UUID, row: Int, column: Int, time: CFTimeInterval)?
    /// Duplicate/delete menu shown after a double tap on a first cell.
    private(set) var lineMenu: UIMenu?
    private lazy var lineMenuInteraction: UIEditMenuInteraction = {
        let interaction = UIEditMenuInteraction(delegate: self); surface.addInteraction(interaction); return interaction
    }()
    public var realizedBlockViewCount: Int { blockViews.count }
    public var recycledBlockViewCount: Int { textPool.count + objectPool.count }
    private var blockViews: [UUID: UIView] = [:]
    private var textIDs: [ObjectIdentifier: UUID] = [:]
    private var connectionViews: [UIView] = []
    private var frames: [UUID: LogicalRect] = [:]
    private var connectingFrom: UUID?
    private var movingID: UUID?
    private var moveOrigin = CGPoint.zero
    private var typingGroup: String?
    private var typingBlock: UUID?
    private var typingCaret: Int?
    private var typingTime = Date.distantPast
    private var typingStarted = Date.distantPast
    private var pendingTyping = false

    /// Embedded pages live inside PagedCanvasViewController, which owns scrolling, zoom,
    /// the ruler and toolbar routing. The page itself is laid out at its logical size.
    let embedded: Bool
    init(configuration: CanvasEditor, embedded: Bool = false) {
        self.configuration = configuration; self.embedded = embedded; super.init(nibName: nil, bundle: nil)
    }
    var hasActiveText: Bool { activeText != nil || cellEditor != nil }
    func performAction(_ action: TextEditingAction) { perform(action) }
    required init?(coder: NSCoder) { fatalError("Use CanvasEditor") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        scroll.delegate = self
        scroll.minimumZoomScale = 0.15; scroll.maximumZoomScale = 6
        scroll.backgroundColor = .systemGray5
        view.addSubview(scroll)
        surface.backgroundColor = .white
        surface.overrideUserInterfaceStyle = .light
        surface.layer.shadowOpacity = 0.15; surface.layer.shadowRadius = 8
        scroll.addSubview(surface)
        surface.addInteraction(UIContextMenuInteraction(delegate: self))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapCanvas(_:)))
        tap.delegate = self; tap.cancelsTouchesInView = false
        surface.addGestureRecognizer(tap)
        view.addSubview(ruler)
        ink.delegate = self; ink.backgroundColor = .clear; ink.isOpaque = false
        ink.isScrollEnabled = false; ink.drawingPolicy = .anyInput
        ink.isAccessibilityElement = true
        ink.accessibilityValue = "0 traços"
        ink.accessibilityIdentifier = "drawingCanvas"
        ink.accessibilityLabel = "Desenho da página"
        let inkTap = UITapGestureRecognizer(target: self, action: #selector(tapInk(_:)))
        inkTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]   // finger only; Pencil taps stay dots
        inkTap.cancelsTouchesInView = false; inkTap.delegate = self
        ink.addGestureRecognizer(inkTap); self.inkTap = inkTap
        pencilWatcher.delegate = self; pencilWatcher.cancelsTouchesInView = false
        ink.addGestureRecognizer(pencilWatcher)
        bindSession()
        surface.addSubview(bands)
        surface.addSubview(ink)
        surface.addSubview(bandGuides)
        if embedded {
            scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 1
            scroll.isScrollEnabled = false; scroll.delaysContentTouches = false
            scroll.backgroundColor = .clear; view.backgroundColor = .clear
            // An object dragged toward another page stays visible past this page's edge.
            scroll.clipsToBounds = false
            ruler.isHidden = true
        }
        render()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if embedded {
            // The first render happens before the page has its real size (in viewDidLoad), so it
            // only realized the objects near the top-left corner; a Teia reopened on its way back
            // from a note showed only its first card. Render again once the size is known.
            let resized = scroll.frame.size != view.bounds.size
            scroll.frame = view.bounds
            if resized { render() }
            return
        }
        ruler.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 28)
        scroll.frame = CGRect(x: 0, y: 28, width: view.bounds.width, height: max(0, view.bounds.height - 28))
        if !fitted, scroll.bounds.width > 0 { fitted = true; fitPage() }
        updateRuler()
    }
    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
    public func scrollViewDidZoom(_ scrollView: UIScrollView) { updateVisibility(); updateRuler() }
    public func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisibility(); updateRuler() }

    func configure(_ value: CanvasEditor) {
        configuration = value
        bindSession()
        if isViewLoaded { render() }
    }

    private func render() {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        do { frames = try CanvasLayoutEngine.frames(in: configuration.document) }
        catch { configuration.onError(error); return }
        let page = configuration.document.canvas.size
        let size = CGSize(width: page.width, height: page.height)
        surface.bounds = CGRect(origin: .zero, size: size)
        // Bounds changes preserve UIView.center; a zero-size view otherwise starts at
        // (-width/2, -height/2). Keep the zoomed page anchored at the content origin.
        let scaledSize = CGSize(width: size.width * scroll.zoomScale, height: size.height * scroll.zoomScale)
        surface.center = CGPoint(x: scaledSize.width / 2, y: scaledSize.height / 2)
        scroll.contentSize = scaledSize
        if let known = knownBlockIDs {
            let added = configuration.document.blocks.filter { $0.parentID == nil && !known.contains($0.id) }
            if added.count == 1, let block = added.first {
                switch block.content {
                case .image, .sticker, .pdf, .table: selectedObjectID = block.id; croppingID = nil
                case .shape(let shape) where shape.kind == .stickyNote || shape.kind == .calendar: selectedObjectID = block.id; croppingID = nil
                default: break
                }
            }
        }
        knownBlockIDs = Set(configuration.document.blocks.map(\.id))
        // An embedded page is already realized only when it is near the screen (PagedCanvasViewController),
        // so everything on it is shown, also objects moved past its edge (a Teia card dragged aside).
        let visible = embedded ? CGRect.infinite : scroll.convert(scroll.bounds, to: surface).insetBy(dx: -80, dy: -80)
        // The text of a folded transcription card is not shown.
        let folded = Stickers.foldedContent(in: configuration.document)
        let ids = Set(configuration.document.blocks.compactMap { block -> UUID? in
            guard !folded.contains(block.id), let frame = frames[block.id] else { return nil }
            let bounds = CanvasLayoutEngine.rotatedBounds(frame, radians: block.effectivePresentation.rotationRadians)
            let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
            return rect.intersects(visible) || blockViews[block.id]?.isFirstResponder == true || movingID == block.id || selectedObjectID == block.id || configuration.session?.pendingFocus?.blockID == block.id ? block.id : nil
        })
        for id in Array(blockViews.keys) where !ids.contains(id) {
            recycle(id)
        }
        // Back to front: stacking index, then insertion order (old notes have every index at 0).
        for block in configuration.document.paintOrder() {
            if case .drawing = block.content { continue }
            guard ids.contains(block.id), let logical = frames[block.id] else { continue }
            let blockView: UIView
            var keepFrame = false
            if case .text(let richText) = block.content {
                let isNew = blockViews[block.id] == nil
                let textView = (blockViews[block.id] as? UITextView) ?? makeTextView(id: block.id)
                if let flow = textView as? FlowTextView {
                    flow.pinsContent = block.textFlowID != nil && block.parentID == nil
                    if flow.pinsContent, flow.contentOffset != .zero { flow.contentOffset = .zero }
                }
                // On notebook paper the first line starts on the band below the box's top edge.
                let ruling = configuration.document.followsRuledLines(block.id) ? configuration.document.canvas.ruledLines : nil
                let insetTop = 4 + CGFloat(ruling?.offset(below: logical.y + 4) ?? 0)
                if textView.textContainerInset.top != insetTop { textView.textContainerInset.top = insetTop }
                if richText.plainText.isEmpty, !textView.isFirstResponder {
                    let style = (try? configuration.document.resolvedStyle(for: block.id)) ?? .init()
                    let size = style.fontSize ?? 18
                    let font = TextBridge.font(named: style.fontName, size: size)
                    let typing: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(hex: style.foreground ?? "#111827")]
                    textView.typingAttributes = ruling.map { TextBridge.ruledTyping(typing, lines: $0) } ?? typing
                } else if let ruling, textView.isFirstResponder {
                    let typing = TextBridge.ruledTyping(textView.typingAttributes, lines: ruling)
                    if (typing[.paragraphStyle] as? NSParagraphStyle) != (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle) { textView.typingAttributes = typing }
                }
                let rendered = TextBridge.shown(richText, block: block.id, in: configuration.document)
                let stale = textView.isFirstResponder && (sentRevision[block.id].map { configuration.document.revision <= $0 } ?? false)
                // The box being typed in was already resized locally; an older layout must not shrink it.
                keepFrame = stale && blockViews[block.id] === textView
                if !stale, textView.markedTextRange == nil, !rendered.isEqual(to: textView.attributedText ?? NSAttributedString(string: "")) {
                    let selection = textView.selectedRange
                    textView.attributedText = rendered
                    sentText[block.id] = nil              // the view now shows the document (undo, another page)
                    let location = min(selection.location, rendered.length)
                    textView.selectedRange = NSRange(location: location, length: min(selection.length, rendered.length - location))
                }
                textView.textContainer.exclusionPaths = ((try? TextFlowEngine.exclusions(for: block.id, in: configuration.document)) ?? []).map {
                    let path = UIBezierPath()
                    for (index, point) in $0.polygon.enumerated() {
                        let cg = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
                        if index == 0 { path.move(to: cg) } else { path.addLine(to: cg) }
                    }
                    path.close(); return path
                }
                blockView = textView
                if isNew, richText.plainText.isEmpty, pendingFocusID == block.id {
                    pendingFocusID = nil
                    Task { @MainActor [weak textView] in textView?.becomeFirstResponder() }
                }
            } else {
                let object = (blockViews[block.id] as? CanvasObjectView) ?? makeObjectView(id: block.id)
                object.block = block
                if case .audio(let reference) = block.content {
                    object.asset = nil
                    object.audioDuration = audioDuration(reference.hash)
                    object.accessibilityValue = object.audioDuration.map { AudioArt.time($0) }
                    object.audioPlaying = playingAudio == block.id && audioPlayer?.isPlaying == true
                    if playingAudio != block.id { object.audioProgress = 0 }
                } else {
                    object.asset = block.content.assetHash.flatMap(configuration.image)
                }
                if case .noteReference(let ref) = block.content { object.note = configuration.note(ref.documentID) }
                object.layer.shadowPath = nil
                switch block.content {
                case .sticker:
                    object.layer.shadowColor = UIColor.black.cgColor; object.layer.shadowOpacity = 0.38
                    object.layer.shadowOffset = CGSize(width: 0, height: 6); object.layer.shadowRadius = 8
                case .shape(let shape) where shape.kind == .stickyNote:
                    // Glued at the top: the shadow is under the loose bottom edge and the lifted corner.
                    object.layer.shadowColor = UIColor.black.cgColor; object.layer.shadowOpacity = 0.3
                    object.layer.shadowOffset = CGSize(width: 0, height: 4); object.layer.shadowRadius = 5
                    object.layer.shadowPath = StickerArt.stickyNoteShadow(for: CGRect(x: 0, y: 0, width: logical.width, height: logical.height)).cgPath
                case .shape(let shape) where shape.kind == .calendar:
                    object.layer.shadowColor = UIColor.black.cgColor; object.layer.shadowOpacity = 0.28
                    object.layer.shadowOffset = CGSize(width: 0, height: 4); object.layer.shadowRadius = 6
                default: object.layer.shadowOpacity = 0
                }
                object.setNeedsDisplay()
                blockView = object
            }
            if let previous = blockViews[block.id], previous !== blockView { previous.removeFromSuperview() }
            blockViews[block.id] = blockView
            if !keepFrame {
                blockView.transform = .identity
                blockView.frame = CGRect(x: logical.x, y: logical.y, width: logical.width, height: logical.height)
                blockView.transform = CGAffineTransform(rotationAngle: block.effectivePresentation.rotationRadians)
            }
            if blockView.superview == nil { surface.addSubview(blockView) }
            surface.bringSubviewToFront(blockView)
        }
        // Children (a post-it's text, a shape's label) sit right above their parent, not above
        // everything: an object put on top of a post-it covers its text too.
        for root in configuration.document.blocks where root.parentID == nil {
            if let view = blockViews[root.id] { _ = stackChildren(of: root.id, above: view) }
        }
        connectionViews.forEach { $0.removeFromSuperview() }; connectionViews = []
        if configuration.document.kind == .web {
            var metadata: [UUID: NoteCardMetadata] = [:]
            for block in configuration.document.blocks {
                if case .noteReference(let ref) = block.content, let note = configuration.note(ref.documentID) {
                    metadata[ref.documentID] = .init(id: ref.documentID, title: note.title, createdAt: note.createdAt)
                }
            }
            for link in TeiaEngine.chronology(in: configuration.document, metadata: metadata) {
                guard let source = frames[link.sourceCardID], let target = frames[link.targetCardID] else { continue }
                let view = ConnectionView(frame: surface.bounds)
                view.relation = .init(sourceID: link.sourceCardID, targetID: link.targetCardID, kind: .connector, style: .init(color: "#94A3B8", width: 1))
                view.points = ConnectorGeometry.path(from: source, to: target)
                view.isChronology = true; view.isUserInteractionEnabled = false
                surface.addSubview(view); connectionViews.append(view)
            }
        }
        for relation in configuration.document.relations where relation.kind == .connector {
            guard let source = frames[relation.sourceID], let target = frames[relation.targetID] else { continue }
            let connection = ConnectionView(frame: surface.bounds)
            connection.relation = relation
            connection.points = ConnectorGeometry.path(from: source, to: target, routing: relation.style?.routing ?? .straight)
            connection.onUpdate = { [weak self] relation in self?.configuration.onCommands([.setRelation(relation)]) }
            connection.onDelete = { [weak self] in self?.configuration.onCommands([.removeRelation(relation.id)]) }
            // A connector lies just above the higher of the two objects it joins, so an object
            // stacked above both also covers the arrow.
            let ends = [relation.sourceID, relation.targetID].compactMap { blockViews[$0] }.compactMap { surface.subviews.firstIndex(of: $0) }
            if let highest = ends.max() { surface.insertSubview(connection, aboveSubview: surface.subviews[highest]) }
            else { surface.addSubview(connection) }
            connectionViews.append(connection)
        }
        ink.frame = surface.bounds
        ink.contentSize = surface.bounds.size
        updateInkInteraction()
        let signature = "\(configuration.tool)-\(configuration.inkColor.hex)-\(configuration.inkWidth)-\(configuration.vectorEraser)"
        if signature != inkToolSignature {
            ink.tool = configuration.tool.nativeTool(color: configuration.inkColor, width: configuration.inkWidth, vectorEraser: configuration.vectorEraser)
            inkToolSignature = signature
        }
        applyInputMode()
        // Only switching to a pen ends typing; re-renders while typing in pen mode must not.
        if configuration.tool.isDrawing, let previous = lastTool, !previous.isDrawing { activeText?.resignFirstResponder() }
        lastTool = configuration.tool
        loadDrawing()
        ink.accessibilityValue = "\(ink.drawing.strokes.count) traços"
        ink.accessibilityIdentifier = configuration.pageNumber.map { "drawingCanvas-\($0)" } ?? "drawingCanvas"
        surface.bringSubviewToFront(ink)
        bands.frame = surface.bounds; bands.image = configuration.image
        bands.settings = configuration.document.canvas
        bands.fills = configuration.document.pages.first.map { configuration.document.paperFills(on: $0.id) } ?? []
        bands.background = configuration.document.pages.first?.background
        bands.pageIndex = max(0, (configuration.pageNumber ?? 1) - 1); bands.pageCount = max(1, configuration.pageCount ?? 1)
        surface.sendSubviewToBack(bands)
        bandGuides.frame = surface.bounds; surface.bringSubviewToFront(bandGuides)
        selectionOverlay?.removeFromSuperview(); selectionOverlay = nil
        if let id = selectedObjectID, let object = blockViews[id],
           let block = configuration.document.blocks.first(where: { $0.id == id }), !Stickers.isFolded(block) {
            let handles = SelectionHandles(frame: object.bounds)
            handles.center = object.center; handles.transform = object.transform
            if croppingID == id, let objectView = object as? CanvasObjectView {
                handles.cropping = true
                let originCenter = object.center
                handles.onResize = { [weak self, weak objectView] dx, dy, left, top, ended in
                    guard let self, let objectView else { return }
                    do {
                        let cropped = try CanvasTransforms.cropByDraggingCorner(block, left: left, top: top, dx: dx, dy: dy)
                        if ended {
                            if cropped != block { self.configuration.onCommands([.replaceBlock(cropped)]) } else { self.render() }
                            return
                        }
                        // Live preview in the object's own (possibly rotated) axes.
                        let old = block.layout.frame, new = cropped.layout.frame
                        let shift = CGPoint(x: new.x + new.width / 2 - (old.x + old.width / 2),
                                            y: new.y + new.height / 2 - (old.y + old.height / 2))
                            .applying(CGAffineTransform(rotationAngle: block.effectivePresentation.rotationRadians))
                        objectView.block = cropped
                        objectView.bounds.size = CGSize(width: new.width, height: new.height)
                        objectView.center = CGPoint(x: originCenter.x + shift.x, y: originCenter.y + shift.y)
                        objectView.setNeedsDisplay()
                        handles.bounds.size = objectView.bounds.size; handles.center = objectView.center; handles.setNeedsLayout()
                    } catch { self.configuration.onError(error) }
                }
                surface.addSubview(handles); selectionOverlay = handles
            } else {
            handles.onResize = { [weak self] dx, dy, left, top, ended in
                guard let self else { return }
                var rect = block.layout.frame
                var width = max(24, rect.width + (left ? -dx : dx))
                var height = max(24, rect.height + (top ? -dy : dy))
                if CanvasTransforms.keepsAspectRatio(block.content) {
                    // Photos, stickers and PDFs scale without distortion; cropping is "Recortar com alças".
                    let fitted = CanvasTransforms.proportionalSize(from: rect, proposedWidth: width, proposedHeight: height)
                    width = fitted.width; height = fitted.height
                }
                if left { rect.x += rect.width - width }; if top { rect.y += rect.height - height }
                rect.width = width; rect.height = height
                if ended {
                    do {
                        var commands = try CanvasTransforms.resize(id, width: width, height: height, in: self.configuration.document)
                        commands = commands.map { command in
                            if case .replaceBlock(var changed) = command, changed.id == id {
                                changed.layout.frame.x = rect.x; changed.layout.frame.y = rect.y; return .replaceBlock(changed)
                            }; return command
                        }
                        self.configuration.onCommands(commands)
                    } catch { self.configuration.onError(error) }
                } else {
                    object.bounds.size = CGSize(width: width, height: height)
                    handles.bounds.size = object.bounds.size; handles.setNeedsLayout()
                    self.showBandGuides(for: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
                }
                if ended { self.bandGuides.hide() }
            }
            surface.addSubview(handles); selectionOverlay = handles
            }
        }
        showTableChrome()
        // Block views are re-ordered by z-index above; the open cell editor must stay on top
        // or the table drawing hides what is being typed.
        if let cellEditor { surface.bringSubviewToFront(cellEditor) }
        updateRuler()
        claimPendingFocus()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        claimPendingFocus()
    }

    /// With an Apple Pencil, fingers never draw: they scroll with one finger and tap like the cursor.
    /// Without one (iPhone), the finger is the pen and taps are read from the stroke itself.
    func applyInputMode() {
        let pencil = configuration.session?.prefersPencil ?? false
        let policy: PKCanvasViewDrawingPolicy = pencil ? .pencilOnly : .anyInput
        if ink.drawingPolicy != policy { ink.drawingPolicy = policy }
        inkTap?.isEnabled = pencil
        scroll.panGestureRecognizer.minimumNumberOfTouches = configuration.tool.isDrawing && !pencil && ink.isUserInteractionEnabled ? 2 : 1
    }
    /// True while one-finger drags on this page draw ink (scrolling then needs two fingers).
    var fingerDraws: Bool { ink.isUserInteractionEnabled && ink.drawingPolicy == .anyInput }

    /// The caret moved to a box on this page (another page overflowed into it, or backspace joined
    /// it). Taking focus here, synchronously, keeps the next keystrokes in the right box.
    func claimPendingFocus() {
        guard let focus = configuration.session?.pendingFocus, blockViews[focus.blockID] != nil, view.window != nil else { return }
        _ = claimFocus(focus)
    }
    func claimFocus(_ focus: TextFlowFocus) -> Bool {
        guard let textView = blockViews[focus.blockID] as? UITextView, textView.window != nil else { return false }
        let rendered = TextBridge.shown(focus.text, block: focus.blockID, in: configuration.document)
        if !rendered.isEqual(to: textView.attributedText ?? NSAttributedString()) { textView.attributedText = rendered; sentText[focus.blockID] = nil }
        if let frame = focus.frame { resize(textView, to: frame) }
        // Read the keys typed meanwhile before clearing the pending move (clearing drops the queue).
        let queued = configuration.session?.queuedInput ?? []
        configuration.session?.queuedInput.removeAll()
        if configuration.session?.pendingFocus?.blockID == focus.blockID { configuration.session?.pendingFocus = nil }
        // Until the host's update for this move arrives, renders carry older text for this box.
        sentRevision[focus.blockID] = configuration.document.revision
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        let length = textView.attributedText.length
        let location = min(focus.range.location, length)
        textView.selectedRange = NSRange(location: location, length: min(focus.range.length, length - location))
        for key in queued {
            switch key {
            case .insert(let text): textView.insertText(text)
            case .deleteBackward: textView.deleteBackward()
            }
        }
        configuration.session?.revealCaret?()
        return true
    }
    /// Grows or shrinks a story box at once, before the host re-renders, so no line is clipped.
    private func resize(_ textView: UITextView, to frame: LogicalRect) {
        let rotation = textView.transform
        textView.transform = .identity
        textView.frame = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        textView.transform = rotation
    }

    /// Pens own the page unless the user is typing, editing a cell or has an object selected;
    /// then touches reach text views, handles and objects (move/resize) instead of drawing.
    private func updateInkInteraction() {
        let enabled = configuration.tool.isDrawing && activeText == nil && cellEditor == nil && selectedObjectID == nil
            && !configuration.document.canvas.isSimpleNote
        guard ink.isUserInteractionEnabled != enabled else { return }
        ink.isUserInteractionEnabled = enabled
        applyInputMode()
        configuration.session?.interactionChanged?()
    }

    private func bindSession() {
        // Stacked pages share one session; the container routes toolbar actions to the right page.
        guard !embedded else { return }
        configuration.session?.handler = { [weak self] action in self?.perform(action) }
        configuration.session?.focusRouter = { [weak self] focus in self?.claimFocus(focus) ?? false }
    }

    private func fitPage() {
        let width = configuration.document.canvas.size.width
        scroll.setZoomScale(min(1, max(scroll.minimumZoomScale, (scroll.bounds.width - 24) / max(1, width))), animated: false)
        scroll.contentOffset = .zero
    }

    private func updateRuler() {
        ruler.zoom = scroll.zoomScale; ruler.offset = scroll.contentOffset.x
        switch configuration.document.canvas.displayUnit {
        case .centimeters: ruler.pointsPerUnit = 72 / 2.54; ruler.unitName = "cm"
        case .inches: ruler.pointsPerUnit = 72; ruler.unitName = "in"
        case .pixels: ruler.pointsPerUnit = 72 / configuration.document.canvas.pixelsPerInch; ruler.unitName = "px"
        }
        ruler.setNeedsDisplay()
    }

    private func perform(_ action: TextEditingAction) {
        switch action {
        case .insertText: insertText(at: CGPoint(x: 24, y: max(24, scroll.contentOffset.y / scroll.zoomScale + 24))); return
        case .insertTable:
            let probe = CanvasTable(rows: 3, columns: 3, width: min(480, configuration.document.canvas.size.width - 48))
            let spot = Placement.firstFreeSpot(width: probe.width, height: probe.height, on: configuration.document)
            insertTable(at: CGPoint(x: spot.x, y: spot.y)); return
        case .fitPage: fitPage(); return
        case .zoom(let factor): scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * factor)), animated: true); return
        case .finish: activeText?.resignFirstResponder(); usingTool = false; saveDrawing(); return
        default: break
        }
        guard let text = activeText, text.superview != nil else { return }
        switch action {
        case .bold: text.toggleBoldface(nil); textViewDidChange(text)
        case .italic: text.toggleItalics(nil); textViewDidChange(text)
        case .underline: toggle(text, key: .underlineStyle)
        case .strike: toggle(text, key: .strikethroughStyle)
        case .font(let name):
            let size = (text.typingAttributes[.font] as? UIFont)?.pointSize ?? 18
            format(text, key: .font, value: name == "Sistema" ? UIFont.systemFont(ofSize: size) : (UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)))
        case .fontSize(let size):
            let font = (text.typingAttributes[.font] as? UIFont) ?? UIFont.systemFont(ofSize: size)
            format(text, key: .font, value: font.withSize(size))
        case .alignment(let value): paragraph(text) { $0.alignment = value }
        case .highlight(let value):
            if let value { format(text, key: .backgroundColor, value: value) }
            else { text.typingAttributes.removeValue(forKey: .backgroundColor); if text.selectedRange.length > 0 { text.textStorage.removeAttribute(.backgroundColor, range: text.selectedRange); textViewDidChange(text) } }
        case .foreground(let value): format(text, key: .foregroundColor, value: value)
        case .bulletList: paragraph(text) { $0.textLists = [NSTextList(markerFormat: .disc, options: 0)] }
        case .numberedList: paragraph(text) { $0.textLists = [NSTextList(markerFormat: .decimal, options: 0)] }
        case .removeList: paragraph(text) { $0.textLists = [] }
        case .indent(let delta): paragraph(text) { $0.headIndent = max(0, $0.headIndent + delta); $0.firstLineHeadIndent = max(0, $0.firstLineHeadIndent + delta) }
        case .lineSpacing(let value): paragraph(text) { $0.lineSpacing = value }
        case .link: insertLink(text)
        case .find: text.findInteraction?.presentFindNavigator(showingReplace: true)
        default: break
        }
    }

    private func toggle(_ text: UITextView, key: NSAttributedString.Key) {
        let current = text.selectedRange.length > 0 ? text.textStorage.attribute(key, at: text.selectedRange.location, effectiveRange: nil) : text.typingAttributes[key]
        format(text, key: key, value: (current as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0)
    }

    private func loadDrawing() {
        guard !usingTool else { return }
        let reference = configuration.document.blocks.compactMap { block -> AssetReference? in
            if case .drawing(let ref) = block.content { return ref }; return nil
        }.first
        let hash = reference.map { $0.allHashes.joined(separator: "+") }
        guard hash != loadedDrawingHash else { return }
        do {
            let drawing = try reference.map { try DrawingStorage.drawing($0, data: configuration.drawingData) } ?? PKDrawing()
            applyingDrawing = true; ink.drawing = drawing; applyingDrawing = false
            drawing.strokes.forEach { classifiedStrokes.insert(Self.key($0)) }
            loadedDrawingHash = hash
            savedStrokes = drawing.strokes.map(DrawingStorage.fingerprint); savedParts = reference?.parts?.count ?? 0
        } catch { configuration.onError(error) }
    }

    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        usingTool = true; strokesAtStart = canvasView.drawing.strokes.count
        handwritingTimer?.invalidate()       // still writing
        shapeCheckGeneration += 1          // writing continues: wait for the next pause
    }
    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        usingTool = false; toolEndedAt = Date()
        if readsWriting, configuration.tool != .eraser {
            handwritingTimer?.invalidate()
            handwritingTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.convertHandwriting() }
            }
        }
        // PencilKit can deliver the final drawing change after the tool-end callback.
        Task { @MainActor [weak self] in await Task.yield(); self?.processInk() }
    }
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // VoiceOver (and tests) read the strokes on the page as they are drawn, not only after saving.
        canvasView.accessibilityValue = "\(canvasView.drawing.strokes.count) traços"
        guard !applyingDrawing, !usingTool else { return }
        Task { @MainActor [weak self] in await Task.yield(); self?.processInk() }
    }

    private static func key(_ stroke: PKStroke) -> Double { stroke.path.creationDate.timeIntervalSinceReferenceDate }
    private func sample(_ stroke: PKStroke, releasedAt: Date? = nil) -> InkSample {
        let points = stroke.path.map { point -> CanvasPoint in
            let location = point.location.applying(stroke.transform)
            return .init(x: location.x, y: location.y)
        }
        let start = Self.key(stroke), times = stroke.path.map(\.timeOffset)
        let release = max(releasedAt?.timeIntervalSinceReferenceDate ?? 0, start + (times.last ?? 0))
        return InkSample(points: points, times: times, startedAt: start, releasedAt: release)
    }
    /// Screen points per logical point, including the container's zoom.
    private var screenScale: Double {
        let probe = ink.convert(CGRect(x: 0, y: 0, width: 100, height: 100), to: nil)
        return probe.width > 0 ? probe.width / 100 : 1
    }

    /// Decides what each finished stroke means. On iPhone the finger is the pen, so a tap is told
    /// apart from a stroke by its size and duration, and from the dot of an "i" by the writing just
    /// before it. A tap is never ink and never opens a text box while drawing; it selects what is
    /// under it. A stroke that rests at its end asks for a figure; other strokes become figures only
    /// after a pause, when they clearly are one and are not part of writing.
    private func processInk() {
        guard !usingTool, !applyingDrawing, isViewLoaded else { return }
        let strokes = ink.drawing.strokes
        let fresh = strokes.filter { !classifiedStrokes.contains(Self.key($0)) }
        fresh.forEach { classifiedStrokes.insert(Self.key($0)) }
        guard configuration.tool != .eraser, !fresh.isEmpty else { saveDrawing(); return }
        let fingerIsPen = !(configuration.session?.prefersPencil ?? false)
        let scale = screenScale
        var taps: [(key: Double, point: CGPoint)] = []
        var held: [Double] = []
        for stroke in fresh {
            let drawn = sample(stroke, releasedAt: toolEndedAt)
            let key = Self.key(stroke)
            if fingerIsPen, InkIntent.isTap(drawn, screenScale: scale), !InkIntent.tapBelongsToWriting(drawn, recent: Array(recentInk.values)) {
                let box = drawn.bounds
                taps.append((key, CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2))); continue
            }
            if let conversion = lastConversion, InkIntent.continuesWriting(after: conversion.bounds, convertedAt: conversion.at, with: drawn) {
                let earlier = suspect?.conversion.shapeID == conversion.shapeID ? suspect?.keys ?? [] : []
                suspect = (conversion, earlier.union([key]))
            }
            recentInk[key] = drawn
            if readsWriting { handwritingKeys.insert(key) }
            if InkIntent.holdDuration(drawn, screenScale: scale) >= InkIntent.holdToSnap { held.append(key) }
            else { awaitingShape.append(key) }
        }
        let now = Date().timeIntervalSinceReferenceDate
        recentInk = recentInk.filter { now - $0.value.releasedAt < 20 }
        if !taps.isEmpty {
            let removed = Set(taps.map(\.key))
            applyingDrawing = true
            ink.drawing = PKDrawing(strokes: ink.drawing.strokes.filter { !removed.contains(Self.key($0)) })
            applyingDrawing = false
        }
        saveDrawing()                    // the ink itself is kept first: undo then restores it
        for key in held { snapFigure(endingWith: key) }
        if let tap = taps.last { handleFingerTap(at: tap.point) }
        scheduleShapeCheck()
    }

    /// "Draw and hold": the stroke, with strokes drawn just before and touching it, becomes a figure.
    private func snapFigure(endingWith key: Double) {
        guard configuration.document.canvas.recognizeDiagrams,
              let stroke = ink.drawing.strokes.first(where: { Self.key($0) == key }) else { return }
        let last = sample(stroke)
        let box = last.bounds
        let pad = max(12, 0.2 * max(box.width, box.height))
        let partners = recentInk.filter { $0.key != key && last.startedAt - $0.value.releasedAt < 4 && $0.value.releasedAt <= last.startedAt + 0.01 }
            .filter { InkIntent.groups([box, $0.value.bounds], padding: pad).count == 1 }
            .sorted { $0.value.startedAt > $1.value.startedAt }.prefix(3)
        let together = partners.map(\.value.points) + [last.points]
        if partners.count > 0, let figure = ShapeRecognizer.recognize(together, intent: .deliberate) {
            convert(figure, strokes: Set(partners.map(\.key) + [key]), automatic: false); return
        }
        if let figure = ShapeRecognizer.recognize([last.points], intent: .deliberate) {
            convert(figure, strokes: [key], automatic: false)
        }
    }

    private func scheduleShapeCheck() {
        guard !awaitingShape.isEmpty || suspect != nil else { return }
        guard configuration.document.canvas.recognizeDiagrams else { awaitingShape.removeAll(); suspect = nil; return }
        shapeCheckGeneration += 1
        let generation = shapeCheckGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.shapeCheckGeneration == generation, !self.usingTool else { return }
            self.checkAwaitingShapes()
        }
    }

    /// After a pause: strokes drawn together are one candidate. Many strokes, writing on the same
    /// line, small strokes, or strokes inside an object (a label in a box) stay ink. Strokes that run
    /// from one figure to another are connectors: the figures convert first, then those lines
    /// become straight connectors between them.
    private func checkAwaitingShapes() {
        let pending = awaitingShape.compactMap { key in recentInk[key].map { (key: key, ink: $0) } }
            .filter { item in ink.drawing.strokes.contains { Self.key($0) == item.key } }
        awaitingShape.removeAll()
        var converted = Set<Double>()
        defer { resolveSuspect(converted: converted) }
        guard !pending.isEmpty else { return }
        let scale = screenScale
        let minimum = max(36, 40 / max(scale, 0.01))      // at least 40 screen points (about 7 mm) at any zoom
        let padding = max(6, 10 / max(scale, 0.01))
        let tolerance = max(24, 22 / max(scale, 0.01))   // how far from a figure a connector may end
        var working = configuration.document
        let shapeFrames = configuration.document.blocks.filter { $0.content.allowsChildren }.compactMap { frames[$0.id] }
        let lineKeys = Set(InkIntent.connectorStrokes(pending.map(\.ink), figures: shapeFrames, padding: padding, tolerance: tolerance).map { pending[$0].key })
        let figureStrokes = pending.filter { !lineKeys.contains($0.key) }

        func neighbourGroups(excluding keys: Set<Double>) -> [[InkSample]] {
            let others = recentInk.filter { !keys.contains($0.key) && !lineKeys.contains($0.key) }.map(\.value)
            return InkIntent.groups(others.map(\.bounds), padding: padding).map { $0.map { others[$0] } }
        }
        func tryFigure(_ members: [(key: Double, ink: InkSample)]) -> Bool {
            guard !members.isEmpty, members.count <= 4 else { return false }
            let keys = Set(members.map(\.key))
            let bounds = InkIntent.union(members.map(\.ink.bounds))
            guard max(bounds.width, bounds.height) >= minimum, !liesInsideObject(bounds) else { return false }
            guard !InkIntent.isNextToWriting(bounds, neighbourGroups: neighbourGroups(excluding: keys)) else { return false }
            // Every stroke of a figure is a real part of its outline, not a dot or a tick.
            let total = members.reduce(0) { $0 + $1.ink.length }
            if members.count > 1, members.contains(where: { $0.ink.length < 0.15 * total }) { return false }
            guard let figure = ShapeRecognizer.recognize(members.map(\.ink.points), intent: .automatic),
                  let commands = convert(figure, strokes: keys, automatic: true, in: working, tolerance: tolerance) else { return false }
            if let updated = try? CommandEngine.applying(commands, to: working) { working = updated }
            converted.formUnion(keys)
            return true
        }
        for group in InkIntent.groups(figureStrokes.map(\.ink.bounds), padding: padding) {
            _ = tryFigure(group.map { figureStrokes[$0] })
        }
        // Lines between figures, including figures converted just now.
        for item in pending where !converted.contains(item.key) && (lineKeys.contains(item.key) || ShapeRecognizer.isConnectorStroke(item.ink.points)) {
            let box = item.ink.bounds
            let line = RecognizedShape(kind: .line, frame: box, originalPoints: item.ink.points)
            guard let commands = convert(line, strokes: [item.key], automatic: true, in: working, tolerance: tolerance) else { continue }
            if let updated = try? CommandEngine.applying(commands, to: working) { working = updated }
            converted.insert(item.key)
        }
    }

    /// Decides about strokes drawn beside the last figure: kept as a figure when they formed or
    /// started another figure (or were erased), turned back into ink when they were writing.
    private func resolveSuspect(converted: Set<Double>) {
        guard let pendingSuspect = suspect else { return }
        suspect = nil
        if !pendingSuspect.keys.isDisjoint(with: converted) { return }
        let alive = pendingSuspect.keys.filter { key in ink.drawing.strokes.contains { Self.key($0) == key } }
        let followers = alive.compactMap { recentInk[$0] }
        if followers.isEmpty || InkIntent.followerIsFigure(followers) { return }
        saveDrawing(revert(pendingSuspect.conversion))
    }

    private func liesInsideObject(_ rect: LogicalRect) -> Bool {
        configuration.document.blocks.contains { block in
            guard block.parentID == nil, let frame = frames[block.id] else { return false }
            switch block.content {
            case .shape, .image, .sticker, .pdf, .table, .container: break
            default: return false
            }
            return rect.x >= frame.x && rect.y >= frame.y && rect.x + rect.width <= frame.x + frame.width && rect.y + rect.height <= frame.y + frame.height
        }
    }

    /// Replaces strokes by a figure in one save, after the ink itself was saved: one undo brings the
    /// strokes back. Free lines become shapes only on a deliberate gesture; otherwise only lines
    /// joining two figures (connectors) convert.
    @discardableResult
    private func convert(_ figure: RecognizedShape, strokes keys: Set<Double>, automatic: Bool,
                         in document: CanvasDocument? = nil, tolerance: Double = 24) -> [DocumentCommand]? {
        do {
            guard let commands = try DiagramCommands.insert(figure, in: document ?? configuration.document, stroke: configuration.inkColor.hex,
                                                             lineWidth: configuration.inkWidth, allowFreeLines: !automatic,
                                                             connectionTolerance: tolerance) else { return nil }
            let removed = ink.drawing.strokes.filter { keys.contains(Self.key($0)) }
            applyingDrawing = true
            ink.drawing = PKDrawing(strokes: ink.drawing.strokes.filter { !keys.contains(Self.key($0)) })
            applyingDrawing = false
            keys.forEach { recentInk.removeValue(forKey: $0) }
            awaitingShape.removeAll { keys.contains($0) }
            lastConversion = nil
            if automatic, case .insertBlock(let block)? = commands.first, block.parentID == nil {
                let f = figure.frame
                lastConversion = (block.id, removed, f, Date().timeIntervalSinceReferenceDate)
            }
            if let current = suspect, !current.keys.isDisjoint(with: keys) { suspect = nil }   // the follower was a figure
            saveDrawing(commands)
            return commands
        } catch { configuration.onError(error); return nil }
    }

    /// Writing went on right beside a figure made a moment ago: it was a letter. Puts the strokes back.
    private func revert(_ conversion: Conversion) -> [DocumentCommand] {
        lastConversion = nil
        guard configuration.document.blocks.contains(where: { $0.id == conversion.shapeID }) else { return [] }
        applyingDrawing = true
        ink.drawing = PKDrawing(strokes: ink.drawing.strokes + conversion.strokes)
        applyingDrawing = false
        for stroke in conversion.strokes { recentInk[Self.key(stroke)] = sample(stroke) }
        return [.removeSubtree(conversion.shapeID)]
    }

    /// An isolated finger tap while the finger is the pen: selects the object under it or places the
    /// caret in a text under it. On empty paper it does nothing; text boxes start in cursor mode.
    private func handleFingerTap(at point: CGPoint) {
        for view in surface.subviews.reversed() {
            guard let object = view as? CanvasObjectView, object.id != nil, !object.isHidden else { continue }
            let local = object.convert(point, from: surface)
            if object.point(inside: local, with: nil) { handleObjectTap(object, at: local); return }
        }
        for view in surface.subviews.reversed() {
            guard let text = view as? UITextView, text !== cellEditor, textIDs[ObjectIdentifier(text)] != nil else { continue }
            let local = text.convert(point, from: surface)
            guard text.point(inside: local, with: nil) else { continue }
            text.becomeFirstResponder()
            if let position = text.closestPosition(to: local) { text.selectedTextRange = text.textRange(from: position, to: position) }
            return
        }
    }

    private func saveDrawing(_ commands: [DocumentCommand] = []) {
        guard !usingTool, !applyingDrawing else { return }
        let drawing = ink.drawing
        let current = drawing.strokes.map(DrawingStorage.fingerprint)
        guard current != savedStrokes || !commands.isEmpty else { return }
        ink.accessibilityValue = "\(drawing.strokes.count) traços"
        let save: DrawingSave
        if current == savedStrokes {
            save = .unchanged
        } else if !savedStrokes.isEmpty, current.count > savedStrokes.count, Array(current.prefix(savedStrokes.count)) == savedStrokes,
                  savedParts < DrawingParts.limit {
            // Only new strokes: write just those, as one more part.
            save = .appended(PKDrawing(strokes: Array(drawing.strokes.dropFirst(savedStrokes.count))).dataRepresentation())
            savedParts += 1
        } else {
            // Strokes erased, moved, turned into shapes, or too many parts: the whole drawing again.
            save = .full(drawing.dataRepresentation())
            savedParts = 0
        }
        savedStrokes = current
        configuration.onDrawing(save, commands)
    }

    /// Views outside the overscan are detached and reset. Focus/IME and active drags stay pinned.
    private func recycle(_ id: UUID) {
        guard let view = blockViews.removeValue(forKey: id) else { return }
        view.removeFromSuperview(); view.transform = .identity
        textIDs.removeValue(forKey: ObjectIdentifier(view))
        sentText[id] = nil; sentSelection[id] = nil
        if let text = view as? UITextView {
            text.attributedText = nil; text.textContainer.exclusionPaths = []; text.typingAttributes = [:]
            text.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            text.undoManager?.removeAllActions()
            if textPool.count < 12 { textPool.append(text) }
        } else if let object = view as? CanvasObjectView {
            object.id = nil; object.block = nil; object.asset = nil; object.note = nil; object.onMenu = nil
            object.layer.shadowOpacity = 0; object.accessibilityHint = nil
            if objectPool.count < 24 { objectPool.append(object) }
        }
    }

    private func updateVisibility() {
        guard isViewLoaded, scroll.zoomScale > 0, !rendering else { return }
        render()
    }

    private func makeTextView(id: UUID) -> UITextView {
        if let reused = textPool.popLast() { textIDs[ObjectIdentifier(reused)] = id; return reused }
        let text = FlowTextView(usingTextLayoutManager: true)
        text.backspaceAtStart = { [weak self, weak text] in self?.backspaceAcrossFragments(text) ?? false }
        text.storyCommand = { [weak self, weak text] selector in
            guard let self, let text, let id = self.textIDs[ObjectIdentifier(text)] else { return false }
            return self.configuration.session?.storyCommand?(selector, id) ?? false
        }
        text.delegate = self; text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        text.isScrollEnabled = true
        text.isFindInteractionEnabled = true
        text.adjustsFontForContentSizeCategory = true
        text.accessibilityLabel = "Bloco de texto"
        textIDs[ObjectIdentifier(text)] = id
        // A bar that scrolls sideways, with "Concluir" fixed on the right: a UIToolbar cannot
        // scroll, and on iOS 26 its glass capsules ran past the iPhone's width.
        let bar = KeyboardBar()
        bar.add("bold", "Negrito") { [weak self, weak text] in
            guard let self, let text, !self.storyFormat(.bold) else { return }
            text.toggleBoldface(nil); self.textViewDidChange(text)
        }
        bar.add("italic", "Itálico") { [weak self, weak text] in
            guard let self, let text, !self.storyFormat(.italic) else { return }
            text.toggleItalics(nil); self.textViewDidChange(text)
        }
        bar.add("underline", "Sublinhado") { [weak self, weak text] in
            guard let self, let text, !self.storyFormat(.underline) else { return }
            self.format(text, key: .underlineStyle, value: NSUnderlineStyle.single.rawValue)
        }
        bar.add("strikethrough", "Tachado") { [weak self, weak text] in
            if let text { self?.format(text, key: .strikethroughStyle, value: NSUnderlineStyle.single.rawValue) }
        }
        bar.add("textformat.size.larger", "Aumentar fonte") { [weak self, weak text] in if let text { self?.resizeFont(text, delta: 2) } }
        bar.add("textformat.size.smaller", "Diminuir fonte") { [weak self, weak text] in if let text { self?.resizeFont(text, delta: -2) } }
        bar.add("highlighter", "Marca-texto") { [weak self, weak text] in if let text { self?.format(text, key: .backgroundColor, value: UIColor.systemYellow) } }
        bar.add("list.bullet", "Lista com marcadores") { [weak self, weak text] in
            if let text { self?.paragraph(text) { $0.textLists = [NSTextList(markerFormat: .disc, options: 0)] } }
        }
        bar.add("list.number", "Lista numerada") { [weak self, weak text] in
            if let text { self?.paragraph(text) { $0.textLists = [NSTextList(markerFormat: .decimal, options: 0)] } }
        }
        bar.add(menu: textMenu(text), symbol: "ellipsis.circle", label: "Mais")
        bar.done = { [weak text] in text?.resignFirstResponder() }
        text.inputAccessoryView = bar
        return text
    }

    /// Joins a continuation fragment to the previous one: the character before the story break
    /// is deleted, the text reflows, and the caret lands where that character was.
    private func backspaceAcrossFragments(_ textView: UITextView?) -> Bool {
        guard let textView, let id = textIDs[ObjectIdentifier(textView)] else { return false }
        if configuration.session?.waitingForFocus == true { configuration.session?.queuedInput.append(.deleteBackward); return true }
        if let onBackspace = configuration.onBackspaceAtStart {
            typingGroup = UUID().uuidString; typingBlock = nil; typingCaret = nil; pendingTyping = false
            guard let focus = onBackspace(id, typingGroup) else { return false }
            handOff(focus); return true
        }
        guard let onTextCommands = configuration.onTextCommands,
              let merge = configuration.document.backspaceAcrossFragments(at: id) else { return false }
        typingGroup = UUID().uuidString; typingBlock = nil; typingCaret = nil; pendingTyping = false
        guard let focus = onTextCommands(merge.replacement, typingGroup, NSRange(location: merge.caret, length: 0)) else { return true }
        handOff(focus)
        return true
    }

    /// The caret now belongs in another box. If that box is on screen it takes focus at once; if it is
    /// being created (a new page), keys typed meanwhile are queued for it instead of landing here,
    /// where they would end up before the text that already moved on.
    private func handOff(_ focus: TextFlowFocus) {
        if configuration.session?.focusRouter?(focus) == true { return }
        configuration.session?.pendingFocus = focus
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        activeText = textView; configuration.session?.hasTextSelection = true
        updateInkInteraction()
        configuration.session?.revealCaret?()
    }
    var activeTextView: UITextView? { activeText ?? cellEditor }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if textView === cellEditor { return true }
        let now = Date(), id = textIDs[ObjectIdentifier(textView)]
        // Typing or deleting over a selection that runs across pages edits the whole story.
        if let session = configuration.session, let selection = session.storySelection, let storyEdit = session.storyEdit,
           let id, session.fragmentRanges[id]?.story == selection.story, textView.markedTextRange == nil {
            storyEdit(selection, text.isEmpty ? .delete : .replace(text))
            return false
        }
        if let session = configuration.session, session.waitingForFocus, session.pendingFocus?.blockID != id,
           textView.markedTextRange == nil {
            if range.length == 0, !text.isEmpty { session.queuedInput.append(.insert(text)); return false }
            if range.length == 1, text.isEmpty { session.queuedInput.append(.deleteBackward); return false }
        }
        if typingBlock != id || typingCaret != textView.selectedRange.location || textView.selectedRange.length > 0 ||
           now.timeIntervalSince(typingTime) > 1 || now.timeIntervalSince(typingStarted) > 5 || text.count > 1 {
            typingGroup = UUID().uuidString; typingStarted = now
        }
        typingBlock = id; typingTime = now
        typingCaret = range.location + (text as NSString).length
        pendingTyping = true
        return true
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        defer { updateInkInteraction() }
        if textView === cellEditor {
            if activeText === textView { activeText = nil; configuration.session?.hasTextSelection = false }
            commitCell(); return
        }
        if activeText === textView { activeText = nil; configuration.session?.hasTextSelection = false }
        typingGroup = nil; typingBlock = nil; typingCaret = nil; pendingTyping = false
        removeIfAbandoned(textView)
        // Leaving the text (a tap on the page, another tool) ends a selection across pages; moving
        // to another box of the story does not, so decide once focus has settled.
        if configuration.session?.storySelection != nil {
            Task { @MainActor [weak self] in
                guard let session = self?.configuration.session, !session.hasTextSelection else { return }
                session.storySelection = nil
            }
        }
    }

    /// A tap creates a text block; leaving it without typing must not leave an empty box behind.
    /// Only standalone blocks or a story's only fragment qualify; continuation pages are owned
    /// by pagination.
    private func removeIfAbandoned(_ textView: UITextView) {
        // The view is the truth: the configuration may not yet carry the last keystroke.
        guard textView.text.isEmpty, textView.markedTextRange == nil, let id = textIDs[ObjectIdentifier(textView)],
              let block = configuration.document.blocks.first(where: { $0.id == id }), block.parentID == nil,
              case .text(let rich) = block.content, rich.plainText.isEmpty else { return }
        let story = block.textFlowID ?? block.id
        guard story == block.id, !configuration.document.blocks.contains(where: { $0.id != id && $0.textFlowID == story }) else { return }
        configuration.onCommands([.removeSubtree(id)])
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard let id = textIDs[ObjectIdentifier(textView)], var block = configuration.document.blocks.first(where: { $0.id == id }) else { return }
        // A larger font or a new paragraph keeps to the paper's lines at once (not at the next render).
        if textView.markedTextRange == nil, configuration.document.followsRuledLines(id), let lines = configuration.document.canvas.ruledLines {
            let selection = textView.selectedRange
            if TextBridge.rule(textView.textStorage, lines: lines) { textView.selectedRange = selection }
            let typing = TextBridge.ruledTyping(textView.typingAttributes, lines: lines)
            if (typing[.paragraphStyle] as? NSParagraphStyle) != (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle) { textView.typingAttributes = typing }
        }
        let rich = TextBridge.richText(textView.attributedText)
        block.content = .text(rich)
        let group = pendingTyping ? typingGroup : nil
        pendingTyping = false
        guard textView.markedTextRange == nil else { return } // Do not split an IME composition.
        // The same text reported twice (end of a composition) is one edit.
        if let last = sentText[id], last == rich, textView.selectedRange == sentSelection[id] { return }
        sentText[id] = rich; sentSelection[id] = textView.selectedRange
        sentRevision[id] = configuration.document.revision
        if let onTextCommands = configuration.onTextCommands {
            if let focus = onTextCommands(block, group, textView.selectedRange) {
                if focus.blockID == id {
                    // Only rewrite the view when pagination moved text out of it; rewriting on every
                    // key resets the keyboard's autocorrection state.
                    let rendered = TextBridge.shown(focus.text, block: id, in: configuration.document)
                    if !rendered.isEqual(to: textView.attributedText ?? NSAttributedString()) { textView.attributedText = rendered }
                    if textView.selectedRange != focus.range { textView.selectedRange = focus.range }
                    sentText[id] = TextBridge.richText(textView.attributedText); sentSelection[id] = textView.selectedRange
                    if let frame = focus.frame { resize(textView, to: frame) }
                } else { handOff(focus) }
            }
        }
        else { configuration.onCommands([.replaceBlock(block)]) }
        configuration.session?.revealCaret?()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.isFirstResponder else { return }
        syncStorySelection(from: textView)
        configuration.session?.revealCaret?()
    }

    /// A selection made in a box of a story longer than a page becomes a story selection, which
    /// has its own handles that can be dragged onto other pages. A caret ends it.
    private func syncStorySelection(from textView: UITextView) {
        // Selections set by the editor itself (re-rendering after an edit) are not the user's.
        guard !rendering, let session = configuration.session, session.storyEdit != nil,
              let id = textIDs[ObjectIdentifier(textView)], let fragment = session.fragmentRanges[id] else { return }
        let native = textView.selectedRange
        guard native.length > 0, textView.markedTextRange == nil else {
            if session.storySelection != nil { session.storySelection = nil }
            return
        }
        guard session.spansPages(fragment.story) else { return }
        session.storySelection = StorySelection(story: fragment.story, range: NSRange(location: fragment.range.location + native.location, length: native.length))
    }

    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let session = configuration.session, let selection = session.storySelection, let id = textIDs[ObjectIdentifier(textView)],
              session.fragmentRanges[id]?.story == selection.story, let menu = session.storyMenu else { return nil }
        return menu()
    }

    // MARK: Selection across pages

    /// Formats the selection across pages, if there is one.
    private func storyFormat(_ action: TextEditingAction) -> Bool {
        guard let session = configuration.session, let selection = session.storySelection, let edit = session.storyEdit else { return false }
        edit(selection, .format(action)); return true
    }

    private static let storyHighlightName = "storySelection"

    /// Draws this page's part of the story selection, and hides the native one meanwhile.
    func showStorySelection() {
        let session = configuration.session
        for (id, view) in blockViews {
            guard let text = view as? UITextView, text !== cellEditor else { continue }
            text.layer.sublayers?.filter { $0.name == Self.storyHighlightName }.forEach { $0.removeFromSuperlayer() }
            guard let selection = session?.storySelection, let fragment = session?.fragmentRanges[id], fragment.story == selection.story else {
                if text.tintColor == .clear { text.tintColor = nil }
                continue
            }
            text.tintColor = .clear
            let shared = NSIntersectionRange(selection.range, fragment.range)
            guard shared.length > 0,
                  let start = text.position(from: text.beginningOfDocument, offset: shared.location - fragment.range.location),
                  let end = text.position(from: start, offset: shared.length),
                  let textRange = text.textRange(from: start, to: end) else { continue }
            let path = UIBezierPath()
            for rect in text.selectionRects(for: textRange) where rect.rect.width > 0 && rect.rect.height > 0 { path.append(UIBezierPath(rect: rect.rect)) }
            let layer = CAShapeLayer()
            layer.name = Self.storyHighlightName
            layer.path = path.cgPath
            layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
            text.layer.insertSublayer(layer, at: 0)
        }
    }

    /// The story character nearest to `point` (in this page's view), or nil if the story has no box here.
    func storyIndex(at point: CGPoint, story: UUID) -> Int? {
        guard let session = configuration.session else { return nil }
        let boxes = blockViews.compactMap { id, view -> (UITextView, NSRange)? in
            guard let text = view as? UITextView, text !== cellEditor, let fragment = session.fragmentRanges[id], fragment.story == story else { return nil }
            return (text, fragment.range)
        }
        func distance(_ text: UITextView) -> CGFloat {
            let frame = text.superview?.convert(text.frame, to: view) ?? text.frame
            return frame.contains(point) ? 0 : max(0, max(frame.minY - point.y, point.y - frame.maxY))
        }
        guard let nearest = boxes.min(by: { distance($0.0) < distance($1.0) }) else { return nil }
        let (text, range) = nearest
        let local = view.convert(point, to: text)
        guard let position = text.closestPosition(to: local) else { return nil }
        return range.location + text.offset(from: text.beginningOfDocument, to: position)
    }

    /// Caret rectangle of a story position on this page (in this page's view). At the end of a
    /// page and the start of the next, `endOfBox` picks the earlier box.
    func storyCaretRect(_ index: Int, story: UUID, endOfBox: Bool) -> CGRect? {
        guard let session = configuration.session else { return nil }
        for (id, view) in blockViews {
            guard let text = view as? UITextView, text !== cellEditor, let fragment = session.fragmentRanges[id], fragment.story == story else { continue }
            let range = fragment.range
            let inside = endOfBox ? (index > range.location && index <= NSMaxRange(range)) : (index >= range.location && index < NSMaxRange(range))
            guard inside || (range.length == 0 && index == range.location),
                  let position = text.position(from: text.beginningOfDocument, offset: index - range.location) else { continue }
            return text.convert(text.caretRect(for: position), to: self.view)
        }
        return nil
    }

    private func format(_ text: UITextView, key: NSAttributedString.Key, value: Any) {
        if text.selectedRange.length == 0 { text.typingAttributes[key] = value; return }
        text.textStorage.addAttribute(key, value: value, range: text.selectedRange)
        textViewDidChange(text)
    }
    private func resizeFont(_ text: UITextView, delta: CGFloat) {
        let current = (text.typingAttributes[.font] as? UIFont) ?? .systemFont(ofSize: 18)
        format(text, key: .font, value: current.withSize(max(6, min(144, current.pointSize + delta))))
    }

    private func textMenu(_ text: UITextView) -> UIMenu {
        let colors: [(String, UIColor)] = [("Preto", .black), ("Azul", .systemBlue), ("Vermelho", .systemRed), ("Verde", .systemGreen)]
        let alignments: [(String, NSTextAlignment)] = [("Esquerda", .left), ("Centro", .center), ("Direita", .right), ("Justificado", .justified)]
        let styles = configuration.document.effectiveNamedStyles.map { named in
            UIAction(title: named.name) { [weak self, weak text] _ in
                // Look the definition up when chosen: the style may have been redefined since.
                guard let self, let text else { return }
                self.applyNamedStyle(text, self.configuration.document.namedStyle(named.id) ?? named)
            }
        }
        let styleMenu = UIMenu(title: "Estilo", image: UIImage(systemName: "textformat"), children: styles + [
            UIAction(title: "Atualizar estilo pela seleção", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self, weak text] _ in
                if let text { self?.redefineNamedStyle(from: text) }
            }
        ])
        return UIMenu(children: [
            styleMenu,
            UIMenu(title: "Cor", children: colors.map { name, color in UIAction(title: name) { [weak self, weak text] _ in if let text { self?.format(text, key: .foregroundColor, value: color) } } }),
            UIMenu(title: "Fonte", children: ["Helvetica", "Times New Roman", "Menlo"].map { name in UIAction(title: name) { [weak self, weak text] _ in
                if let text, let font = UIFont(name: name, size: (text.typingAttributes[.font] as? UIFont)?.pointSize ?? 18) { self?.format(text, key: .font, value: font) }
            } }),
            UIMenu(title: "Alinhamento", children: alignments.map { name, alignment in UIAction(title: name) { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.alignment = alignment } } } }),
            UIAction(title: "Tachado") { [weak self, weak text] _ in if let text { self?.format(text, key: .strikethroughStyle, value: NSUnderlineStyle.single.rawValue) } },
            UIAction(title: "Marca-texto") { [weak self, weak text] _ in if let text { self?.format(text, key: .backgroundColor, value: UIColor.systemYellow) } },
            UIAction(title: "Lista com marcadores") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.textLists = [NSTextList(markerFormat: .disc, options: 0)] } } },
            UIAction(title: "Lista numerada") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.textLists = [NSTextList(markerFormat: .decimal, options: 0)] } } },
            UIAction(title: "Remover lista") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.textLists = [] } } },
            UIAction(title: "Aumentar recuo") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.headIndent += 18; $0.firstLineHeadIndent += 18 } } },
            UIAction(title: "Diminuir recuo") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.headIndent = max(0, $0.headIndent - 18); $0.firstLineHeadIndent = max(0, $0.firstLineHeadIndent - 18) } } },
            UIAction(title: "Espaçamento entre linhas: +2 pt") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.lineSpacing += 2 } } },
            UIAction(title: "Espaçamento padrão") { [weak self, weak text] _ in if let text { self?.paragraph(text) { $0.lineSpacing = 0; $0.paragraphSpacing = 0 } } },
            UIAction(title: "Inserir link") { [weak self, weak text] _ in if let text { self?.insertLink(text) } },
            UIAction(title: "Localizar e substituir") { [weak text] _ in text?.findInteraction?.presentFindNavigator(showingReplace: true) }
        ])
    }

    /// Applies a named style to the paragraphs under the selection (or caret), like Word.
    private func applyNamedStyle(_ text: UITextView, _ named: NamedStyle) {
        guard let id = textIDs[ObjectIdentifier(text)] else { return }
        let selection = text.selectedRange
        let styled = TextBridge.richText(text.attributedText)
            .applyingNamedStyle(named, utf16Range: selection.location..<(selection.location + selection.length))
        let base = (try? configuration.document.resolvedStyle(for: id)) ?? .init()
        let rendered = TextBridge.attributed(styled, base: base)
        text.attributedText = rendered
        text.selectedRange = NSRange(location: min(selection.location, rendered.length), length: min(selection.length, max(0, rendered.length - selection.location)))
        // New typing continues in the chosen style, including in an empty block.
        let caretStyle = rendered.length > 0
            ? rendered.attributes(at: min(selection.location, rendered.length - 1), effectiveRange: nil)
            : TextBridge.attributed(RichText(runs: [TextRun(" ", style: styled.runs.first?.style ?? named.style)]), base: base).attributes(at: 0, effectiveRange: nil)
        text.typingAttributes = caretStyle
        textViewDidChange(text)
    }

    /// "Update style to match selection": the formatting at the caret becomes the style's
    /// definition, and every text tagged with that style in the note follows.
    private func redefineNamedStyle(from text: UITextView) {
        let attributed = text.attributedText ?? NSAttributedString()
        guard attributed.length > 0 else { return }
        let location = min(text.selectedRange.location, attributed.length - 1)
        let current = TextBridge.richText(attributed.attributedSubstring(from: NSRange(location: location, length: 1))).runs.first?.style
        guard let current, let id = current.namedStyle, var named = configuration.document.namedStyle(id) else {
            configuration.onError(DocumentError.invalid("Posicione o cursor em um texto com estilo (Título, Corpo…) para atualizá-lo."))
            return
        }
        // System fonts report private names (".SFUI…"); keep the definition on the system font.
        named.style.fontName = current.fontName.flatMap { $0.hasPrefix(".") ? nil : $0 }
        named.style.fontSize = current.fontSize; named.style.bold = current.bold; named.style.italic = current.italic
        named.style.foreground = current.foreground; named.style.paragraph = current.paragraph
        do { configuration.onCommands(try configuration.document.redefiningNamedStyle(named)) }
        catch { configuration.onError(error) }
    }

    private func paragraph(_ text: UITextView, update: (NSMutableParagraphStyle) -> Void) {
        let range = (text.text as NSString).paragraphRange(for: text.selectedRange)
        let existing = range.location < text.textStorage.length ? text.textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : text.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        update(style)
        text.typingAttributes[.paragraphStyle] = style
        if range.length > 0 { text.textStorage.addAttribute(.paragraphStyle, value: style, range: range); textViewDidChange(text) }
    }

    private func insertLink(_ text: UITextView) {
        let alert = UIAlertController(title: "Link", message: "Selecione o texto e informe o endereço.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://"; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Aplicar", style: .default) { [weak self, weak alert, weak text] _ in
            guard let text, let value = alert?.textFields?.first?.text, let url = URL(string: value),
                  ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            self?.format(text, key: .link, value: url)
        })
        present(alert, animated: true)
    }

    private func makeObjectView(id: UUID) -> CanvasObjectView {
        let reused = objectPool.popLast()
        let object = reused ?? CanvasObjectView()
        object.id = id
        object.onMenu = { [weak self, weak object] in
            guard let id = object?.id else { return UIMenu(children: []) }
            return self?.objectMenu(id) ?? UIMenu(children: [])
        }
        if reused != nil { return object }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(moveObject(_:)))
        object.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectObject(_:)))
        object.addGestureRecognizer(tap)
        return object
    }

    private func showAlignment(_ lines: [AlignmentGuides.Line]) {
        if alignmentLines.superlayer !== surface.layer { surface.layer.addSublayer(alignmentLines) }
        alignmentLines.zPosition = 1000
        alignmentLines.strokeColor = UIColor.black.cgColor; alignmentLines.lineWidth = 1 / max(0.5, scroll.zoomScale)
        let path = UIBezierPath()
        for line in lines {
            path.move(to: CGPoint(x: line.start.x, y: line.start.y)); path.addLine(to: CGPoint(x: line.end.x, y: line.end.y))
        }
        alignmentLines.frame = surface.bounds
        alignmentLines.path = lines.isEmpty ? nil : path.cgPath
    }

    /// While an object is moved or resized into the header or footer, their edge and a notice show.
    func showBandGuides(for frame: CGRect) {
        guard configuration.document.kind == .note else { return }
        bandGuides.show(for: LogicalRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), settings: configuration.document.canvas)
        surface.bringSubviewToFront(bandGuides)
    }

    /// Places the children of `parent` (in their order, each followed by its own children) right
    /// above `view`; returns the last view placed.
    private func stackChildren(of parent: UUID, above view: UIView) -> UIView {
        var cursor = view
        for child in configuration.document.blocks.filter({ $0.parentID == parent }).sorted(by: { $0.order < $1.order }) {
            guard let childView = blockViews[child.id] else { continue }
            surface.insertSubview(childView, aboveSubview: cursor)
            cursor = stackChildren(of: child.id, above: childView)
        }
        return cursor
    }

    /// An object being dragged is shown above everything (with its children) until it is dropped.
    private func lift(_ id: UUID) {
        guard let view = blockViews[id] else { return }
        surface.bringSubviewToFront(view)
        _ = stackChildren(of: id, above: view)
        surface.bringSubviewToFront(ink)
    }

    /// Stacking index that puts `block` above every other object on this page (unchanged if it already is).
    private func frontIndex(for block: CanvasBlock) -> Int {
        let others = configuration.document.blocks.filter { $0.id != block.id && $0.parentID == nil && $0.isStacked }.map(\.layout.zIndex)
        guard let top = others.max() else { return block.layout.zIndex }
        return block.layout.zIndex > top ? block.layout.zIndex : top + 1
    }

    private func backIndex(for block: CanvasBlock) -> Int {
        let others = configuration.document.blocks.filter { $0.id != block.id && $0.parentID == nil && $0.isStacked }.map(\.layout.zIndex)
        guard let bottom = others.min() else { return block.layout.zIndex }
        return block.layout.zIndex < bottom ? block.layout.zIndex : bottom - 1
    }

    @objc private func moveObject(_ gesture: UIPanGestureRecognizer) {
        guard let object = gesture.view as? CanvasObjectView, let id = object.id,
              var block = configuration.document.blocks.first(where: { $0.id == id }) else { return }
        if gesture.state == .began {
            movingID = id; moveOrigin = object.center; configuration.session?.objectDragBegan?(self); lift(id)
            alignmentSnap = .none; alignmentFeedback.prepare()
        }
        var delta = gesture.translation(in: surface)
        if gesture.state == .changed || gesture.state == .ended {
            // Middles lining up with another object or the page: snap and show the line.
            let raw = object.bounds.size
            let proposed = LogicalRect(x: moveOrigin.x + delta.x - raw.width / 2, y: moveOrigin.y + delta.y - raw.height / 2, width: raw.width, height: raw.height)
            let others = configuration.document.blocks.filter { $0.id != id && $0.parentID == nil && $0.isStacked && $0.textFlowID == nil }
                .compactMap { frames[$0.id] }
            let snap = AlignmentGuides.snap(proposed, to: others, page: configuration.document.canvas.size, threshold: 6 / max(0.5, scroll.zoomScale))
            if !snap.lines.isEmpty, snap.lines.count > alignmentSnap.lines.count { alignmentFeedback.selectionChanged() }
            alignmentSnap = snap
            delta.x += snap.offset.x; delta.y += snap.offset.y
        }
        if gesture.state == .changed {
            object.center = CGPoint(x: moveOrigin.x + delta.x, y: moveOrigin.y + delta.y)
            showBandGuides(for: object.frame)
            showAlignment(alignmentSnap.lines)
        }
        if gesture.state != .changed, gesture.state != .began { bandGuides.hide(); showAlignment([]) }
        // Dropped on another page: the object moves there (a whole root object, not a text story box).
        if gesture.state == .ended, block.parentID == nil, block.textFlowID == nil,
           let target = configuration.session?.pageForDrop?(self, object.superview?.convert(object.frame, to: view) ?? object.frame) {
            block.pageID = target.page
            block.layout.mode = .absolute
            block.layout.frame.x = target.origin.x; block.layout.frame.y = target.origin.y
            if selectedObjectID == id { selectedObjectID = nil }
            configuration.onCommands([.replaceBlock(block)]); movingID = nil
            return
        }
        if gesture.state == .ended {
            if block.layout.mode == .flow, let world = frames[id] {
                let parent = block.parentID.flatMap { frames[$0] }
                block.layout.frame.x = world.x - (parent?.x ?? 0)
                block.layout.frame.y = world.y - (parent?.y ?? 0)
                block.layout.mode = .absolute
            }
            block.layout.frame.x += delta.x; block.layout.frame.y += delta.y
            // What was moved stays where the user put it: above what it was dragged over.
            if block.parentID == nil { block.layout.zIndex = frontIndex(for: block) }
            configuration.onCommands([.replaceBlock(block)]); movingID = nil
        } else if gesture.state == .cancelled { movingID = nil; render() }
    }

    @objc private func selectObject(_ gesture: UITapGestureRecognizer) {
        guard let object = gesture.view as? CanvasObjectView else { return }
        handleObjectTap(object, at: gesture.location(in: object))
    }

    func handleObjectTap(_ object: CanvasObjectView, at point: CGPoint) {
        guard let id = object.id else { return }
        // A transcription card folds with a tap on its header and opens with a tap on the square.
        if connectingFrom == nil, let block = object.block, case .shape(let shape) = block.content, shape.kind == .transcript,
           shape.folded != nil || point.y <= CGFloat(Stickers.transcriptHeader) {
            toggleFold(block); return
        }
        if croppingID != id { croppingID = nil }
        let wasSelected = selectedObjectID == id
        selectedObjectID = id
        if tableFocus?.block != id { tableFocus = nil }
        render()
        if connectingFrom == nil, case .table(let table) = object.block?.content {
            tapTable(object, table: table, at: point, wasSelected: wasSelected); return
        }
        if connectingFrom == nil, case .audio(let reference) = object.block?.content {
            toggleAudio(id, hash: reference.hash); return
        }
        if connectingFrom == nil, case .video = object.block?.content, let play = configuration.onPlayVideo {
            stopAudio(); play(id); return
        }
        if wasSelected, connectingFrom == nil, case .shape(let shape) = object.block?.content, shape.kind == .calendar {
            pickDay(for: id); return
        }
        if let source = connectingFrom {
            connectingFrom = nil
            if source != id { configuration.onCommands([.setRelation(.init(sourceID: source, targetID: id, kind: .connector, style: .init()))]) }
        } else if case .pdf = object.block?.content { configuration.onOpenPDF(id) }
        else if case .noteReference(let ref) = object.block?.content { configuration.onOpenNote(ref.documentID) }
    }

    /// Folds an open transcription card beside its audio, or opens a folded one (one undo step).
    private func toggleFold(_ block: CanvasBlock) {
        do {
            let changed = Stickers.isFolded(block)
                ? try Stickers.unfolding(block, page: configuration.document.canvas.size)
                : try Stickers.folding(block, audio: Stickers.audio(near: block, in: configuration.document))
            if selectedObjectID == block.id { selectedObjectID = nil }
            if let text = activeText, configuration.document.blocks.contains(where: { $0.parentID == block.id && blockViews[$0.id] === text }) {
                text.resignFirstResponder()
            }
            UISelectionFeedbackGenerator().selectionChanged()
            configuration.onCommands([.replaceBlock(changed)])
        } catch { configuration.onError(error) }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pencilWatcher {
            if touch.type == .pencil, !(configuration.session?.prefersPencil ?? false) {
                configuration.session?.pencilDetected()
                applyInputMode()
            }
            return false
        }
        if gestureRecognizer === inkTap { return true }
        return touch.view === surface && (configuration.tool == .select || !ink.isUserInteractionEnabled)
    }
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === inkTap   // never delays or blocks PencilKit's own drawing gesture
    }

    /// Tap on empty page: first ends typing or clears the selection; otherwise starts a text block.
    @objc private func tapCanvas(_ gesture: UITapGestureRecognizer) {
        // A simple note: a tap on the paper puts the caret at the end of its text, typing or not.
        if configuration.document.canvas.isSimpleNote { insertText(at: gesture.location(in: surface)); return }
        if let cellEditor { cellEditor.resignFirstResponder(); return }
        if let activeText { activeText.resignFirstResponder(); return }
        if selectedObjectID != nil { selectedObjectID = nil; croppingID = nil; render(); return }
        insertText(at: gesture.location(in: surface))
    }

    /// Finger tap while an Apple Pencil draws (fingers cannot draw then, so no dot exists): the same
    /// meaning as in cursor mode, so writing never requires switching tools first.
    @objc private func tapInk(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: surface)
        for view in surface.subviews.reversed() {
            guard let object = view as? CanvasObjectView, object.id != nil, !object.isHidden else { continue }
            let local = object.convert(point, from: surface)
            if object.point(inside: local, with: nil) { handleObjectTap(object, at: local); return }
        }
        for view in surface.subviews.reversed() {
            guard let text = view as? UITextView, text !== cellEditor, textIDs[ObjectIdentifier(text)] != nil else { continue }
            let local = text.convert(point, from: surface)
            guard text.point(inside: local, with: nil) else { continue }
            text.becomeFirstResponder()
            if let position = text.closestPosition(to: local) { text.selectedTextRange = text.textRange(from: position, to: position) }
            return
        }
        insertText(at: point)
    }

    private func insertText(at point: CGPoint) {
        // One line tall; pagination grows it with the text (down to the text area's bottom).
        // A note's text lives in the page's text area (Word's A4 margins in new notes): a tap in a
        // margin starts the text at the margin's edge.
        let area = configuration.document.canvas.textArea
        let frame: LogicalRect
        if configuration.document.canvas.isSimpleNote {
            // A simple note has one text: a tap anywhere continues it (at its end), or starts it
            // at the top of the page.
            if let story = configuration.document.blocks.filter({ $0.parentID == nil && $0.textFlowID != nil }).max(by: { $0.order < $1.order }),
               let textView = blockViews[story.id] as? UITextView {
                textView.becomeFirstResponder()
                textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
                return
            }
            frame = LogicalRect(x: area.x, y: area.y, width: area.width, height: 44)
        } else if configuration.document.kind == .note {
            let x = min(max(point.x, area.x), area.x + area.width - 80)
            var y: Double = min(max(Double(point.y), area.y), area.y + area.height - 44)
            // On notebook paper the text starts on the line under the finger.
            if let lines = configuration.document.canvas.ruledLines {
                let band = lines.bandTop(containing: y + 4)
                y = band - 4 < area.y ? y : band - 4
            }
            frame = LogicalRect(x: x, y: y, width: area.x + area.width - x, height: 44)
        } else {
            frame = LogicalRect(x: point.x, y: point.y, width: max(80, configuration.document.canvas.size.width - point.x - 24), height: 44)
        }
        var block = CanvasBlock(order: nextOrder, layout: .init(mode: .absolute, frame: frame), content: .text(RichText("")))
        if configuration.document.kind == .note { block.textFlowID = block.id }
        pendingFocusID = block.id
        configuration.onCommands([.insertBlock(block)])
    }
    private func insertTable(at point: CGPoint) {
        let size = configuration.document.canvas.size
        let width = max(120, min(480, size.width - point.x - 24))
        let table = CanvasTable(rows: 3, columns: 3, width: width)
        let block = CanvasBlock(order: nextOrder, layout: .init(mode: .absolute,
            frame: .init(x: point.x, y: point.y, width: table.width, height: table.height)), content: .table(table))
        selectedObjectID = block.id
        configuration.onCommands([.insertBlock(block)])
    }

    /// Second tap on a selected table edits the cell under the finger.
    private func beginEditingCell(_ object: CanvasObjectView, at point: CGPoint) {
        guard let id = object.id, let block = configuration.document.blocks.first(where: { $0.id == id }),
              case .table(let table) = block.content else { return }
        let sx = object.bounds.width / max(1, table.width), sy = object.bounds.height / max(1, table.height)
        guard let hit = table.cell(at: .init(x: Double(point.x / sx), y: Double(point.y / sy))) else { return }
        let rect = table.frame(row: hit.row, column: hit.column)
        let editor: UITextView
        if let existing = cellEditor {
            // Moving between cells keeps the same first responder: the keyboard stays up.
            commitCell(keepEditor: true); editor = existing
        } else {
            editor = UITextView(usingTextLayoutManager: true)
            editor.delegate = self
            editor.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.97)
            editor.layer.borderColor = UIColor.systemBlue.cgColor; editor.layer.borderWidth = 2
            editor.textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
            editor.accessibilityIdentifier = "tableCellEditor"
            surface.addSubview(editor)
        }
        let base = TableRendering.base(header: table.headerRow && hit.row == 0)
        editor.attributedText = TextBridge.attributed(table.cells[hit.row][hit.column].text, base: base)
        editor.typingAttributes = TextBridge.attributed(RichText(" "), base: base).attributes(at: 0, effectiveRange: nil)
        editor.transform = .identity
        editor.bounds = CGRect(x: 0, y: 0, width: rect.width * sx, height: max(rect.height * sy, 36))
        editor.center = object.convert(CGPoint(x: (rect.x + rect.width / 2) * sx, y: (rect.y + rect.height / 2) * sy), to: surface)
        editor.transform = object.transform
        cellEditor = editor; editingCell = (id, hit.row, hit.column)
        surface.bringSubviewToFront(editor)
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
        editor.selectedRange = NSRange(location: editor.attributedText.length, length: 0)
        updateInkInteraction()
    }

    /// Saves the open cell (if it changed) and grows its row to fit; one undo step per cell edit.
    private func commitCell(keepEditor: Bool = false) {
        guard let editor = cellEditor, let cell = editingCell else { return }
        let text = TextBridge.richText(editor.attributedText ?? NSAttributedString())
        let needed = editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height
        if !keepEditor {
            cellEditor = nil; editingCell = nil
            editor.delegate = nil; editor.removeFromSuperview()
            updateInkInteraction()
        }
        guard let block = configuration.document.blocks.first(where: { $0.id == cell.block }), case .table(let table) = block.content,
              table.cells.indices.contains(cell.row), table.cells[cell.row].indices.contains(cell.column) else { return }
        let old = table.cells[cell.row][cell.column].text
        guard old != text, !(old.plainText.isEmpty && text.plainText.isEmpty) else { return }
        do {
            let updated = try block.updatingTable {
                try $0.settingText(text, row: cell.row, column: cell.column).fittingRow(cell.row, toContentHeight: Double(needed))
            }
            configuration.onCommands([.replaceBlock(updated)])
        } catch { configuration.onError(error) }
    }

    // MARK: Audio

    private var audioPlayer: AVAudioPlayer?
    private(set) var playingAudio: UUID?
    private var audioTimer: Timer?
    private var audioDurations: [String: TimeInterval] = [:]

    /// Length of an audio file, read once per file.
    private func audioDuration(_ hash: String) -> TimeInterval? {
        if let known = audioDurations[hash] { return known }
        guard let data = configuration.drawingData(hash), let player = try? AVAudioPlayer(data: data) else { return nil }
        audioDurations[hash] = player.duration
        return player.duration
    }

    /// A tap on an audio block plays it, or pauses it if it is playing; another one stops it.
    func toggleAudio(_ id: UUID, hash: String) {
        if playingAudio == id, let player = audioPlayer {
            if player.isPlaying { player.pause(); audioTimer?.invalidate() } else { player.play(); startAudioTimer() }
            updateAudioView(); return
        }
        stopAudio()
        guard let data = configuration.drawingData(hash) else { configuration.onError(DocumentError.invalid("O áudio não está disponível.")); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            audioPlayer = player; playingAudio = id
            player.play(); startAudioTimer(); updateAudioView()
        } catch { configuration.onError(DocumentError.invalid("Não foi possível tocar este áudio.")) }
    }

    func stopAudio() {
        audioTimer?.invalidate(); audioTimer = nil
        audioPlayer?.stop(); audioPlayer = nil
        if let id = playingAudio, let view = blockViews[id] as? CanvasObjectView { view.audioPlaying = false; view.audioProgress = 0 }
        playingAudio = nil
    }

    private func startAudioTimer() {
        audioTimer?.invalidate()
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAudioView() }
        }
    }

    private func updateAudioView() {
        guard let id = playingAudio, let player = audioPlayer else { return }
        if !player.isPlaying, player.currentTime == 0 || player.currentTime >= player.duration - 0.05 {
            // Played to the end.
            stopAudio(); return
        }
        guard let view = blockViews[id] as? CanvasObjectView else { return }
        view.audioPlaying = player.isPlaying
        view.audioProgress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAudio()
    }

    // MARK: Handwriting to text

    private var handwritingTimer: Timer?
    /// Strokes written since the last conversion (figures and lines turned into shapes drop out).
    private var handwritingKeys: Set<Double> = []
    private var readingHandwriting = false

    /// Writing is read after a pause when it may become text, or may be a formula to answer.
    private var readsWriting: Bool {
        configuration.session?.handwritingToText == true || (configuration.document.canvas.solveEquations && configuration.document.kind == .note)
    }

    /// A moment after the pen stops, the writing is read on the device. A formula ("12+7=",
    /// "2x+4=10") is answered beside it, in the handwriting font and in blue, when "Resolver
    /// equações" is on (the default); the writing stays. Otherwise, with "Escrita vira texto" on,
    /// the writing becomes text in the chosen font, where it was written and about as large.
    /// Each is one undo step. Strokes that read as neither stay as they are.
    func convertHandwriting() {
        guard !readingHandwriting, !usingTool, let session = configuration.session, readsWriting else { return }
        let keys = handwritingKeys
        handwritingKeys.removeAll()
        let strokes = ink.drawing.strokes.filter { keys.contains(Self.key($0)) }
        guard !strokes.isEmpty else { return }
        let groups = HandwritingReader.lines(strokes.map(\.renderBounds)).map { $0.map { strokes[$0] } }
        let pictures: [(strokes: [PKStroke], bounds: CGRect, image: CGImage)] = groups.compactMap { group in
            let bounds = group.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
            guard bounds.height >= 8, let image = HandwritingReader.picture(of: group, bounds: bounds) else { return nil }
            return (group, bounds, image)
        }
        guard !pictures.isEmpty else { return }
        readingHandwriting = true
        let images = pictures.map(\.image)
        let language = [Locale.current.language.languageCode?.identifier == "pt" ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : "pt-BR", "en-US"]
        let font = session.handwritingFont
        let solve = configuration.document.canvas.solveEquations, toText = session.handwritingToText
        Task { [weak self] in
            // Per group: (answer to a formula, text reading) — only what is needed is read.
            let readings = await Task.detached(priority: .userInitiated) {
                images.map { image -> (answer: String?, text: HandwritingReader.Reading?) in
                    if solve, let math = HandwritingReader.read(image, languages: ["en-US"], correction: false),
                       let formula = HandwrittenMath.normalize(math.text), let answer = HandwrittenMath.answer(formula) {
                        return (answer, nil)
                    }
                    return (nil, toText ? HandwritingReader.read(image, languages: language) : nil)
                }
            }.value
            guard let self else { return }
            self.readingHandwriting = false
            guard !self.usingTool else { self.handwritingKeys.formUnion(keys); return }
            var removed = Set<Double>()
            var commands: [DocumentCommand] = []
            var order = (self.configuration.document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? 0) + 1
            let alive = Set(self.ink.drawing.strokes.map(Self.key))
            let pageWidth = CGFloat(self.configuration.document.canvas.size.width)
            for (picture, reading) in zip(pictures, readings) {
                // Still there (not erased or turned into a shape meanwhile).
                let groupKeys = picture.strokes.map(Self.key)
                guard groupKeys.allSatisfy(alive.contains) else { continue }
                if let answer = reading.answer {
                    let size = min(96, max(12, (picture.bounds.height * 0.8).rounded()))
                    let width = max(40, CGFloat(answer.count) * size * 0.55 + 16)
                    let beside = picture.bounds.maxX + 10 + width <= pageWidth - 8
                    let frame = beside ? CGRect(x: picture.bounds.maxX + 10, y: picture.bounds.minY - size * 0.1, width: width, height: max(picture.bounds.height, size * 1.4))
                                       : CGRect(x: picture.bounds.minX, y: picture.bounds.maxY + 6, width: width, height: size * 1.4)
                    commands.append(.insertBlock(CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)),
                                                             style: .init(fontName: font, fontSize: size, foreground: "#1D4ED8"),
                                                             content: .text(RichText(answer)), presentation: .init(wrap: .none))))
                    order += 1
                    continue
                }
                guard let text = reading.text, text.confidence >= 0.35, text.text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let lineHeight = picture.bounds.height / CGFloat(max(1, text.lines))
                let size = min(96, max(10, (lineHeight * 0.78).rounded()))
                let block = CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(
                        x: picture.bounds.minX, y: picture.bounds.minY - size * 0.15,
                        width: max(picture.bounds.width * 1.15, 60), height: max(picture.bounds.height, size * 1.4))),
                    style: .init(fontName: font, fontSize: size, foreground: "#111827"),
                    content: .text(RichText(text.text)), presentation: .init(wrap: .none))
                order += 1
                commands.append(.insertBlock(block))
                removed.formUnion(groupKeys)
            }
            guard !commands.isEmpty else { return }
            if !removed.isEmpty {
                self.applyingDrawing = true
                self.ink.drawing = PKDrawing(strokes: self.ink.drawing.strokes.filter { !removed.contains(Self.key($0)) })
                self.applyingDrawing = false
                self.saveDrawing(commands)
            } else {
                self.configuration.onCommands(commands)
            }
        }
    }

    // MARK: Background removal

    private var cutouts: [UUID: UIActivityIndicatorView] = [:]

    /// Removes the picture's background (subject lifting for photos, paper for drawings), after a
    /// preview where the result can be retouched. The work runs off the main thread.
    func cutOut(_ id: UUID) {
        guard cutouts[id] == nil, let block = configuration.document.blocks.first(where: { $0.id == id }),
              let hash = block.content.assetHash, let image = configuration.image(hash),
              let source = ImageCutout.raster(image, maxSide: 2048) else {
            configuration.onError(DocumentError.invalid("Não foi possível ler esta imagem.")); return
        }
        let sheet = CutoutPreviewController(source: source) { [weak self] processed in self?.applyCutout(id, processed) }
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        // Painting on the preview must not pull the sheet down.
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }

    private func applyCutout(_ id: UUID, _ processed: ImageCutout.Processed) {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .systemBlue; spinner.accessibilityIdentifier = "cutoutProgress"
        if let view = blockViews[id] { spinner.center = view.center }
        surface.addSubview(spinner); spinner.startAnimating()
        cutouts[id] = spinner
        let image = processed.cutout.image
        Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { ImageCutout.png(image) }.value
            guard let self else { return }
            self.cutouts.removeValue(forKey: id)?.removeFromSuperview()
            // The picture may have been deleted meanwhile.
            guard self.configuration.document.blocks.contains(where: { $0.id == id }) else { return }
            guard let png else { self.configuration.onError(DocumentError.invalid("Não foi possível gravar a imagem sem fundo.")); return }
            self.configuration.onReplaceImage?(id, png)
        }
    }

    // MARK: Tables

    /// Taps on a table. The first cell of a row (column 0) or of a column (row 0) picks that line:
    /// one tap shows its resize handle, a quick second tap offers duplicate/delete, a slower
    /// second tap edits the cell. Any other cell: first tap selects, second tap edits.
    private func tapTable(_ object: CanvasObjectView, table: CanvasTable, at point: CGPoint, wasSelected: Bool) {
        guard let id = object.id else { return }
        let sx = object.bounds.width / max(1, table.width), sy = object.bounds.height / max(1, table.height)
        guard let hit = table.cell(at: .init(x: Double(point.x / sx), y: Double(point.y / sy))) else { return }
        guard let picked = TableFocus.picked(block: id, row: hit.row, column: hit.column) else {
            lastFirstCellTap = nil
            if tableFocus != nil { tableFocus = nil; render() }
            if wasSelected { beginEditingCell(object, at: point) }
            return
        }
        let now = CACurrentMediaTime()
        if let last = lastFirstCellTap, last.block == id, last.row == hit.row, last.column == hit.column, now - last.time < 0.4 {
            lastFirstCellTap = nil
            if cellEditor != nil { commitCell() }
            tableFocus = picked; render()
            presentLineMenu(for: picked, at: object.convert(point, to: surface))
            return
        }
        lastFirstCellTap = (id, hit.row, hit.column, now)
        if wasSelected, tableFocus == picked { beginEditingCell(object, at: point); return }
        if cellEditor != nil { commitCell() }
        tableFocus = picked; render()
    }

    enum TableLineAction: Equatable { case duplicateRow(Int), deleteRow(Int), duplicateColumn(Int), deleteColumn(Int), addRow, addColumn }

    func applyTableAction(_ action: TableLineAction, to blockID: UUID) {
        guard let block = configuration.document.blocks.first(where: { $0.id == blockID }), case .table = block.content else { return }
        do {
            let updated = try block.updatingTable { table in
                switch action {
                case .duplicateRow(let row): return try table.duplicatingRow(at: row)
                case .deleteRow(let row): return try table.removingRow(at: row)
                case .duplicateColumn(let column): return try table.duplicatingColumn(at: column)
                case .deleteColumn(let column): return try table.removingColumn(at: column)
                case .addRow: return try table.insertingRow(at: table.rowCount)
                case .addColumn: return try table.insertingColumn(at: table.columnCount)
                }
            }
            // The focus follows the copy; a deleted line leaves nothing picked.
            switch action {
            case .duplicateRow(let row): tableFocus = TableFocus(block: blockID, row: row + 1, column: nil)
            case .duplicateColumn(let column): tableFocus = TableFocus(block: blockID, row: nil, column: column + 1)
            case .deleteRow, .deleteColumn: tableFocus = nil
            case .addRow, .addColumn: break
            }
            configuration.onCommands([.replaceBlock(updated)])
        } catch { configuration.onError(error) }
    }

    /// Actions for the picked line; the corner cell is the first of both a row and a column.
    func lineActions(for focus: TableFocus) -> [(title: String, symbol: String, destructive: Bool, action: TableLineAction)] {
        guard let block = configuration.document.blocks.first(where: { $0.id == focus.block }), case .table(let table) = block.content else { return [] }
        var actions: [(String, String, Bool, TableLineAction)] = []
        if let row = focus.row {
            actions.append(("Duplicar linha", "plus.square.on.square", false, .duplicateRow(row)))
            if table.rowCount > 1 { actions.append(("Excluir linha", "trash", true, .deleteRow(row))) }
        }
        if let column = focus.column {
            actions.append(("Duplicar coluna", "plus.square.on.square", false, .duplicateColumn(column)))
            if table.columnCount > 1 { actions.append(("Excluir coluna", "trash", true, .deleteColumn(column))) }
        }
        return actions.map { (title: $0.0, symbol: $0.1, destructive: $0.2, action: $0.3) }
    }

    private func presentLineMenu(for focus: TableFocus, at point: CGPoint) {
        let actions = lineActions(for: focus)
        guard !actions.isEmpty else { return }
        lineMenu = UIMenu(children: actions.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol), attributes: item.destructive ? .destructive : []) { [weak self] _ in
                self?.applyTableAction(item.action, to: focus.block)
            }
        })
        lineMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: "tableLine" as NSString, sourcePoint: point))
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        interaction === lineMenuInteraction ? lineMenu : UIMenu(children: suggestedActions)
    }

    /// "+" buttons and the picked line's tint and handle over the selected table.
    private func showTableChrome() {
        tableChrome?.removeFromSuperview(); tableChrome = nil
        guard let id = selectedObjectID, let object = blockViews[id] as? CanvasObjectView, croppingID != id,
              let block = configuration.document.blocks.first(where: { $0.id == id }), case .table(let table) = block.content else {
            tableFocus = nil; return
        }
        if let focus = tableFocus, focus.block != id
            || focus.row.map({ !table.rowHeights.indices.contains($0) }) == true
            || focus.column.map({ !table.columnWidths.indices.contains($0) }) == true { tableFocus = nil }
        let chrome = TableChrome(table: table, focus: tableFocus)
        chrome.bounds = object.bounds; chrome.center = object.center; chrome.transform = object.transform
        chrome.onAddRow = { [weak self] in self?.applyTableAction(.addRow, to: id) }
        chrome.onAddColumn = { [weak self] in self?.applyTableAction(.addColumn, to: id) }
        let originCenter = object.center
        chrome.onResize = { [weak self, weak object, weak chrome] axis, index, size, ended in
            guard let self, let object, let chrome else { return }
            do {
                let updated = try block.updatingTable {
                    try (axis == .row ? $0.settingRowHeight(size, at: index) : $0.settingColumnWidth(size, at: index))
                }
                if ended {
                    if updated != block { self.configuration.onCommands([.replaceBlock(updated)]) } else { self.render() }
                    return
                }
                guard case .table(let next) = updated.content else { return }
                // Live preview: the origin stays put, so the center moves by half the growth (in the table's axes).
                let old = block.layout.frame, new = updated.layout.frame
                let shift = CGPoint(x: (new.width - old.width) / 2, y: (new.height - old.height) / 2)
                    .applying(CGAffineTransform(rotationAngle: block.effectivePresentation.rotationRadians))
                object.block = updated
                object.bounds.size = CGSize(width: new.width, height: new.height)
                object.center = CGPoint(x: originCenter.x + shift.x, y: originCenter.y + shift.y)
                object.setNeedsDisplay()
                chrome.table = next; chrome.bounds = object.bounds; chrome.center = object.center
                if let handles = self.selectionOverlay { handles.bounds = object.bounds; handles.center = object.center; handles.setNeedsLayout() }
            } catch { self.configuration.onError(error) }
        }
        surface.addSubview(chrome); tableChrome = chrome
    }

    /// Test hooks: a finger tap in the middle of a cell, and the chrome currently shown.
    func tapTableCell(_ id: UUID, row: Int, column: Int) {
        guard let object = blockViews[id] as? CanvasObjectView, case .table(let table) = object.block?.content else { return }
        let f = table.frame(row: row, column: column)
        let sx = object.bounds.width / max(1, table.width), sy = object.bounds.height / max(1, table.height)
        handleObjectTap(object, at: CGPoint(x: (f.x + f.width / 2) * sx, y: (f.y + f.height / 2) * sy))
    }
    var tableChromeForTesting: TableChrome? { tableChrome }
    var editingCellForTesting: (row: Int, column: Int)? { editingCell.map { ($0.row, $0.column) } }

    /// Long press on a table: add lines first (the most common need), then the row and the
    /// column under the finger, then the cell and the table's look.
    private func tableMenu(_ block: CanvasBlock, _ table: CanvasTable) -> [UIMenuElement] {
        var cell = (row: 0, column: 0)
        if let object = blockViews[block.id] as? CanvasObjectView, let location = object.menuLocation {
            let sx = object.bounds.width / max(1, table.width), sy = object.bounds.height / max(1, table.height)
            if let hit = table.cell(at: .init(x: Double(location.x / sx), y: Double(location.y / sy))) { cell = hit }
        }
        func edit(_ title: String, _ symbol: String? = nil, destructive: Bool = false, _ change: @escaping (CanvasTable) throws -> CanvasTable) -> UIAction {
            UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, attributes: destructive ? .destructive : []) { [weak self] _ in
                guard let self else { return }
                do { self.configuration.onCommands([.replaceBlock(try block.updatingTable(change))]) }
                catch { self.configuration.onError(error) }
            }
        }
        let colors: [(String, String?)] = [("Sem cor", nil), ("Cinza", "#F3F4F6"), ("Amarelo", "#FEF3C7"), ("Verde", "#DCFCE7"), ("Azul", "#DBEAFE"), ("Rosa", "#FCE7F3")]
        let add = UIMenu(title: "", options: .displayInline, children: [
            edit("Nova linha", "plus.rectangle") { try $0.insertingRow(at: $0.rowCount) },
            edit("Nova coluna", "plus.rectangle.portrait") { try $0.insertingColumn(at: $0.columnCount) },
            UIAction(title: "Editar célula", image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let self, let object = self.blockViews[block.id] as? CanvasObjectView else { return }
                let f = table.frame(row: cell.row, column: cell.column)
                let sx = object.bounds.width / max(1, table.width), sy = object.bounds.height / max(1, table.height)
                self.beginEditingCell(object, at: CGPoint(x: (f.x + f.width / 2) * sx, y: (f.y + f.height / 2) * sy))
            },
        ])
        let row = UIMenu(title: "Linha \(cell.row + 1)", image: UIImage(systemName: "rectangle.split.1x2"), children: [
            edit("Inserir linha acima", "arrow.up.to.line") { try $0.insertingRow(at: cell.row) },
            edit("Inserir linha abaixo", "arrow.down.to.line") { try $0.insertingRow(at: cell.row + 1) },
            edit("Duplicar linha", "plus.square.on.square") { try $0.duplicatingRow(at: cell.row) },
            UIAction(title: "Ajustar altura", image: UIImage(systemName: "arrow.up.and.down")) { [weak self] _ in
                self?.tableFocus = TableFocus(block: block.id, row: cell.row, column: nil); self?.selectedObjectID = block.id; self?.render()
            },
            edit("Excluir linha", "trash", destructive: true) { try $0.removingRow(at: cell.row) },
        ])
        let column = UIMenu(title: "Coluna \(cell.column + 1)", image: UIImage(systemName: "rectangle.split.2x1"), children: [
            edit("Inserir coluna à esquerda", "arrow.left.to.line") { try $0.insertingColumn(at: cell.column) },
            edit("Inserir coluna à direita", "arrow.right.to.line") { try $0.insertingColumn(at: cell.column + 1) },
            edit("Duplicar coluna", "plus.square.on.square") { try $0.duplicatingColumn(at: cell.column) },
            UIAction(title: "Ajustar largura", image: UIImage(systemName: "arrow.left.and.right")) { [weak self] _ in
                self?.tableFocus = TableFocus(block: block.id, row: nil, column: cell.column); self?.selectedObjectID = block.id; self?.render()
            },
            edit("Excluir coluna", "trash", destructive: true) { try $0.removingColumn(at: cell.column) },
        ])
        let look = UIMenu(title: "Aparência", image: UIImage(systemName: "paintbrush"), children: [
            edit(table.headerRow ? "Remover cabeçalho" : "Primeira linha como cabeçalho", "rectangle.topthird.inset.filled") { var t = $0; t.headerRow.toggle(); return t },
            UIMenu(title: "Cor da célula", children: colors.map { name, color in
                edit(name) { var t = $0; t.cells[cell.row][cell.column].background = color; return t }
            }),
            UIMenu(title: "Bordas", children: [("Sem borda", 0.0), ("Fina", 1.0), ("Média", 2.0)].map { name, width in
                edit(name) { var t = $0; t.borderWidth = width; return t }
            }),
        ])
        return [UIMenu(title: "Tabela", options: .displayInline, children: [add, row, column, look])]
    }

    private var nextOrder: Int { (configuration.document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1 }

    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // A simple note holds text only: nothing to insert on the page.
        guard !configuration.document.canvas.isSimpleNote else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [UIAction(title: "Texto") { _ in self.insertText(at: location) },
                                     UIAction(title: "Tabela", image: UIImage(systemName: "tablecells")) { _ in self.insertTable(at: location) }] +
                [ShapeKind.rectangle, .ellipse, .diamond, .triangle].map { kind in
                    UIAction(title: kind.title) { _ in
                        self.configuration.onCommands(DiagramCommands.insertNode(kind: kind, frame: .init(x: location.x, y: location.y, width: 180, height: 110), order: self.nextOrder))
                    }
                })
        })
    }

    private func objectMenu(_ id: UUID) -> UIMenu {
        guard let block = configuration.document.blocks.first(where: { $0.id == id }) else { return UIMenu(children: []) }
        func update(_ transform: @escaping (inout CanvasBlock) -> Void) -> UIActionHandler {
            { [weak self] _ in var changed = block; transform(&changed); self?.configuration.onCommands([.replaceBlock(changed)]) }
        }
        let colors = [("Azul", "#2563EB"), ("Verde", "#16A34A"), ("Coral", "#F97316"), ("Branco", "#FFFFFF"), ("Preto", "#111827")]
        var actions: [UIMenuElement] = [
            UIMenu(title: "", options: .displayInline, children: block.parentID != nil ? [] : [
                UIAction(title: "Trazer para a frente", image: UIImage(systemName: "square.3.layers.3d.top.filled"),
                         handler: update { [weak self] in $0.layout.zIndex = self?.frontIndex(for: $0) ?? $0.layout.zIndex }),
                UIAction(title: "Enviar para trás", image: UIImage(systemName: "square.3.layers.3d.bottom.filled"),
                         handler: update { [weak self] in $0.layout.zIndex = self?.backIndex(for: $0) ?? $0.layout.zIndex }),
            ]),
            UIAction(title: "Conectar a outro bloco") { [weak self] _ in self?.connectingFrom = id },
            UIAction(title: "Redimensionar") { [weak self] _ in self?.resize(block) },
            UIAction(title: "Girar 90°", handler: update { var p = $0.effectivePresentation; p.rotationRadians += .pi / 2; $0.presentation = p }),
            UIMenu(title: "Contorno do texto", children: TextWrapMode.allMenuCases.map { mode in
                UIAction(title: mode.title, handler: update { var p = $0.effectivePresentation; p.wrap = mode; $0.presentation = p })
            })
        ]
        if case .pdf = block.content { actions.insert(UIAction(title: "Abrir PDF") { [weak self] _ in self?.configuration.onOpenPDF(id) }, at: 0) }
        if case .audio = block.content, configuration.onTranscribe != nil {
            actions.insert(UIAction(title: "Transcrever", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.stopAudio(); self?.configuration.onTranscribe?(id)
            }, at: 0)
        }
        switch block.content {
        case .image, .sticker:
            actions.insert(UIAction(title: "Remover fundo", image: UIImage(systemName: "person.crop.rectangle.badge.plus")) { [weak self] _ in
                self?.cutOut(id)
            }, at: 0)
        default: break
        }
        if case .table(let table) = block.content { actions.insert(contentsOf: tableMenu(block, table), at: 0) }
        if case .shape(let shape) = block.content, shape.kind == .transcript {
            actions.insert(UIAction(title: shape.folded == nil ? "Recolher" : "Abrir",
                                    image: UIImage(systemName: shape.folded == nil ? "chevron.up" : "chevron.down")) { [weak self] _ in
                self?.toggleFold(block)
            }, at: 0)
            // A folded square keeps its size; it opens back to the card's size.
            if shape.folded != nil { actions.removeAll { ($0 as? UIAction)?.title == "Redimensionar" } }
        }
        if case .shape(let shape) = block.content, shape.kind == .stickyNote {
            let current = StickyNoteColor(hex: shape.fill) ?? .yellow
            actions.insert(UIMenu(title: "Cor do post-it", image: UIImage(systemName: "paintpalette"), children: StickyNoteColor.allCases.map { color in
                UIAction(title: color.title, image: Self.swatch(color.hex), state: color == current ? .on : .off) { [weak self] _ in
                    guard let self, let changed = try? Stickers.settingColor(color, of: block) else { return }
                    self.configuration.onCommands([.replaceBlock(changed)])
                }
            }), at: 0)
        } else if case .shape(let shape) = block.content, shape.kind == .calendar {
            actions.insert(contentsOf: [
                UIAction(title: "Alterar data…", image: UIImage(systemName: "calendar")) { [weak self] _ in self?.pickDay(for: id) },
                UIAction(title: "Hoje", image: UIImage(systemName: "calendar.badge.clock")) { [weak self] _ in self?.setDay(Date(), for: id) },
            ], at: 0)
        } else if case .shape = block.content {
            actions.append(UIMenu(title: "Preenchimento", children: colors.map { name, color in
                UIAction(title: name, handler: update { if case .shape(var shape) = $0.content { shape.fill = color; $0.content = .shape(shape) } })
            }))
            actions.append(UIMenu(title: "Cor da borda", children: colors.map { name, color in
                UIAction(title: name, handler: update { if case .shape(var shape) = $0.content { shape.stroke = color; $0.content = .shape(shape) } })
            }))
        }
        switch block.content {
        case .image, .sticker:
            if croppingID == id {
                actions.append(UIAction(title: "Concluir recorte", image: UIImage(systemName: "checkmark")) { [weak self] _ in
                    self?.croppingID = nil; self?.render()
                })
            } else {
                actions.append(UIAction(title: "Recortar com alças", image: UIImage(systemName: "crop")) { [weak self] _ in
                    self?.croppingID = id; self?.selectedObjectID = id; self?.render()
                })
            }
            actions.append(UIAction(title: "Recorte exato (%)…") { [weak self] _ in self?.crop(block) })
            let masks: [(String, ShapeKind?)] = [("Original", nil), ("Círculo / elipse", .ellipse), ("Losango", .diamond), ("Triângulo", .triangle)]
            actions.append(UIMenu(title: "Formato da imagem", image: UIImage(systemName: "circle.dashed"), children: masks.map { name, kind in
                UIAction(title: name, state: block.effectivePresentation.imageMask == kind ? .on : .off,
                         handler: update { var p = $0.effectivePresentation; p.imageMask = kind; $0.presentation = p })
            }))
            actions.append(UIAction(title: "Restaurar recorte", handler: update { var p = $0.effectivePresentation; p.imageCrop = nil; $0.presentation = p }))
        default: break
        }
        actions.append(UIAction(title: "Excluir", attributes: .destructive) { [weak self] _ in self?.configuration.onCommands([.removeSubtree(id)]) })
        return UIMenu(children: actions)
    }

    /// A calendar sticker shows the day picked here (today when it was inserted).
    private func pickDay(for id: UUID) {
        guard let block = configuration.document.blocks.first(where: { $0.id == id }), case .shape(let shape) = block.content,
              shape.kind == .calendar, presentedViewController == nil else { return }
        let picker = DayPickerController(day: Stickers.day(from: shape.date) ?? Date()) { [weak self] day in self?.setDay(day, for: id) }
        let sheet = UINavigationController(rootViewController: picker)
        // On the iPhone a popover that adapted into a half-height sheet around the inline date
        // picker hung the app (reproduced in the iPhone simulator); there it is a plain full sheet.
        if traitCollection.horizontalSizeClass == .regular, let anchor = blockViews[id] {
            sheet.modalPresentationStyle = .popover
            sheet.preferredContentSize = CGSize(width: 340, height: 420)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = anchor; popover.sourceRect = anchor.bounds
                popover.permittedArrowDirections = [.up, .down, .left, .right]
                popover.delegate = self
            }
        } else {
            sheet.modalPresentationStyle = .pageSheet
            sheet.sheetPresentationController?.detents = [.large()]
        }
        present(sheet, animated: true)
    }
    public func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    private func setDay(_ day: Date, for id: UUID) {
        guard let block = configuration.document.blocks.first(where: { $0.id == id }),
              let changed = try? Stickers.settingDay(day, of: block), changed != block else { return }
        configuration.onCommands([.replaceBlock(changed)])
    }
    private static func swatch(_ hex: String) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
            UIColor(hex: hex).setFill(); UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 18, height: 18), cornerRadius: 4).fill()
            UIColor.black.withAlphaComponent(0.2).setStroke(); UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 18, height: 18), cornerRadius: 4).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    private func resize(_ block: CanvasBlock) {
        let alert = UIAlertController(title: "Tamanho em pontos", message: "A proporção pode ser ajustada pelos valores abaixo.", preferredStyle: .alert)
        for value in [block.layout.frame.width, block.layout.frame.height] {
            alert.addTextField { $0.text = String(format: "%.1f", value); $0.keyboardType = .decimalPad }
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Aplicar", style: .default) { [weak self, weak alert] _ in
            guard let fields = alert?.textFields, let width = Double(fields[0].text ?? ""), let height = Double(fields[1].text ?? ""), width > 0, height > 0 else { return }
            guard let self else { return }
            do { self.configuration.onCommands(try CanvasTransforms.resize(block.id, width: width, height: height, in: self.configuration.document)) }
            catch { self.configuration.onError(error) }
        })
        present(alert, animated: true)
    }

    private func crop(_ block: CanvasBlock) {
        let alert = UIAlertController(title: "Recorte (%)", message: "Esquerda, topo, largura e altura dentro da imagem original.", preferredStyle: .alert)
        let rect = block.effectivePresentation.imageCrop ?? .init(x: 0, y: 0, width: 1, height: 1)
        for value in [rect.x, rect.y, rect.width, rect.height] { alert.addTextField { $0.text = String(format: "%.0f", value * 100); $0.keyboardType = .decimalPad } }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Aplicar", style: .default) { [weak self, weak alert] _ in
            guard let values = alert?.textFields?.compactMap({ Double($0.text ?? "") }), values.count == 4 else { return }
            var changed = block, p = block.effectivePresentation
            p.imageCrop = .init(x: values[0] / 100, y: values[1] / 100, width: values[2] / 100, height: values[3] / 100)
            changed.presentation = p; self?.configuration.onCommands([.replaceBlock(changed)])
        })
        present(alert, animated: true)
    }
}

/// Date picker for a calendar sticker: the day under the finger is applied with "Concluir".
@MainActor
final class DayPickerController: UIViewController {
    private let picker = UIDatePicker()
    private let onPick: (Date) -> Void
    init(day: Date, onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .inline
        picker.locale = Locale(identifier: "pt_BR")
        picker.date = day
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Data do calendário"
        view.backgroundColor = .systemBackground
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Hoje", primaryAction: UIAction { [weak self] _ in self?.picker.setDate(Date(), animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.onPick(self.picker.date); self.dismiss(animated: true)
        })
    }
}

private extension ShapeKind {
    var title: String {
        switch self {
        case .rectangle: "Retângulo"; case .ellipse: "Elipse"; case .diamond: "Losango"
        case .triangle: "Triângulo"; case .line: "Linha"; case .arrow: "Seta"
        case .stickyNote: "Post-it"; case .calendar: "Calendário"; case .transcript: "Transcrição"
        }
    }
}

private extension TextWrapMode {
    static var allMenuCases: [TextWrapMode] { [.inherit, .bounds, .contour, .topAndBottom, .none] }
    var title: String { switch self { case .inherit: "Padrão da nota"; case .bounds: "Retangular"; case .contour: "Contorno"; case .topAndBottom: "Acima e abaixo"; case .none: "Sobrepor" } }
}

/// The bar above the keyboard: formatting buttons in a row that scrolls sideways (a finger drag
/// moves it), and "Concluir" fixed on the right, always reachable.
@MainActor final class KeyboardBar: UIInputView {
    private let scroll = UIScrollView()
    private let row = UIStackView()
    let doneButton = UIButton(type: .system)
    var done: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal; row.spacing = 2; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        var config = UIButton.Configuration.borderedProminent()
        config.title = "Concluir"; config.cornerStyle = .capsule
        doneButton.configuration = config
        doneButton.accessibilityLabel = "Concluir"
        doneButton.addAction(UIAction { [weak self] _ in self?.done?() }, for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let divider = UIView(); divider.backgroundColor = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        [scroll, divider, doneButton].forEach(addSubview)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -6),
            divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 24),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            doneButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(button)
        return button
    }

    func add(_ symbol: String, _ label: String, action: @escaping () -> Void) {
        button(symbol, label).addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    func add(menu: UIMenu, symbol: String, label: String) {
        let button = button(symbol, label)
        button.menu = menu; button.showsMenuAsPrimaryAction = true
    }

    /// Buttons in the scrolling row (tests).
    var items: [UIButton] { row.arrangedSubviews.compactMap { $0 as? UIButton } }
}
#endif
