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
    private var lastFocus: UUID?
    private var lastScrollRequest = 0
    private var lastReportedPage: UUID?
    /// While the app itself scrolls to a page, intermediate positions are not "the user's page".
    private var scrollingToPage = false
    /// Space between pages, and beside them (kept small so the page fills the screen).
    private let gap: CGFloat = 20
    private let sideGap: CGFloat = 6
    /// The page fills the width (the default, "full screen"); pinching away from it turns this off,
    /// pinching back near it or "Ajustar à largura" turns it on again.
    private var followsWidth = true
    private var fittedWidth: CGFloat = 0
    /// Axis chosen at the start of a drag: vertical unless the drag is clearly sideways.
    private var lockedAxis: (horizontal: Bool, offset: CGPoint)?
    private var keyboardOverlap: CGFloat = 0
    private var caretRevealQueued = false

    init(configuration: PagedCanvasEditor) { self.configuration = configuration; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use PagedCanvasEditor") }

    /// Number of page editors currently instantiated (virtualization check in tests).
    public var realizedPageCount: Int { pageEditors.count }
    var pagesScrollView: UIScrollView { scroll }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        scroll.delegate = self
        scroll.minimumZoomScale = 0.15; scroll.maximumZoomScale = 6
        scroll.backgroundColor = .systemGray5
        scroll.accessibilityIdentifier = "pagesScroll"
        scroll.isDirectionalLockEnabled = true
        scroll.alwaysBounceHorizontal = false
        scroll.keyboardDismissMode = .none
        view.addSubview(scroll)
        scroll.addSubview(content)
        view.addSubview(ruler)
        bindSession()
        layoutPages()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ruler.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 28)
        scroll.frame = CGRect(x: 0, y: 28, width: view.bounds.width, height: max(0, view.bounds.height - 28))
        if scroll.bounds.width > 0, !order.isEmpty {
            if fittedWidth == 0 {
                fitWidth(keepingTop: false)
                if let focus = configuration.focusPageID, focus != order.first { scrollToPageIfHidden(focus, animated: false) }
            } else if followsWidth, abs(fittedWidth - scroll.bounds.width) > 1 {
                fitWidth(keepingTop: true)      // rotation, split view, sidebar shown or hidden
            }
        }
        applyKeyboardInset()
        realizeVisiblePages(); updateRuler()
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    public func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent(); realizeVisiblePages(); updateRuler() }
    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { followsWidth = false; lockedAxis = nil }
    public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Close to the page width counts as "fill the width" again.
        let fit = fitScale
        guard fit > 0, abs(scale - fit) / fit < 0.08 else { return }
        followsWidth = true; fittedWidth = scroll.bounds.width
        if abs(scale - fit) > 0.001 { scroll.setZoomScale(fit, animated: true) }
    }
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let lock = lockedAxis, scroll.isDragging || scroll.isDecelerating, !scroll.isZooming {
            // Keep the other axis still: a vertical drag never drifts sideways, and vice versa.
            if lock.horizontal, scroll.contentOffset.y != lock.offset.y { scroll.contentOffset.y = lock.offset.y }
            if !lock.horizontal, scroll.contentOffset.x != lock.offset.x { scroll.contentOffset.x = lock.offset.x }
        }
        realizeVisiblePages(); updateRuler(); reportVisiblePage()
    }
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scrollingToPage = false; reportVisiblePage() }
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollingToPage = false
        // Sideways only when the movement is clearly sideways (within about 25° of horizontal).
        let pan = scroll.panGestureRecognizer
        var motion = pan.translation(in: scroll)
        if abs(motion.x) + abs(motion.y) < 2 { motion = pan.velocity(in: scroll) }
        lockedAxis = (abs(motion.x) > 2.1 * abs(motion.y), scroll.contentOffset)
    }
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { lockedAxis = nil } }
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { lockedAxis = nil }

    func configure(_ value: PagedCanvasEditor) {
        configuration = value
        bindSession()
        guard isViewLoaded else { return }
        layoutPages()
        // A new focus, or an explicit request (tap on a page in the list), shows that page.
        // scrollToPageIfHidden does nothing when the page is already on screen, so focus changes
        // that come from the user's own scrolling never move the view. While typing, the caret is
        // followed instead, so text flowing onto the next page does not jump to that page's top.
        if let focus = value.focusPageID, focus != lastFocus || value.scrollRequest != lastScrollRequest {
            let requested = value.scrollRequest != lastScrollRequest
            lastFocus = focus; lastScrollRequest = value.scrollRequest
            if !requested, pageEditors.values.contains(where: \.hasActiveText) { revealCaretSoon() }
            else { scrollToPageIfHidden(focus) }
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
            frames[pageID(editor)] = CGRect(x: sideGap, y: y, width: size.width, height: size.height)
            y += size.height + gap; width = max(width, size.width + 2 * sideGap)
        }
        // Only touch geometry when the stack size changes, so updates never fight a pinch or scroll.
        if content.bounds.size != CGSize(width: width, height: y) {
            let zoom = scroll.zoomScale
            content.bounds = CGRect(x: 0, y: 0, width: width, height: y)
            scroll.contentSize = CGSize(width: width * zoom, height: y * zoom)
            centerContent()
        }
        updatePanTouches()
        // Drop editors of pages that no longer exist.
        for (id, child) in pageEditors where frames[id] == nil { detach(id, child) }
        realizeVisiblePages()
    }

    /// Pages narrower than the screen (zoomed out) sit in the middle instead of on the left edge.
    private func centerContent() {
        let size = scroll.contentSize
        let inset = max(0, (scroll.bounds.width - size.width) / 2)
        content.center = CGPoint(x: size.width / 2 + inset, y: size.height / 2)
    }

    /// Two fingers scroll while one finger draws; otherwise (typing, an object selected, an Apple
    /// Pencil in use, cursor mode) one finger scrolls.
    private func updatePanTouches() {
        let fingerDraws = configuration.tool.isDrawing && !(configuration.session?.prefersPencil ?? false) &&
            pageEditors.values.allSatisfy(\.fingerDraws)
        scroll.panGestureRecognizer.minimumNumberOfTouches = fingerDraws ? 2 : 1
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
                || configuration.session?.pendingFocus?.pageID == id
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
                    child.claimPendingFocus()       // text that just flowed onto this new page
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

    private var fitScale: CGFloat {
        let width = content.bounds.width
        guard width > 0, scroll.bounds.width > 0 else { return 0 }
        // A hair under the exact width, so rounding never allows a sideways scroll.
        return min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.bounds.width / width * 0.9995))
    }

    /// Page width = screen width. Keeps the same spot of the note at the top when refitting.
    private func fitWidth(keepingTop: Bool) {
        let scale = fitScale
        guard scale > 0 else { return }
        let top = scroll.contentOffset.y / max(scroll.zoomScale, 0.01)
        scroll.setZoomScale(scale, animated: false)
        fittedWidth = scroll.bounds.width; followsWidth = true
        centerContent()
        let maxY = max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        scroll.contentOffset = CGPoint(x: 0, y: keepingTop ? min(maxY, top * scale) : 0)
    }

    private func scrollToPageIfHidden(_ id: UUID, animated: Bool = true) {
        guard let frame = frames[id], scroll.bounds.height > 0 else { return }
        let visible = scroll.convert(scroll.bounds, to: content)
        // Already showing a good part of the page: leave the user's position alone.
        if visible.intersection(frame).height >= min(frame.height, visible.height) * 0.5 { return }
        // Page top just below the top edge of the viewport.
        let zoom = scroll.zoomScale
        let maxY = max(0, scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height)
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

    // MARK: Keyboard and caret

    /// The keyboard covers the bottom of the pages; the covered part becomes scrollable space.
    @objc private func keyboardChanged(_ notification: Notification) {
        guard let screen = view.window?.windowScene?.screen else { return }
        var overlap: CGFloat = 0
        if notification.name != UIResponder.keyboardWillHideNotification,
           let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let keyboard = view.convert(end, from: screen.coordinateSpace)
            overlap = max(0, scroll.frame.maxY - keyboard.minY)
        }
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        applyKeyboardInset()
        revealCaretSoon()
    }
    private func applyKeyboardInset() {
        guard scroll.contentInset.bottom != keyboardOverlap else { return }
        scroll.contentInset.bottom = keyboardOverlap
        scroll.verticalScrollIndicatorInsets.bottom = keyboardOverlap
    }

    /// Coalesced to the next turn of the run loop, after the text box has its new size.
    private func revealCaretSoon() {
        guard !caretRevealQueued else { return }
        caretRevealQueued = true
        Task { @MainActor [weak self] in
            self?.caretRevealQueued = false
            self?.revealCaret()
        }
    }
    /// Scrolls just enough to keep the caret, and the line after it, above the keyboard.
    private func revealCaret() {
        guard let textView = pageEditors.values.lazy.compactMap(\.activeTextView).first(where: \.isFirstResponder),
              let range = textView.selectedTextRange, textView.window != nil else { return }
        let caret = textView.convert(textView.caretRect(for: range.end), to: scroll)
        guard caret.height.isFinite, caret.height > 0 else { return }
        let insets = scroll.adjustedContentInset
        let margin = caret.height * 1.5
        var offset = scroll.contentOffset
        let top = offset.y + insets.top + 8, bottom = offset.y + scroll.bounds.height - insets.bottom - 8
        if caret.maxY + margin > bottom { offset.y += caret.maxY + margin - bottom }
        else if caret.minY - 8 < top { offset.y -= top - (caret.minY - 8) }
        let left = offset.x + 8, right = offset.x + scroll.bounds.width - 8
        if caret.maxX + 24 > right { offset.x += caret.maxX + 24 - right }
        else if caret.minX - 24 < left { offset.x -= left - (caret.minX - 24) }
        let maxY = max(-insets.top, scroll.contentSize.height + insets.bottom - scroll.bounds.height)
        let maxX = max(-insets.left, scroll.contentSize.width + insets.right - scroll.bounds.width)
        offset.y = min(maxY, max(-insets.top, offset.y)); offset.x = min(maxX, max(-insets.left, offset.x))
        guard abs(offset.y - scroll.contentOffset.y) > 0.5 || abs(offset.x - scroll.contentOffset.x) > 0.5 else { return }
        scroll.setContentOffset(offset, animated: true)
    }

    /// Toolbar actions: zoom is global; insertions go to the current page; formatting goes to the
    /// page that owns the text being edited. The caret can move to any page through here.
    private func bindSession() {
        guard let session = configuration.session else { return }
        session.handler = { [weak self] action in self?.route(action) }
        session.focusRouter = { [weak self] focus in
            guard let self, let child = self.pageEditors[focus.pageID] else { return false }
            return child.claimFocus(focus)
        }
        session.revealCaret = { [weak self] in self?.revealCaretSoon() }
        session.interactionChanged = { [weak self] in
            guard let self else { return }
            for child in self.pageEditors.values { child.applyInputMode() }
            self.updatePanTouches()
        }
    }
    private func route(_ action: TextEditingAction) {
        switch action {
        case .zoom(let factor):
            followsWidth = false
            scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * factor)), animated: true)
        case .fitPage: fitWidth(keepingTop: true)
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
        ruler.offset = scroll.contentOffset.x - (content.frame.minX + sideGap * scroll.zoomScale)
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
