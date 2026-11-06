#if canImport(UIKit)
import SwiftUI
import UIKit
import PencilKit
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
    public var onDrawing: (Data, [DocumentCommand]) -> Void
    public var image: (String) -> UIImage?
    public var note: (UUID) -> NoteCardPresentation?
    public var onTextCommands: ((CanvasBlock, String?, NSRange) -> TextFlowFocus?)?
    public var onCommands: ([DocumentCommand]) -> Void
    public var onOpenPDF: (UUID) -> Void
    public var onOpenNote: (UUID) -> Void
    public var onError: (Error) -> Void

    @MainActor public init(document: CanvasDocument, tool: CanvasTool = .select, session: EditorSession? = nil,
                inkColor: UIColor = .black, inkWidth: CGFloat = 3, vectorEraser: Bool = false,
                drawingData: @escaping (String) -> Data? = { _ in nil },
                onDrawing: @escaping (Data, [DocumentCommand]) -> Void = { _, _ in },
                image: @escaping (String) -> UIImage? = { _ in nil },
                note: @escaping (UUID) -> NoteCardPresentation? = { _ in nil },
                onTextCommands: ((CanvasBlock, String?, NSRange) -> TextFlowFocus?)? = nil,
                onCommands: @escaping ([DocumentCommand]) -> Void,
                onOpenPDF: @escaping (UUID) -> Void = { _ in },
                onOpenNote: @escaping (UUID) -> Void = { _ in }, onError: @escaping (Error) -> Void = { _ in }) {
        self.session = session; self.inkColor = inkColor; self.inkWidth = inkWidth; self.vectorEraser = vectorEraser
        self.drawingData = drawingData; self.onDrawing = onDrawing
        self.onOpenPDF = onOpenPDF
        self.onTextCommands = onTextCommands
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
    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0, markedTextRange == nil,
           backspaceAtStart?() == true { return }
        super.deleteBackward()
    }
}

@MainActor
public final class CanvasViewController: UIViewController, UIScrollViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, PKCanvasViewDelegate {
    private var configuration: CanvasEditor
    private let scroll = UIScrollView()
    private let surface = UIView()
    private let ink = PKCanvasView()
    private let ruler = PageRuler()
    private weak var activeText: UITextView?
    private var applyingDrawing = false
    private var usingTool = false
    private var lastDrawingData = PKDrawing().dataRepresentation()
    private var strokesAtStart = 0
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

    init(configuration: CanvasEditor) { self.configuration = configuration; super.init(nibName: nil, bundle: nil) }
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
        bindSession()
        surface.addSubview(ink)
        render()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
        let visible = scroll.convert(scroll.bounds, to: surface).insetBy(dx: -80, dy: -80)
        let ids = Set(configuration.document.blocks.compactMap { block -> UUID? in
            guard let frame = frames[block.id] else { return nil }
            let bounds = CanvasLayoutEngine.rotatedBounds(frame, radians: block.effectivePresentation.rotationRadians)
            let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
            return rect.intersects(visible) || blockViews[block.id]?.isFirstResponder == true || movingID == block.id || selectedObjectID == block.id || configuration.session?.pendingFocus?.blockID == block.id ? block.id : nil
        })
        for id in Array(blockViews.keys) where !ids.contains(id) {
            recycle(id)
        }
        for block in configuration.document.blocks.sorted(by: { $0.layout.zIndex < $1.layout.zIndex }) {
            if case .drawing = block.content { continue }
            guard ids.contains(block.id), let logical = frames[block.id] else { continue }
            let blockView: UIView
            if case .text(let richText) = block.content {
                let isNew = blockViews[block.id] == nil
                let textView = (blockViews[block.id] as? UITextView) ?? makeTextView(id: block.id)
                if richText.plainText.isEmpty, !textView.isFirstResponder {
                    let style = (try? configuration.document.resolvedStyle(for: block.id)) ?? .init()
                    textView.typingAttributes = [.font: UIFont.systemFont(ofSize: style.fontSize ?? 18), .foregroundColor: UIColor(hex: style.foreground ?? "#111827")]
                }
                let rendered = TextBridge.attributed(richText, base: (try? configuration.document.resolvedStyle(for: block.id)) ?? .init())
                if textView.markedTextRange == nil, !rendered.isEqual(to: textView.attributedText ?? NSAttributedString(string: "")) {
                    let selection = textView.selectedRange
                    textView.attributedText = rendered
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
                if let focus = configuration.session?.pendingFocus, focus.blockID == block.id {
                    configuration.session?.pendingFocus = nil
                    Task { @MainActor [weak textView] in
                        textView?.becomeFirstResponder(); textView?.selectedRange = focus.range
                    }
                }
                if isNew, richText.plainText.isEmpty, configuration.tool == .select, pendingFocusID == block.id {
                    Task { @MainActor [weak textView] in textView?.becomeFirstResponder() }
                }
            } else {
                let object = (blockViews[block.id] as? CanvasObjectView) ?? makeObjectView(id: block.id)
                object.block = block
                object.asset = block.content.assetHash.flatMap(configuration.image)
                if case .noteReference(let ref) = block.content { object.note = configuration.note(ref.documentID) }
                if case .sticker = block.content {
                    object.layer.shadowColor = UIColor.black.cgColor; object.layer.shadowOpacity = 0.24
                    object.layer.shadowOffset = CGSize(width: 0, height: 4); object.layer.shadowRadius = 5
                } else { object.layer.shadowOpacity = 0 }
                object.setNeedsDisplay()
                blockView = object
            }
            if let previous = blockViews[block.id], previous !== blockView { previous.removeFromSuperview() }
            blockViews[block.id] = blockView
            blockView.transform = .identity
            blockView.frame = CGRect(x: logical.x, y: logical.y, width: logical.width, height: logical.height)
            blockView.transform = CGAffineTransform(rotationAngle: block.effectivePresentation.rotationRadians)
            if blockView.superview == nil { surface.addSubview(blockView) }
            surface.bringSubviewToFront(blockView)
        }
        // Containers and shape parents remain behind their editable children.
        for block in configuration.document.blocks where block.parentID != nil {
            if let child = blockViews[block.id] { surface.bringSubviewToFront(child) }
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
            surface.addSubview(connection); connectionViews.append(connection)
        }
        ink.frame = surface.bounds
        ink.contentSize = surface.bounds.size
        ink.isUserInteractionEnabled = configuration.tool.isDrawing
        let signature = "\(configuration.tool)-\(configuration.inkColor.hex)-\(configuration.inkWidth)-\(configuration.vectorEraser)"
        if signature != inkToolSignature {
            ink.tool = configuration.tool.nativeTool(color: configuration.inkColor, width: configuration.inkWidth, vectorEraser: configuration.vectorEraser)
            inkToolSignature = signature
        }
        scroll.panGestureRecognizer.minimumNumberOfTouches = configuration.tool.isDrawing ? 2 : 1
        if configuration.tool.isDrawing { activeText?.resignFirstResponder() }
        loadDrawing()
        ink.accessibilityValue = "\(ink.drawing.strokes.count) traços"
        surface.bringSubviewToFront(ink)
        selectionOverlay?.removeFromSuperview(); selectionOverlay = nil
        if configuration.tool == .select, let id = selectedObjectID, let object = blockViews[id],
           let block = configuration.document.blocks.first(where: { $0.id == id }) {
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
                let width = max(24, rect.width + (left ? -dx : dx))
                let height = max(24, rect.height + (top ? -dy : dy))
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
                }
            }
            surface.addSubview(handles); selectionOverlay = handles
            }
        }
        updateRuler()
    }

    private func bindSession() {
        configuration.session?.handler = { [weak self] action in self?.perform(action) }
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
        case .insertTable: insertTable(at: CGPoint(x: 24, y: max(24, scroll.contentOffset.y / scroll.zoomScale + 24))); return
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
        let hash = configuration.document.blocks.compactMap { block -> String? in
            if case .drawing(let ref) = block.content { return ref.hash }; return nil
        }.first
        guard hash != loadedDrawingHash else { return }
        do {
            let data: Data
            if let hash {
                guard let bytes = configuration.drawingData(hash) else { throw DocumentError.invalid("Desenho indisponível") }
                data = bytes
            } else { data = PKDrawing().dataRepresentation() }
            let drawing = try PKDrawing(data: data)
            applyingDrawing = true; ink.drawing = drawing; applyingDrawing = false
            loadedDrawingHash = hash; lastDrawingData = data
        } catch { configuration.onError(error) }
    }

    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        usingTool = true; strokesAtStart = canvasView.drawing.strokes.count
    }
    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        usingTool = false
        // PencilKit can deliver the final drawing change after the tool-end callback.
        Task { @MainActor [weak self] in await Task.yield(); self?.saveDrawing() }
    }
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applyingDrawing, !usingTool else { return }
        Task { @MainActor [weak self] in await Task.yield(); self?.saveDrawing() }
    }
    private func saveDrawing() {
        guard !usingTool, !applyingDrawing else { return }
        var drawing = ink.drawing
        guard drawing.dataRepresentation() != lastDrawingData else { return }
        var commands: [DocumentCommand] = []
        if configuration.tool != .eraser, configuration.document.canvas.recognizeDiagrams,
           drawing.strokes.count == strokesAtStart + 1, let stroke = drawing.strokes.last {
            let points = stroke.path.map { point -> CanvasPoint in
                let location = point.location.applying(stroke.transform)
                return .init(x: location.x, y: location.y)
            }
            if DiagramRecognizer.recognize(points) != nil {
                do {
                    commands = try DiagramCommands.insertStroke(points, in: configuration.document).map { command in
                        if case .insertBlock(var block) = command, case .shape(var shape) = block.content {
                            shape.stroke = configuration.inkColor.hex; shape.lineWidth = configuration.inkWidth
                            block.content = .shape(shape); return .insertBlock(block)
                        }
                        if case .setRelation(var relation) = command {
                            relation.style = .init(color: configuration.inkColor.hex, width: configuration.inkWidth)
                            return .setRelation(relation)
                        }
                        return command
                    }
                    drawing = PKDrawing(strokes: Array(drawing.strokes.dropLast()))
                    applyingDrawing = true; ink.drawing = drawing; applyingDrawing = false
                } catch { configuration.onError(error); return }
            }
        }
        let bytes = drawing.dataRepresentation()
        ink.accessibilityValue = "\(drawing.strokes.count) traços"
        lastDrawingData = bytes
        configuration.onDrawing(bytes, commands)
    }

    /// Views outside the overscan are detached and reset. Focus/IME and active drags stay pinned.
    private func recycle(_ id: UUID) {
        guard let view = blockViews.removeValue(forKey: id) else { return }
        view.removeFromSuperview(); view.transform = .identity
        textIDs.removeValue(forKey: ObjectIdentifier(view))
        if let text = view as? UITextView {
            text.attributedText = nil; text.textContainer.exclusionPaths = []; text.typingAttributes = [:]
            text.undoManager?.removeAllActions()
            if textPool.count < 12 { textPool.append(text) }
        } else if let object = view as? CanvasObjectView {
            object.id = nil; object.block = nil; object.asset = nil; object.note = nil; object.onMenu = nil
            object.layer.shadowOpacity = 0
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
        text.delegate = self; text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        text.isScrollEnabled = true
        text.isFindInteractionEnabled = true
        text.adjustsFontForContentSizeCategory = true
        text.accessibilityLabel = "Bloco de texto"
        textIDs[ObjectIdentifier(text)] = id
        let bar = UIToolbar()
        bar.items = [
            UIBarButtonItem(title: "B", primaryAction: UIAction { [weak self, weak text] _ in if let text { text.toggleBoldface(nil); self?.textViewDidChange(text) } }),
            UIBarButtonItem(title: "I", primaryAction: UIAction { [weak self, weak text] _ in if let text { text.toggleItalics(nil); self?.textViewDidChange(text) } }),
            UIBarButtonItem(title: "U", primaryAction: UIAction { [weak self, weak text] _ in if let text { self?.format(text, key: .underlineStyle, value: NSUnderlineStyle.single.rawValue) } }),
            UIBarButtonItem(title: "A+", primaryAction: UIAction { [weak self, weak text] _ in if let text { self?.resizeFont(text, delta: 2) } }),
            UIBarButtonItem(title: "A−", primaryAction: UIAction { [weak self, weak text] _ in if let text { self?.resizeFont(text, delta: -2) } }),
            UIBarButtonItem(title: "Cor", primaryAction: UIAction { [weak self, weak text] _ in if let text { self?.format(text, key: .foregroundColor, value: UIColor.systemBlue) } }),
            UIBarButtonItem(title: "Mais", menu: textMenu(text)),
            UIBarButtonItem(title: "Concluir", primaryAction: UIAction { [weak text] _ in text?.resignFirstResponder() })
        ]
        bar.sizeToFit(); text.inputAccessoryView = bar
        return text
    }

    /// Joins a continuation fragment to the previous one: the character before the story break
    /// is deleted, the text reflows, and the caret lands where that character was.
    private func backspaceAcrossFragments(_ textView: UITextView?) -> Bool {
        guard let textView, let id = textIDs[ObjectIdentifier(textView)],
              let onTextCommands = configuration.onTextCommands,
              let merge = configuration.document.backspaceAcrossFragments(at: id) else { return false }
        typingGroup = UUID().uuidString; typingBlock = nil; typingCaret = nil; pendingTyping = false
        guard let focus = onTextCommands(merge.replacement, typingGroup, NSRange(location: merge.caret, length: 0)) else { return true }
        configuration.session?.pendingFocus = focus
        return true
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        activeText = textView; configuration.session?.hasTextSelection = true
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if textView === cellEditor { return true }
        let now = Date(), id = textIDs[ObjectIdentifier(textView)]
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
        if textView === cellEditor {
            if activeText === textView { activeText = nil; configuration.session?.hasTextSelection = false }
            commitCell(); return
        }
        if activeText === textView { activeText = nil; configuration.session?.hasTextSelection = false }
        typingGroup = nil; typingBlock = nil; typingCaret = nil; pendingTyping = false
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard let id = textIDs[ObjectIdentifier(textView)], var block = configuration.document.blocks.first(where: { $0.id == id }) else { return }
        block.content = .text(TextBridge.richText(textView.attributedText))
        let group = pendingTyping ? typingGroup : nil
        pendingTyping = false
        guard textView.markedTextRange == nil else { return } // Do not split an IME composition.
        if let onTextCommands = configuration.onTextCommands {
            if let focus = onTextCommands(block, group, textView.selectedRange) {
                if focus.blockID == id {
                    textView.attributedText = TextBridge.attributed(focus.text, base: (try? configuration.document.resolvedStyle(for: id)) ?? .init())
                    textView.selectedRange = focus.range
                } else { configuration.session?.pendingFocus = focus }
            }
        }
        else { configuration.onCommands([.replaceBlock(block)]) }
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

    @objc private func moveObject(_ gesture: UIPanGestureRecognizer) {
        guard let object = gesture.view as? CanvasObjectView, let id = object.id,
              var block = configuration.document.blocks.first(where: { $0.id == id }) else { return }
        if gesture.state == .began { movingID = id; moveOrigin = object.center }
        let delta = gesture.translation(in: surface)
        if gesture.state == .changed { object.center = CGPoint(x: moveOrigin.x + delta.x, y: moveOrigin.y + delta.y) }
        if gesture.state == .ended {
            if block.layout.mode == .flow, let world = frames[id] {
                let parent = block.parentID.flatMap { frames[$0] }
                block.layout.frame.x = world.x - (parent?.x ?? 0)
                block.layout.frame.y = world.y - (parent?.y ?? 0)
                block.layout.mode = .absolute
            }
            block.layout.frame.x += delta.x; block.layout.frame.y += delta.y
            configuration.onCommands([.replaceBlock(block)]); movingID = nil
        } else if gesture.state == .cancelled { movingID = nil; render() }
    }

    @objc private func selectObject(_ gesture: UITapGestureRecognizer) {
        guard let object = gesture.view as? CanvasObjectView, let id = object.id else { return }
        if croppingID != id { croppingID = nil }
        let wasSelected = selectedObjectID == id
        selectedObjectID = id
        render()
        if wasSelected, connectingFrom == nil, case .table = object.block?.content {
            beginEditingCell(object, at: gesture.location(in: object)); return
        }
        if let source = connectingFrom {
            connectingFrom = nil
            if source != id { configuration.onCommands([.setRelation(.init(sourceID: source, targetID: id, kind: .connector, style: .init()))]) }
        } else if case .pdf = object.block?.content { configuration.onOpenPDF(id) }
        else if case .noteReference(let ref) = object.block?.content { configuration.onOpenNote(ref.documentID) }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        configuration.tool == .select && touch.view === surface
    }
    @objc private func tapCanvas(_ gesture: UITapGestureRecognizer) { insertText(at: gesture.location(in: surface)) }

    private func insertText(at point: CGPoint) {
        let size = configuration.document.canvas.size
        let frame = LogicalRect(x: point.x, y: point.y, width: max(80, size.width - point.x - 24), height: max(80, size.height - point.y - 24))
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
        commitCell()
        let rect = table.frame(row: hit.row, column: hit.column)
        let editor = UITextView(usingTextLayoutManager: true)
        editor.delegate = self
        editor.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.97)
        editor.layer.borderColor = UIColor.systemBlue.cgColor; editor.layer.borderWidth = 2
        editor.textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        editor.accessibilityIdentifier = "tableCellEditor"
        let base = TableRendering.base(header: table.headerRow && hit.row == 0)
        editor.attributedText = TextBridge.attributed(table.cells[hit.row][hit.column].text, base: base)
        editor.typingAttributes = TextBridge.attributed(RichText(" "), base: base).attributes(at: 0, effectiveRange: nil)
        editor.bounds = CGRect(x: 0, y: 0, width: rect.width * sx, height: max(rect.height * sy, 36))
        editor.center = object.convert(CGPoint(x: (rect.x + rect.width / 2) * sx, y: (rect.y + rect.height / 2) * sy), to: surface)
        editor.transform = object.transform
        surface.addSubview(editor)
        cellEditor = editor; editingCell = (id, hit.row, hit.column)
        editor.becomeFirstResponder()
    }

    /// Saves the open cell (if it changed) and grows its row to fit; one undo step per cell edit.
    private func commitCell() {
        guard let editor = cellEditor, let cell = editingCell else { return }
        cellEditor = nil; editingCell = nil
        let text = TextBridge.richText(editor.attributedText ?? NSAttributedString())
        let needed = editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height
        editor.delegate = nil; editor.removeFromSuperview()
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
        return [UIMenu(title: "Tabela (linha \(cell.row + 1), coluna \(cell.column + 1))", image: UIImage(systemName: "tablecells"), children: [
            UIAction(title: "Editar célula", image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let self, let object = self.blockViews[block.id] as? CanvasObjectView else { return }
                let f = table.frame(row: cell.row, column: cell.column)
                let sx = object.bounds.width / max(1, table.width), sy = object.bounds.height / max(1, table.height)
                self.beginEditingCell(object, at: CGPoint(x: (f.x + f.width / 2) * sx, y: (f.y + f.height / 2) * sy))
            },
            edit("Inserir linha acima", "arrow.up.to.line") { try $0.insertingRow(at: cell.row) },
            edit("Inserir linha abaixo", "arrow.down.to.line") { try $0.insertingRow(at: cell.row + 1) },
            edit("Inserir coluna à esquerda", "arrow.left.to.line") { try $0.insertingColumn(at: cell.column) },
            edit("Inserir coluna à direita", "arrow.right.to.line") { try $0.insertingColumn(at: cell.column + 1) },
            edit(table.headerRow ? "Remover cabeçalho" : "Primeira linha como cabeçalho", "rectangle.topthird.inset.filled") { var t = $0; t.headerRow.toggle(); return t },
            UIMenu(title: "Cor da célula", children: colors.map { name, color in
                edit(name) { var t = $0; t.cells[cell.row][cell.column].background = color; return t }
            }),
            UIMenu(title: "Bordas", children: [("Sem borda", 0.0), ("Fina", 1.0), ("Média", 2.0)].map { name, width in
                edit(name) { var t = $0; t.borderWidth = width; return t }
            }),
            edit("Excluir linha", "minus.square", destructive: true) { try $0.removingRow(at: cell.row) },
            edit("Excluir coluna", "minus.square", destructive: true) { try $0.removingColumn(at: cell.column) },
        ])]
    }

    private var nextOrder: Int { (configuration.document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1 }

    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [UIAction(title: "Texto") { _ in self.insertText(at: location) },
                                     UIAction(title: "Tabela", image: UIImage(systemName: "tablecells")) { _ in self.insertTable(at: location) }] +
                [ShapeKind.rectangle, .ellipse, .diamond, .triangle].map { kind in
                    UIAction(title: kind.rawValue) { _ in
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
            UIAction(title: "Conectar a outro bloco") { [weak self] _ in self?.connectingFrom = id },
            UIAction(title: "Redimensionar") { [weak self] _ in self?.resize(block) },
            UIAction(title: "Girar 90°", handler: update { var p = $0.effectivePresentation; p.rotationRadians += .pi / 2; $0.presentation = p }),
            UIMenu(title: "Contorno do texto", children: TextWrapMode.allMenuCases.map { mode in
                UIAction(title: mode.title, handler: update { var p = $0.effectivePresentation; p.wrap = mode; $0.presentation = p })
            })
        ]
        if case .pdf = block.content { actions.insert(UIAction(title: "Abrir PDF") { [weak self] _ in self?.configuration.onOpenPDF(id) }, at: 0) }
        if case .table(let table) = block.content { actions.insert(contentsOf: tableMenu(block, table), at: 0) }
        if case .shape = block.content {
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

private extension TextWrapMode {
    static var allMenuCases: [TextWrapMode] { [.inherit, .bounds, .contour, .topAndBottom, .none] }
    var title: String { switch self { case .inherit: "Padrão da nota"; case .bounds: "Retangular"; case .contour: "Contorno"; case .topAndBottom: "Acima e abaixo"; case .none: "Sobrepor" } }
}
#endif
