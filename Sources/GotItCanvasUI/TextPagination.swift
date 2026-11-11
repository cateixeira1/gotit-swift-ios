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
    public init(blockID: UUID, pageID: UUID, range: NSRange, text: RichText = .init(""), frame: LogicalRect? = nil) {
        self.blockID = blockID; self.pageID = pageID; self.range = range; self.text = text; self.frame = frame
    }
}

/// One logical story, stored as linked rich-text fragments. TextKit measures actual
/// glyphs (including fonts, paragraphs and exclusions); it never estimates by characters.
@MainActor public enum TextPagination {
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
        // Every page has the same text area: inside the margins, clear of header and footer.
        let area = document.canvas.textArea
        repeat {
            var fragment: CanvasBlock
            if index < fragments.count { fragment = fragments[index] }
            else {
                let page = CanvasPage(title: "Continuação", textFlowID: story)
                commands.append(.insertPage(page, after: previousPage))
                fragment = CanvasBlock(order: nextOrder + index, layout: .init(mode: .absolute,
                    frame: .init(x: first.layout.frame.x, y: area.y, width: first.layout.frame.width, height: area.height)),
                    style: first.style, content: .text(.init("")), pageID: page.id, textFlowID: story)
            }
            fragment.textFlowID = story
            let page = fragment.pageID ?? firstPage
            // Continuation pages start at the top of the text area (it moves with the header).
            if index > 0, fragment.layout.frame.y != area.y { fragment.layout.frame.y = area.y }
            let frame = fragment.layout.frame
            // A story box may grow down to the page's bottom margin before text continues on the
            // next page; afterwards the last box shrinks to its text (see below), so a box never
            // covers empty paper where the user wants to tap and start another text.
            let available = max(minimumBoxHeight, area.y + area.height - frame.y)
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

#if canImport(UIKit)
/// An edit of a selection that may run across pages.
public enum StoryEdit {
    /// Typing or pasting over the selection.
    case replace(String)
    case delete
    /// Bold, italic, underline, strike-through, colour, highlight, font or size on the selection.
    case format(TextEditingAction)
}

/// Edits a story as one text: its fragments are joined, the edit is applied to the joined text,
/// and the whole is laid out again from the first page (one undo step for the host).
@MainActor public enum StoryEditing {
    /// The whole story as one attributed text, and where each fragment begins in it.
    public static func joined(story: UUID, in document: CanvasDocument) throws -> (text: NSMutableAttributedString, fragments: [CanvasBlock]) {
        let pageIndices = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ($0.element.id, $0.offset) })
        let fragments = document.blocks.filter { $0.id == story || $0.textFlowID == story }.sorted {
            (pageIndices[document.pageID(for: $0.id) ?? document.id] ?? 0, $0.order) < (pageIndices[document.pageID(for: $1.id) ?? document.id] ?? 0, $1.order)
        }
        let text = NSMutableAttributedString()
        for fragment in fragments {
            guard case .text(let rich) = fragment.content else { throw DocumentError.invalid("Invalid text story") }
            text.append(TextBridge.attributed(rich, base: try document.resolvedStyle(for: fragment.id)))
        }
        return (text, fragments)
    }

    public static func apply(_ edit: StoryEdit, to range: NSRange, story: UUID, in document: CanvasDocument) throws -> TextPagination.Result {
        let (text, fragments) = try joined(story: story, in: document)
        guard var first = fragments.first else { throw DocumentError.invalid("Missing text story") }
        let start = min(max(0, range.location), text.length)
        let selection = NSRange(location: start, length: min(max(0, range.length), text.length - start))
        var caret = NSRange(location: selection.location, length: 0)
        switch edit {
        case .replace(let string):
            var attributes: [NSAttributedString.Key: Any] = [:]
            if text.length > 0 { attributes = text.attributes(at: min(selection.location, text.length - 1), effectiveRange: nil) }
            attributes[.attachment] = nil
            text.replaceCharacters(in: selection, with: NSAttributedString(string: string, attributes: attributes))
            caret.location = selection.location + (string as NSString).length
        case .delete:
            text.deleteCharacters(in: selection)
        case .format(let action):
            format(text, selection, action)
            caret = selection
        }
        // Everything in the first fragment, the others emptied: laying the story out again from the
        // start puts each page's share back, reusing the same boxes and removing the ones left over.
        var working = document
        var commands: [DocumentCommand] = []
        for fragment in fragments.dropFirst() {
            var emptied = fragment; emptied.content = .text(RichText(""))
            commands.append(.replaceBlock(emptied))
        }
        working = try CommandEngine.applying(commands, to: working)
        first.content = .text(TextBridge.richText(text))
        let result = try TextPagination.reflow(first, in: working, selection: caret, incremental: false)
        return .init(commands: commands + result.commands, focus: result.focus)
    }

    static func format(_ text: NSMutableAttributedString, _ range: NSRange, _ action: TextEditingAction) {
        guard range.length > 0 else { return }
        func fonts(_ change: (UIFont) -> UIFont) {
            text.enumerateAttribute(.font, in: range) { value, part, _ in
                text.addAttribute(.font, value: change((value as? UIFont) ?? .systemFont(ofSize: 18)), range: part)
            }
        }
        func allFonts(_ test: (UIFont) -> Bool) -> Bool {
            var all = true
            text.enumerateAttribute(.font, in: range) { value, _, stop in
                if !test((value as? UIFont) ?? .systemFont(ofSize: 18)) { all = false; stop.pointee = true }
            }
            return all
        }
        func trait(_ trait: UIFontDescriptor.SymbolicTraits) {
            let remove = allFonts { $0.fontDescriptor.symbolicTraits.contains(trait) }
            fonts { font in
                var traits = font.fontDescriptor.symbolicTraits
                if remove { traits.remove(trait) } else { traits.insert(trait) }
                return font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            }
        }
        func toggle(_ key: NSAttributedString.Key) {
            var all = true
            text.enumerateAttribute(key, in: range) { value, _, stop in if ((value as? Int) ?? 0) == 0 { all = false; stop.pointee = true } }
            if all { text.removeAttribute(key, range: range) } else { text.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        switch action {
        case .bold: trait(.traitBold)
        case .italic: trait(.traitItalic)
        case .underline: toggle(.underlineStyle)
        case .strike: toggle(.strikethroughStyle)
        case .foreground(let color): text.addAttribute(.foregroundColor, value: color, range: range)
        case .highlight(let color):
            if let color { text.addAttribute(.backgroundColor, value: color, range: range) } else { text.removeAttribute(.backgroundColor, range: range) }
        case .fontSize(let size): fonts { $0.withSize(max(6, min(144, size))) }
        case .font(let name): fonts { font in name == "Sistema" ? .systemFont(ofSize: font.pointSize) : (UIFont(name: name, size: font.pointSize) ?? font) }
        default: break
        }
    }
}
#endif
