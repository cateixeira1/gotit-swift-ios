#if canImport(UIKit)
import UIKit
import GotItDomain
import GotItCanvas

public struct TextFlowFocus {
    public var blockID: UUID
    public var pageID: UUID
    public var range: NSRange
    public var text: RichText = .init("")
    /// The box's new frame, so the view can grow before the host re-renders (no clipped line).
    public var frame: LogicalRect?
}

/// One logical story, stored as linked rich-text fragments. TextKit measures actual
/// glyphs (including fonts, paragraphs and exclusions); it never estimates by characters.
@MainActor public enum TextPagination {
    static let pageBottomMargin = 24.0
    static let minimumBoxHeight = 44.0
    public struct Result {
        public var commands: [DocumentCommand]
        public var focus: TextFlowFocus
    }
    /// Lays the story out again after `replacement` changed. Pages before the edited one cannot
    /// change, except the one just before it (a word shortened at the top of a page may move back
    /// up), so layout starts there; it stops as soon as a page ends where it ended before (shifted by
    /// the edit), because everything after it is then laid out exactly as before. Typing on page 30
    /// therefore lays out two pages, not thirty. `incremental: false` lays out the whole story.
    public static func reflow(_ replacement: CanvasBlock, in document: CanvasDocument, selection: NSRange,
                              incremental: Bool = true) throws -> Result {
        let story = replacement.textFlowID ?? replacement.id
        let pageIndices = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ($0.element.id, $0.offset) })
        let fragments = document.blocks.filter { $0.id == replacement.id || $0.textFlowID == story }.sorted {
            (pageIndices[document.pageID(for: $0.id) ?? document.id] ?? 0) < (pageIndices[document.pageID(for: $1.id) ?? document.id] ?? 0)
        }
        guard let first = fragments.first, first.parentID == nil, let firstPage = document.pageID(for: first.id) else { throw DocumentError.invalid("Missing text story") }
        func length(_ block: CanvasBlock) -> Int {
            if case .text(let rich) = block.content { return (rich.plainText as NSString).length }; return 0
        }
        let edited = fragments.firstIndex { $0.id == replacement.id } ?? 0
        let startIndex = incremental ? max(0, edited - 1) : 0
        let delta = length(replacement) - length(fragments[edited])
        // Where each unchanged fragment after the edit ended before, in this layout's coordinates.
        var oldEnds: [Int: Int] = [:]
        var running = 0
        for (index, fragment) in fragments.enumerated() where index >= startIndex {
            running += length(fragment)
            if index >= edited { oldEnds[index] = running }
        }
        let text = NSMutableAttributedString(string: "")
        var globalCaret = selection.location
        for fragment in fragments[startIndex...] {
            let item = fragment.id == replacement.id ? replacement : fragment
            guard case .text(let rich) = item.content else { throw DocumentError.invalid("Invalid text story") }
            if fragment.id == replacement.id { globalCaret += text.length }
            text.append(TextBridge.attributed(rich, base: try document.resolvedStyle(for: fragment.id)))
        }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager(); storage.addLayoutManager(manager)
        var commands: [DocumentCommand] = [], used: [CanvasBlock] = []
        var focus = TextFlowFocus(blockID: first.id, pageID: firstPage, range: .init(location: 0, length: 0))
        var focusFound = false
        var offset = 0, index = startIndex, previousPage = document.pageID(for: fragments[startIndex].id) ?? firstPage
        var stoppedEarly = false
        let nextOrder = (document.blocks.map(\.order).max() ?? 0) + 1
        repeat {
            var fragment: CanvasBlock
            if index < fragments.count { fragment = fragments[index] }
            else {
                let page = CanvasPage(title: "Continuação", textFlowID: story)
                commands.append(.insertPage(page, after: previousPage))
                fragment = CanvasBlock(order: nextOrder + index, layout: .init(mode: .absolute,
                    frame: .init(x: first.layout.frame.x, y: 24, width: first.layout.frame.width, height: document.canvas.size.height - 48)),
                    style: first.style, content: .text(.init("")), pageID: page.id, textFlowID: story)
            }
            fragment.textFlowID = story
            let page = fragment.pageID ?? firstPage
            let frame = fragment.layout.frame
            // A story box may grow down to the page's bottom margin before text continues on the
            // next page; afterwards the last box shrinks to its text (see below), so a box never
            // covers empty paper where the user wants to tap and start another text.
            let available = max(frame.height, document.canvas.size.height - frame.y - pageBottomMargin)
            let container = NSTextContainer(size: CGSize(width: max(1, frame.width - 8), height: max(1, available - 8)))
            container.lineFragmentPadding = 5
            // Existing media on this page keeps the same wrapping contract as the canvas,
            // measured against the full area the box may grow into.
            if let stored = document.blocks.firstIndex(where: { $0.id == fragment.id }) {
                var probe = document
                probe.blocks[stored].layout.frame.height = available
                container.exclusionPaths = (try TextFlowEngine.exclusions(for: fragment.id, in: probe)).map { exclusion in
                    let path = UIBezierPath()
                    for (i, p) in exclusion.polygon.enumerated() {
                        let point = CGPoint(x: p.x - 4, y: p.y - 4)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.close(); return path
                }
            }
            manager.addTextContainer(container); manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard range.length > 0 || storage.length == 0 else {
                throw DocumentError.invalid("A área de texto não comporta uma linha. Aumente o bloco ou reduza a fonte.")
            }
            let end = NSMaxRange(range)
            guard end > offset || storage.length == 0 else { throw DocumentError.invalid("Text layout made no progress") }
            fragment.content = .text(TextBridge.richText(storage.attributedSubstring(from: range)))
            if end == storage.length {
                // Last box: as tall as its text plus one line of room for the next keystroke.
                let used = manager.usedRect(for: container)
                fragment.layout.frame.height = min(available, max(minimumBoxHeight, ceil(used.maxY) + 8 + 24))
            } else {
                fragment.layout.frame.height = available
            }
            if index >= fragments.count { commands.append(.insertBlock(fragment)) }
            else if fragment != fragments[index] { commands.append(.replaceBlock(fragment)) }   // unchanged pages are not rewritten
            used.append(fragment)
            if globalCaret >= range.location && (globalCaret < end || end == storage.length) {
                focus = .init(blockID: fragment.id, pageID: page,
                    range: .init(location: min(range.length, max(0, globalCaret - range.location)), length: min(selection.length, max(0, end - globalCaret))))
                focusFound = true
            }
            offset = end; previousPage = page
            // This page ends where it ended before: the rest of the story is laid out as it was.
            if incremental, index >= edited, index + 1 < fragments.count, let before = oldEnds[index], end == before + delta, end < storage.length {
                if !focusFound, globalCaret >= end, let next = fragments.dropFirst(index + 1).first {
                    focus = .init(blockID: next.id, pageID: document.pageID(for: next.id) ?? page,
                                  range: .init(location: min(length(next), globalCaret - end), length: 0))
                    if case .text(let rich) = next.content { focus.text = rich }
                    focus.frame = next.layout.frame
                    focusFound = true
                }
                stoppedEarly = true
                break
            }
            index += 1
        } while offset < storage.length
        if stoppedEarly { return .init(commands: commands, focus: focusWithText(focus, used: used)) }
        let unused = fragments.dropFirst(startIndex + used.count)
        for fragment in unused { commands.append(.removeSubtree(fragment.id)) }
        for fragment in unused {
            guard let page = document.pageID(for: fragment.id), document.pages.first(where: { $0.id == page })?.textFlowID == story else { continue }
            // Remove only pages owned by this story and containing no other objects.
            let removedIDs = Set(unused.map(\.id))
            if !document.blocks.contains(where: { document.pageID(for: $0.id) == page && !removedIDs.contains($0.id) }) { commands.append(.removePage(page)) }
        }
        return .init(commands: commands, focus: focusWithText(focus, used: used))
    }

    private static func focusWithText(_ focus: TextFlowFocus, used: [CanvasBlock]) -> TextFlowFocus {
        var focus = focus
        if let block = used.first(where: { $0.id == focus.blockID }), case .text(let rich) = block.content {
            focus.text = rich; focus.frame = block.layout.frame
        }
        return focus
    }
}
#endif
