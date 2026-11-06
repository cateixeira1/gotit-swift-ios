import Foundation

public extension RichText {
    /// Removes the last user-perceived character (emoji and combining sequences stay intact).
    /// Runs that become empty are dropped; styles of the remaining runs are untouched.
    func droppingLastCharacter() -> RichText {
        var runs = self.runs
        while let last = runs.last {
            guard let removed = last.text.indices.last else { runs.removeLast(); continue }
            var run = last
            run.text.remove(at: removed)
            if run.text.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = run }
            break
        }
        return RichText(runs: runs)
    }

    /// Length in UTF-16 units, the unit UITextView/NSRange use for selections.
    var utf16Length: Int { plainText.utf16.count }
}

public struct TextFlowMerge: Equatable, Sendable {
    /// The previous fragment with its last character removed.
    public var replacement: CanvasBlock
    /// Caret position inside `replacement`, in UTF-16 units: where the deleted character was.
    public var caret: Int
}

public extension CanvasDocument {
    /// Fragments of one story in reading order (page order, then block order).
    func textFlowFragments(story: UUID) -> [CanvasBlock] {
        let pageIndex = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.id, $0.offset) })
        let assignments = pageAssignments()
        return blocks
            .filter { $0.parentID == nil && ($0.id == story || $0.textFlowID == story) }
            .sorted {
                let a = pageIndex[assignments[$0.id] ?? id] ?? 0, b = pageIndex[assignments[$1.id] ?? id] ?? 0
                return a != b ? a < b : $0.order < $1.order
            }
    }

    /// Backspace pressed with the caret at offset 0 of a continuation fragment must delete the
    /// last character of the previous fragment, as in a single continuous text. Returns nil when
    /// the block is the first fragment of its story (nothing precedes it) or is not part of a story.
    func backspaceAcrossFragments(at blockID: UUID) -> TextFlowMerge? {
        guard let block = blocks.first(where: { $0.id == blockID }), block.parentID == nil,
              let story = block.textFlowID else { return nil }
        let fragments = textFlowFragments(story: story)
        guard let index = fragments.firstIndex(where: { $0.id == blockID }), index > 0 else { return nil }
        // Skip fragments that hold no text, so one empty page cannot trap the caret.
        for previous in fragments[..<index].reversed() {
            guard case .text(let rich) = previous.content else { return nil }
            if rich.plainText.isEmpty { continue }
            var replacement = previous
            let shortened = rich.droppingLastCharacter()
            replacement.content = .text(shortened)
            return TextFlowMerge(replacement: replacement, caret: shortened.utf16Length)
        }
        return nil
    }
}

public extension CanvasDocument {
    /// Stories whose text may need to reflow because something that text wraps around changed:
    /// an object (shape, image, PDF, container...) was inserted, removed, moved, resized, rotated,
    /// re-wrapped or moved to another page, a story's own text box was moved or resized, or the
    /// canvas-wide wrapping default changed. Drawings never wrap text, and typing changes only
    /// content (handled by the typing path), so neither counts.
    func storiesAffectedByObstacleChanges(since old: CanvasDocument) -> [UUID] {
        struct Signature: Equatable { var layout: BlockLayout; var presentation: ObjectPresentation; var parentID: UUID?; var page: UUID? }
        func signatures(_ document: CanvasDocument) -> [UUID: Signature] {
            let pages = document.pageAssignments()
            var result: [UUID: Signature] = [:]
            for block in document.blocks {
                switch block.content {
                case .drawing: continue
                case .text: if block.parentID != nil || block.textFlowID == nil { continue }  // story fragments: their own box is capacity
                default: break
                }
                result[block.id] = Signature(layout: block.layout, presentation: block.effectivePresentation,
                                             parentID: block.parentID, page: pages[block.id])
            }
            return result
        }
        let before = signatures(old), after = signatures(self)
        let assignments = pageAssignments()
        var pages: Set<UUID> = []
        let everything = old.canvas.textAvoidsObjects != canvas.textAvoidsObjects
        for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
            if let page = before[id]?.page { pages.insert(page) }
            if let page = after[id]?.page { pages.insert(page) }
        }
        guard everything || !pages.isEmpty else { return [] }
        var seen: Set<UUID> = [], stories: [UUID] = []
        for block in blocks where block.parentID == nil {
            guard case .text = block.content, let story = block.textFlowID else { continue }
            guard everything || assignments[block.id].map(pages.contains) == true, seen.insert(story).inserted else { continue }
            stories.append(story)
        }
        return stories
    }
}

public extension CanvasDocument {
    /// Stories whose text content changed outside the typing path (e.g. a named style was
    /// redefined and every heading grew): their pagination must be recomputed.
    func storiesWithTextChanges(since old: CanvasDocument) -> [UUID] {
        let previous = Dictionary(old.blocks.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = [], stories: [UUID] = []
        for block in blocks where block.parentID == nil {
            guard case .text = block.content, let story = block.textFlowID, previous[block.id] != block.content,
                  seen.insert(story).inserted else { continue }
            stories.append(story)
        }
        return stories
    }
}
