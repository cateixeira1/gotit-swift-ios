#if canImport(UIKit)
import SwiftUI
import UIKit
import GotItDomain

/// All pages of a note stacked vertically in one scroll view, like a word processor.
/// Each page is an embedded CanvasViewController at its logical size; this container owns
/// scrolling, zoom, the ruler and the routing of toolbar actions to the right page.
public struct PagedCanvasEditor: UIViewControllerRepresentable {
    /// One editor per page, in page order. Each editor's document is that page's projection.
    public var pages: [CanvasEditor]
    public var tool: CanvasTool
    public var session: EditorSession?
    /// Page the host considers current (selected in the page list, or where focus moved).
    public var focusPageID: UUID?
    /// Reports the page under the middle of the viewport while the user scrolls.
    public var onVisiblePage: (UUID) -> Void
    /// Changing this asks to show `focusPageID` even if it was already the focus (page list taps).
    public var scrollRequest: Int

    public init(pages: [CanvasEditor], tool: CanvasTool, session: EditorSession?, focusPageID: UUID?,
                scrollRequest: Int = 0, onVisiblePage: @escaping (UUID) -> Void) {
        self.pages = pages; self.tool = tool; self.session = session
        self.focusPageID = focusPageID; self.scrollRequest = scrollRequest; self.onVisiblePage = onVisiblePage
    }
    public func makeUIViewController(context: Context) -> PagedCanvasViewController { PagedCanvasViewController(configuration: self) }
    public func updateUIViewController(_ controller: PagedCanvasViewController, context: Context) { controller.configure(self) }
}

@MainActor
public final class PagedCanvasViewController: UIViewController, UIScrollViewDelegate {
    private var configuration: PagedCanvasEditor
    private let scroll = UIScrollView()
    private let content = UIView()
    private let ruler = PageRuler()
    private var pageEditors: [UUID: CanvasViewController] = [:]
    private var frames: [UUID: CGRect] = [:]
    private var order: [UUID] = []
    private var fitted = false
    private var lastFocus: UUID?
    private var lastScrollRequest = 0
    private var lastReportedPage: UUID?
    /// While the app itself scrolls to a page, intermediate positions are not "the user's page".
    private var scrollingToPage = false
    private let gap: CGFloat = 20

    init(configuration: PagedCanvasEditor) { self.configuration = configuration; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use PagedCanvasEditor") }

    /// Number of page editors currently instantiated (virtualization check in tests).
    public var realizedPageCount: Int { pageEditors.count }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        scroll.delegate = self
        scroll.minimumZoomScale = 0.15; scroll.maximumZoomScale = 6
        scroll.backgroundColor = .systemGray5
        scroll.accessibilityIdentifier = "pagesScroll"
        view.addSubview(scroll)
        scroll.addSubview(content)
        view.addSubview(ruler)
        bindSession()
        layoutPages()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ruler.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 28)
        scroll.frame = CGRect(x: 0, y: 28, width: view.bounds.width, height: max(0, view.bounds.height - 28))
        if !fitted, scroll.bounds.width > 0, !order.isEmpty {
            fitted = true; fitWidth()
            if let focus = configuration.focusPageID, focus != order.first { scrollToPageIfHidden(focus, animated: false) }
        }
        realizeVisiblePages(); updateRuler()
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    public func scrollViewDidZoom(_ scrollView: UIScrollView) { realizeVisiblePages(); updateRuler() }
    public func scrollViewDidScroll(_ scrollView: UIScrollView) { realizeVisiblePages(); updateRuler(); reportVisiblePage() }
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scrollingToPage = false; reportVisiblePage() }
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrollingToPage = false }

    func configure(_ value: PagedCanvasEditor) {
        configuration = value
        bindSession()
        guard isViewLoaded else { return }
        layoutPages()
        // A new focus, or an explicit request (tap on a page in the list), shows that page.
        // scrollToPageIfHidden does nothing when the page is already on screen, so focus changes
        // that come from the user's own scrolling never move the view.
        if let focus = value.focusPageID, focus != lastFocus || value.scrollRequest != lastScrollRequest {
            lastFocus = focus; lastScrollRequest = value.scrollRequest
            scrollToPageIfHidden(focus)
        }
    }

    private func pageID(_ editor: CanvasEditor) -> UUID { editor.document.pages.first?.id ?? editor.document.id }

    /// Stacks pages top to bottom; content keeps its zoom while pages are added or removed.
    private func layoutPages() {
        order = configuration.pages.map(pageID)
        var y = gap, width: CGFloat = 0
        frames = [:]
        for editor in configuration.pages {
            let size = CGSize(width: editor.document.canvas.size.width, height: editor.document.canvas.size.height)
            frames[pageID(editor)] = CGRect(x: gap, y: y, width: size.width, height: size.height)
            y += size.height + gap; width = max(width, size.width + 2 * gap)
        }
        // Only touch geometry when the stack size changes, so updates never fight a pinch or scroll.
        if content.bounds.size != CGSize(width: width, height: y) {
            let zoom = scroll.zoomScale
            content.bounds = CGRect(x: 0, y: 0, width: width, height: y)
            content.center = CGPoint(x: width * zoom / 2, y: y * zoom / 2)
            scroll.contentSize = CGSize(width: width * zoom, height: y * zoom)
        }
        scroll.panGestureRecognizer.minimumNumberOfTouches = configuration.tool.isDrawing ? 2 : 1
        // Drop editors of pages that no longer exist.
        for (id, child) in pageEditors where frames[id] == nil { detach(id, child) }
        realizeVisiblePages()
    }

    /// Pages within one screen of the viewport, plus the focused page and any page being typed in,
    /// get a live editor; the rest are released (their content is in the document).
    private func realizeVisiblePages() {
        guard isViewLoaded, scroll.bounds.height > 0 else { return }
        let visible = scroll.convert(scroll.bounds, to: content)
        let margin = max(visible.height, 400)
        let window = visible.insetBy(dx: -margin, dy: -margin)
        for (index, editor) in configuration.pages.enumerated() {
            let id = pageID(editor)
            guard let frame = frames[id] else { continue }
            var page = editor; page.tool = configuration.tool; page.session = configuration.session; page.pageNumber = index + 1
            let keep = frame.intersects(window) || id == configuration.focusPageID || pageEditors[id]?.hasActiveText == true
            if keep {
                if let child = pageEditors[id] {
                    child.view.frame = frame
                    child.configure(page)
                } else {
                    let child = CanvasViewController(configuration: page, embedded: true)
                    addChild(child)
                    child.view.frame = frame
                    content.addSubview(child.view)
                    child.didMove(toParent: self)
                    pageEditors[id] = child
                }
            } else if let child = pageEditors[id] {
                detach(id, child)
            }
        }
    }

    private func detach(_ id: UUID, _ child: CanvasViewController) {
        child.performAction(.finish)           // saves an in-progress drawing before release
        child.willMove(toParent: nil); child.view.removeFromSuperview(); child.removeFromParent()
        pageEditors[id] = nil
    }

    private func fitWidth() {
        let width = content.bounds.width
        guard width > 0 else { return }
        scroll.setZoomScale(min(1, max(scroll.minimumZoomScale, scroll.bounds.width / width)), animated: false)
        scroll.contentOffset = .zero
    }

    private func scrollToPageIfHidden(_ id: UUID, animated: Bool = true) {
        guard let frame = frames[id], scroll.bounds.height > 0 else { return }
        let visible = scroll.convert(scroll.bounds, to: content)
        // Already showing a good part of the page: leave the user's position alone.
        if visible.intersection(frame).height >= min(frame.height, visible.height) * 0.5 { return }
        // Page top just below the top edge of the viewport.
        let zoom = scroll.zoomScale
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        let offset = CGPoint(x: scroll.contentOffset.x, y: min(maxY, max(0, (frame.minY - gap / 2) * zoom)))
        lastReportedPage = id
        scrollingToPage = animated
        scroll.setContentOffset(offset, animated: animated)
        if !animated { realizeVisiblePages() }
    }

    private func reportVisiblePage() {
        guard !scrollingToPage else { return }
        let visible = scroll.convert(scroll.bounds, to: content)
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        guard let id = order.first(where: { frames[$0].map { $0.minY - gap / 2 <= middle.y && middle.y <= $0.maxY + gap / 2 } ?? false }),
              id != lastReportedPage else { return }
        lastReportedPage = id
        if id != configuration.focusPageID { lastFocus = id; configuration.onVisiblePage(id) }   // no scroll back: same page
    }

    private var currentPageID: UUID? {
        configuration.focusPageID.flatMap { frames[$0] != nil ? $0 : nil } ?? lastReportedPage ?? order.first
    }

    /// Toolbar actions: zoom is global; insertions go to the current page; formatting goes to the
    /// page that owns the text being edited.
    private func bindSession() {
        configuration.session?.handler = { [weak self] action in self?.route(action) }
    }
    private func route(_ action: TextEditingAction) {
        switch action {
        case .zoom(let factor):
            scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * factor)), animated: true)
        case .fitPage: fitWidth()
        case .insertText, .insertTable:
            if let id = currentPageID { scrollToPageIfHidden(id); pageEditors[id]?.performAction(action) }
        case .finish:
            for child in pageEditors.values { child.performAction(.finish) }
        default:
            let target = pageEditors.values.first(where: \.hasActiveText) ?? currentPageID.flatMap { pageEditors[$0] }
            target?.performAction(action)
        }
    }

    private func updateRuler() {
        ruler.zoom = scroll.zoomScale
        ruler.offset = scroll.contentOffset.x - gap * scroll.zoomScale
        guard let first = configuration.pages.first?.document.canvas else { return }
        switch first.displayUnit {
        case .centimeters: ruler.pointsPerUnit = 72 / 2.54; ruler.unitName = "cm"
        case .inches: ruler.pointsPerUnit = 72; ruler.unitName = "in"
        case .pixels: ruler.pointsPerUnit = 72 / first.pixelsPerInch; ruler.unitName = "px"
        }
        ruler.setNeedsDisplay()
    }
}
#endif
