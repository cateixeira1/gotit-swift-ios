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
