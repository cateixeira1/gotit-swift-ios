#if canImport(UIKit)
import UIKit
import GotItDomain
import GotItCanvas

public struct TextFlowFocus {
    public var blockID: UUID
    public var pageID: UUID
    public var range: NSRange
    public var text: RichText = .init("")
}

/// One logical story, stored as linked rich-text fragments. TextKit measures actual
/// glyphs (including fonts, paragraphs and exclusions); it never estimates by characters.
@MainActor public enum TextPagination {
    public struct Result {
        public var commands: [DocumentCommand]
        public var focus: TextFlowFocus
    }
    public static func reflow(_ replacement: CanvasBlock, in document: CanvasDocument, selection: NSRange) throws -> Result {
        let story = replacement.textFlowID ?? replacement.id
        let pageIndices = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ($0.element.id, $0.offset) })
        let fragments = document.blocks.filter { $0.id == replacement.id || $0.textFlowID == story }.sorted {
            (pageIndices[document.pageID(for: $0.id) ?? document.id] ?? 0) < (pageIndices[document.pageID(for: $1.id) ?? document.id] ?? 0)
        }
        guard let first = fragments.first, first.parentID == nil, let firstPage = document.pageID(for: first.id) else { throw DocumentError.invalid("Missing text story") }
        let text = NSMutableAttributedString(string: "")
        var globalCaret = selection.location
        for fragment in fragments {
            let item = fragment.id == replacement.id ? replacement : fragment
            guard case .text(let rich) = item.content else { throw DocumentError.invalid("Invalid text story") }
            if fragment.id == replacement.id { globalCaret += text.length }
            text.append(TextBridge.attributed(rich, base: try document.resolvedStyle(for: fragment.id)))
        }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager(); storage.addLayoutManager(manager)
        var commands: [DocumentCommand] = [], used: [CanvasBlock] = []
        var focus = TextFlowFocus(blockID: first.id, pageID: firstPage, range: .init(location: 0, length: 0))
        var offset = 0, index = 0, previousPage = firstPage
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
            let container = NSTextContainer(size: CGSize(width: max(1, frame.width - 8), height: max(1, frame.height - 8)))
            container.lineFragmentPadding = 5
            // Existing media on this page keeps the same wrapping contract as the canvas.
            if document.blocks.contains(where: { $0.id == fragment.id }) {
                container.exclusionPaths = (try TextFlowEngine.exclusions(for: fragment.id, in: document)).map { exclusion in
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
            commands.append(index < fragments.count ? .replaceBlock(fragment) : .insertBlock(fragment))
            used.append(fragment)
            if globalCaret >= range.location && (globalCaret < end || end == storage.length) {
                focus = .init(blockID: fragment.id, pageID: page,
                    range: .init(location: min(range.length, max(0, globalCaret - range.location)), length: min(selection.length, max(0, end - globalCaret))))
            }
            offset = end; previousPage = page; index += 1
        } while offset < storage.length
        let unused = fragments.dropFirst(used.count)
        for fragment in unused { commands.append(.removeSubtree(fragment.id)) }
        for fragment in unused {
            guard let page = document.pageID(for: fragment.id), document.pages.first(where: { $0.id == page })?.textFlowID == story else { continue }
            // Remove only pages owned by this story and containing no other objects.
            let removedIDs = Set(unused.map(\.id))
            if !document.blocks.contains(where: { document.pageID(for: $0.id) == page && !removedIDs.contains($0.id) }) { commands.append(.removePage(page)) }
        }
        if let block = used.first(where: { $0.id == focus.blockID }), case .text(let rich) = block.content { focus.text = rich }
        return .init(commands: commands, focus: focus)
    }
}
#endif
