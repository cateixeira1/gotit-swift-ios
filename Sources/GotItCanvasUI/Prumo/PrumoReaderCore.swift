#if canImport(UIKit)
// Extracted from Prumo PDF 5334bbaa274fe4a28c7e3d74b4382922d06804f6.
// Adaptations: semantic colors, no app catalog/summary dependencies.
import PDFKit
import SwiftUI
import UIKit

/// Estado do leitor (modo Original): página, busca, seleção de texto, marca-texto e destaques.
@MainActor
final class ReaderModel: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    weak var pdfView: PDFView?
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0
    @Published var searched = false
    @Published var hasSelection = false
    @Published var hasMarksInSelection = false
    /// Marca-texto ligado: um dedo destaca, dois dedos rolam (como a Marcação da Apple).
    @Published private(set) var marking = false
    @Published var color: HighlightColor = HighlightColor(rawValue: UserDefaults.standard.string(forKey: "readerColor") ?? "") ?? .yellow {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "readerColor") }
    }
    /// Destaque tocado (para apagar ou mudar a cor).
    @Published var tappedMark: PDFAnnotation?
    /// Qual PDF está aberto (para o desfazer saber onde aplicar).
    var docID = ""
    /// Destaque feito, apagado ou recolorido (para o desfazer e para gravar).
    var onEdit: ((String, ReaderHistory.Change) -> Void)?
    private var markPan: UIPanGestureRecognizer?
    private var markStart: (PDFPage, CGPoint)?
    private var markSelection: PDFSelection?

    func attach(_ view: PDFView) {
        pdfView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMark(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        markPan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UITapGestureRecognizer
    }

    func pageChanged() {
        guard let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        let n = doc.index(for: page) + 1
        if n != currentPage { currentPage = n }
        if doc.pageCount != pageCount { pageCount = doc.pageCount }
    }

    func selectionRanges() -> [(page: Int, range: NSRange)] {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection else { return [] }
        return Highlights.ranges(of: sel, in: doc)
    }

    func selectionChanged() {
        let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasSelection = !text.isEmpty && !marking
        if hasSelection, let doc = pdfView?.document {
            hasMarksInSelection = Highlights.hasMarks(selectionRanges(), in: doc)
        } else {
            hasMarksInSelection = false
        }
    }

    // MARK: Busca

    func search(_ text: String) {
        guard let doc = pdfView?.document else { return }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearSearch(); return }
        results = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searched = true
        resultIndex = 0
        pdfView?.highlightedSelections = results
        show()
    }

    func next() {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + 1) % results.count
        show()
    }

    func previous() {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex - 1 + results.count) % results.count
        show()
    }

    func clearSearch() {
        results = []
        searched = false
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
    }

    func go(toPage n: Int) {
        guard let doc = pdfView?.document, n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { return }
        pdfView?.go(to: page)
    }

    private func show() {
        guard results.indices.contains(resultIndex) else { return }
        let sel = results[resultIndex]
        pdfView?.setCurrentSelection(sel, animate: true)
        pdfView?.go(to: sel)
    }

    // MARK: Marca-texto

    private var scrollView: UIScrollView? {
        guard let view = pdfView else { return nil }
        if let s = view.subviews.compactMap({ $0 as? UIScrollView }).first { return s }
        for sub in view.subviews {
            if let s = sub.subviews.compactMap({ $0 as? UIScrollView }).first { return s }
        }
        return nil
    }

    func setMarking(_ on: Bool) {
        marking = on
        markPan?.isEnabled = on
        // Com o marca-texto ligado, a página rola com dois dedos.
        scrollView?.panGestureRecognizer.minimumNumberOfTouches = on ? 2 : 1
        if on { pdfView?.clearSelection() }
        selectionChanged()
    }

    @objc private func handleMark(_ g: UIPanGestureRecognizer) {
        guard let view = pdfView, let doc = view.document else { return }
        let p = g.location(in: view)
        guard let page = view.page(for: p, nearest: true) else { return }
        let pp = view.convert(p, to: page)
        switch g.state {
        case .began:
            markStart = (page, pp)
        case .changed:
            guard let start = markStart else { return }
            let sel = doc.selection(from: start.0, at: start.1, to: page, at: pp)
            sel?.color = color.uiColor.withAlphaComponent(0.55)
            markSelection = sel
            view.highlightedSelections = sel.map { [$0] }
        case .ended:
            if let sel = markSelection,
               !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                apply(sel, color: color)
            }
            fallthrough
        default:
            markStart = nil
            markSelection = nil
            view.highlightedSelections = results.isEmpty ? nil : results
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let view = pdfView else { return }
        let p = g.location(in: view)
        guard let page = view.page(for: p, nearest: false) else { return }
        if let mark = Highlights.highlight(at: view.convert(p, to: page), on: page) {
            tappedMark = mark
        }
    }

    private func apply(_ selection: PDFSelection, color c: HighlightColor) {
        guard let doc = pdfView?.document else { return }
        let added = Highlights.add(selection, color: c, in: doc)
        guard !added.isEmpty else { return }
        let pairs = added.compactMap { a in a.page.map { (doc.index(for: $0), a) } }
        onEdit?("Destaque", .marks(docID: docID, removed: [], added: pairs))
    }

    /// Destaca o texto selecionado (sem o marca-texto).
    func highlightSelection(_ c: HighlightColor) {
        guard let sel = pdfView?.currentSelection else { return }
        color = c
        apply(sel, color: c)
        pdfView?.clearSelection()
        selectionChanged()
    }

    /// Tira o destaque só do texto selecionado (o resto de cada destaque continua).
    func unmarkSelection() {
        guard let doc = pdfView?.document else { return }
        let change = Highlights.unmark(selectionRanges(), in: doc)
        guard !change.removed.isEmpty else { return }
        onEdit?("Desfazer destaque", .marks(docID: docID, removed: change.removed, added: change.added))
        pdfView?.clearSelection()
        selectionChanged()
    }

    func removeMark(_ a: PDFAnnotation) {
        guard let doc = pdfView?.document, let page = a.page else { return }
        let p = doc.index(for: page)
        Highlights.remove(a)
        onEdit?("Apagar destaque", .marks(docID: docID, removed: [(p, a)], added: []))
    }

    func recolorMark(_ a: PDFAnnotation, _ c: HighlightColor) {
        guard let doc = pdfView?.document, let page = a.page else { return }
        let from = a.color
        Highlights.recolor(a, c)
        onEdit?("Cor do destaque", .recolor(docID: docID, page: doc.index(for: page), mark: a, from: from, to: c.uiColor))
    }

    func copySelection() -> Bool {
        guard let t = pdfView?.currentSelection?.string, !t.isEmpty else { return false }
        UIPasteboard.general.string = t
        return true
    }

    /// A seleção como trecho para o resumo: páginas e texto corrido.
    func excerpt() -> (pages: [Int], text: String)? {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection else { return nil }
        let text = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pages = sel.pages.map { doc.index(for: $0) + 1 }.sorted()
        return (pages, text)
    }

    func clearSelection() {
        pdfView?.clearSelection()
        selectionChanged()
    }

    /// Só para a captura de tela: um trecho selecionado, com parte dele já destacada.
    func demoSelection() {
        guard let view = pdfView, let doc = view.document,
              let phrase = doc.findString("febre persistente, dor abdominal intensa", withOptions: [.caseInsensitive]).first,
              let word = doc.findString("febre persistente", withOptions: [.caseInsensitive]).first else { return }
        Highlights.add(word, color: .yellow, in: doc)
        view.setCurrentSelection(phrase, animate: false)
        selectionChanged()
    }
}

/// O PDFView e, à esquerda, a coluna de miniaturas (que aparece e some pela barra de baixo).
final class ReaderContainerView: UIView {
    let pdfView = PDFView()
    let thumbs = PDFThumbnailView()
    private var leading: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    static let thumbsWidth: CGFloat = 92
    /// Depois da primeira medida, a primeira página começa no alto (sem cortar o cabeçalho).
    var needsInitialPosition = true
    private var lastWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        thumbs.layoutMode = .vertical
        thumbs.thumbnailSize = CGSize(width: 64, height: 86)
        thumbs.backgroundColor = UIColor.secondarySystemBackground
        thumbs.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 60, right: 0)
        addSubview(pdfView)
        addSubview(thumbs)
        widthConstraint = thumbs.widthAnchor.constraint(equalToConstant: Self.thumbsWidth)
        leading = pdfView.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            leading,
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        thumbs.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = pdfView.bounds.width
        guard w > 0, pdfView.document != nil else { return }
        if abs(w - lastWidth) > 0.5 {
            lastWidth = w
            // zoom: de "página inteira na largura" até 5x; sem encolher além da largura
            let fit = pdfView.scaleFactorForSizeToFit
            if fit > 0 {
                pdfView.minScaleFactor = fit
                pdfView.maxScaleFactor = max(fit * 5, 4)
                if pdfView.scaleFactor < fit { pdfView.scaleFactor = fit }
            }
        }
        if needsInitialPosition {
            needsInitialPosition = false
            DispatchQueue.main.async { [weak self] in
                guard let view = self?.pdfView, let page = view.document?.page(at: 0) else { return }
                let b = page.bounds(for: view.displayBox)
                view.go(to: CGRect(x: b.minX, y: b.maxY - 1, width: 1, height: 1), on: page)
            }
        }
    }

    func showThumbnails(_ on: Bool) {
        guard thumbs.isHidden == on else { return }
        thumbs.isHidden = !on
        leading.constant = on ? Self.thumbsWidth : 0
        UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    let model: ReaderModel
    var password: String? = nil
    var showThumbnails = false
    /// Muda quando o arquivo foi alterado por outra ferramenta: o documento é lido de novo.
    var reloadToken = 0

    func makeUIView(context: Context) -> ReaderContainerView {
        let container = ReaderContainerView()
        let view = container.pdfView
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor.systemBackground
        view.document = Self.load(url, password: password)
        container.thumbs.pdfView = view
        model.attach(view)
        context.coordinator.token = reloadToken
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged),
                                               name: .PDFViewSelectionChanged, object: view)
        Task { @MainActor in model.pageChanged() }
        return container
    }

    /// Lê o PDF para a memória: o arquivo pode ser regravado (destaques) sem afetar o que está na tela.
    static func load(_ url: URL, password: String?) -> PDFDocument? {
        let doc = (try? Data(contentsOf: url)).flatMap { PDFDocument(data: $0) } ?? PDFDocument(url: url)
        if let password, doc?.isLocked == true { _ = doc?.unlock(withPassword: password) }
        return doc
    }

    func updateUIView(_ container: ReaderContainerView, context: Context) {
        container.showThumbnails(showThumbnails)
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            let page = container.pdfView.currentPage.flatMap { container.pdfView.document?.index(for: $0) } ?? 0
            container.pdfView.document = Self.load(url, password: password)
            if let doc = container.pdfView.document, let p = doc.page(at: min(page, max(0, doc.pageCount - 1))) {
                container.pdfView.go(to: p)
            }
            container.setNeedsLayout()
            Task { @MainActor in model.pageChanged() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject {
        let model: ReaderModel
        var token = 0
        init(model: ReaderModel) { self.model = model }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc func pageChanged() {
            Task { @MainActor in self.model.pageChanged() }
        }
        @objc func selectionChanged() {
            Task { @MainActor in self.model.selectionChanged() }
        }
    }
}


#endif
