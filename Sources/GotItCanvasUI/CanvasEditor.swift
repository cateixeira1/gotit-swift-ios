#if canImport(UIKit)
import SwiftUI
import UIKit
import GotItDomain
import GotItCanvas

public enum CanvasTool: String, CaseIterable { case select, draw }

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
    public var image: (String) -> UIImage?
    public var note: (UUID) -> NoteCardPresentation?
    public var onCommands: ([DocumentCommand]) -> Void
    public var onOpenNote: (UUID) -> Void
    public var onError: (Error) -> Void

    public init(document: CanvasDocument, tool: CanvasTool = .select,
                image: @escaping (String) -> UIImage? = { _ in nil },
                note: @escaping (UUID) -> NoteCardPresentation? = { _ in nil },
                onCommands: @escaping ([DocumentCommand]) -> Void,
                onOpenNote: @escaping (UUID) -> Void = { _ in }, onError: @escaping (Error) -> Void = { _ in }) {
        self.document = document; self.tool = tool; self.image = image; self.note = note
        self.onCommands = onCommands; self.onOpenNote = onOpenNote; self.onError = onError
    }
    public func makeUIViewController(context: Context) -> CanvasViewController { CanvasViewController(configuration: self) }
    public func updateUIViewController(_ controller: CanvasViewController, context: Context) { controller.configure(self) }
}

@MainActor
public final class CanvasViewController: UIViewController, UIScrollViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    private var configuration: CanvasEditor
    private let scroll = UIScrollView()
    private let surface = UIView()
    private let ink = StrokeInputView()
    private var blockViews: [UUID: UIView] = [:]
    private var textIDs: [ObjectIdentifier: UUID] = [:]
    private var connectionViews: [UIView] = []
    private var frames: [UUID: LogicalRect] = [:]
    private var connectingFrom: UUID?
    private var movingID: UUID?
    private var moveOrigin = CGPoint.zero

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
        ink.onStroke = { [weak self] points in
            guard let self else { return }
            do { self.configuration.onCommands(try DiagramCommands.insertStroke(points, in: self.configuration.document)) }
            catch { self.configuration.onError(error) }
        }
        surface.addSubview(ink)
        render()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds
    }
    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
    public func scrollViewDidZoom(_ scrollView: UIScrollView) { updateVisibility() }
    public func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisibility() }

    func configure(_ value: CanvasEditor) {
        configuration = value
        if isViewLoaded { render() }
    }

    private func render() {
        do { frames = try CanvasLayoutEngine.frames(in: configuration.document) }
        catch { configuration.onError(error); return }
        let page = configuration.document.canvas.size
        let size = CGSize(width: page.width, height: page.height)
        surface.bounds = CGRect(origin: .zero, size: size)
        surface.frame.size = CGSize(width: size.width * scroll.zoomScale, height: size.height * scroll.zoomScale)
        scroll.contentSize = surface.frame.size
        let ids = Set(configuration.document.blocks.map(\.id))
        for id in Array(blockViews.keys) where !ids.contains(id) {
            if let view = blockViews.removeValue(forKey: id) { textIDs.removeValue(forKey: ObjectIdentifier(view)); view.removeFromSuperview() }
        }
        for block in configuration.document.blocks.sorted(by: { $0.layout.zIndex < $1.layout.zIndex }) {
            guard let logical = frames[block.id] else { continue }
            let blockView: UIView
            if case .text(let richText) = block.content {
                let isNew = blockViews[block.id] == nil
                let textView = (blockViews[block.id] as? UITextView) ?? makeTextView(id: block.id)
                if richText.plainText.isEmpty, !textView.isFirstResponder {
                    let style = (try? configuration.document.resolvedStyle(for: block.id)) ?? .init()
                    textView.typingAttributes = [.font: UIFont.systemFont(ofSize: style.fontSize ?? 18), .foregroundColor: UIColor(hex: style.foreground ?? "#111827")]
                }
                if !textView.isFirstResponder { textView.attributedText = TextBridge.attributed(richText, base: (try? configuration.document.resolvedStyle(for: block.id)) ?? .init()) }
                textView.textContainer.exclusionPaths = ((try? TextFlowEngine.exclusions(for: block.id, in: configuration.document)) ?? []).map {
                    let path = UIBezierPath()
                    for (index, point) in $0.polygon.enumerated() {
                        let cg = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
                        if index == 0 { path.move(to: cg) } else { path.addLine(to: cg) }
                    }
                    path.close(); return path
                }
                blockView = textView
                if isNew, richText.plainText.isEmpty, configuration.tool == .select {
                    Task { @MainActor [weak textView] in textView?.becomeFirstResponder() }
                }
            } else {
                let object = (blockViews[block.id] as? CanvasObjectView) ?? makeObjectView(id: block.id)
                object.block = block
                object.asset = block.content.assetHash.flatMap(configuration.image)
                if case .noteReference(let ref) = block.content { object.note = configuration.note(ref.documentID) }
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
        ink.isUserInteractionEnabled = configuration.tool == .draw
        ink.isHidden = configuration.tool != .draw
        surface.bringSubviewToFront(ink)
        updateVisibility()
    }

    private func updateVisibility() {
        guard isViewLoaded, scroll.zoomScale > 0 else { return }
        let visible = scroll.convert(scroll.bounds, to: surface).insetBy(dx: -80, dy: -80)
        for item in blockViews.values { item.isHidden = !item.frame.intersects(visible) && !item.isFirstResponder }
    }

    private func makeTextView(id: UUID) -> UITextView {
        let text = UITextView(usingTextLayoutManager: true)
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

    public func textViewDidChange(_ textView: UITextView) {
        guard let id = textIDs[ObjectIdentifier(textView)], var block = configuration.document.blocks.first(where: { $0.id == id }) else { return }
        block.content = .text(TextBridge.richText(textView.attributedText))
        configuration.onCommands([.replaceBlock(block)])
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
        return UIMenu(children: [
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
        let object = CanvasObjectView()
        object.id = id
        object.onMenu = { [weak self] in self?.objectMenu(id) ?? UIMenu(children: []) }
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
        if let source = connectingFrom {
            connectingFrom = nil
            if source != id { configuration.onCommands([.setRelation(.init(sourceID: source, targetID: id, kind: .connector, style: .init()))]) }
        } else if case .noteReference(let ref) = object.block?.content { configuration.onOpenNote(ref.documentID) }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        configuration.tool == .select && touch.view === surface
    }
    @objc private func tapCanvas(_ gesture: UITapGestureRecognizer) { insertText(at: gesture.location(in: surface)) }

    private func insertText(at point: CGPoint) {
        let size = configuration.document.canvas.size
        let frame = LogicalRect(x: point.x, y: point.y, width: max(80, size.width - point.x - 24), height: max(80, size.height - point.y - 24))
        configuration.onCommands([.insertBlock(.init(order: nextOrder, layout: .init(mode: .absolute, frame: frame), content: .text(RichText(""))))])
    }
    private var nextOrder: Int { (configuration.document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1 }

    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [UIAction(title: "Texto") { _ in self.insertText(at: location) }] +
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
            actions.append(UIAction(title: "Recortar imagem…") { [weak self] _ in self?.crop(block) })
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
