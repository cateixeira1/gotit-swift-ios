import Foundation

/// A reusable paragraph style, as in a word processor. `style` sets every attribute the style
/// controls, so switching from "Título" to "Corpo" also undoes the title's size and weight.
public struct NamedStyle: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var style: BlockStyle
    public init(id: String, name: String, style: BlockStyle) { self.id = id; self.name = name; self.style = style }
}

public extension NamedStyle {
    static let builtIn: [NamedStyle] = [
        .init(id: "title", name: "Título", style: .init(fontSize: 30, bold: true, italic: false, foreground: "#111827",
              paragraph: .init(paragraphSpacing: 12))),
        .init(id: "subtitle", name: "Subtítulo", style: .init(fontSize: 22, bold: false, italic: false, foreground: "#4B5563",
              paragraph: .init(paragraphSpacing: 10))),
        .init(id: "heading1", name: "Título 1", style: .init(fontSize: 24, bold: true, italic: false, foreground: "#111827",
              paragraph: .init(paragraphSpacing: 8))),
        .init(id: "heading2", name: "Título 2", style: .init(fontSize: 20, bold: true, italic: false, foreground: "#1F2937",
              paragraph: .init(paragraphSpacing: 6))),
        .init(id: "body", name: "Corpo", style: .init(fontSize: 18, bold: false, italic: false, foreground: "#111827",
              paragraph: .init(paragraphSpacing: 4))),
        .init(id: "quote", name: "Citação", style: .init(fontSize: 18, bold: false, italic: true, foreground: "#4B5563",
              paragraph: .init(paragraphSpacing: 6, headIndent: 24, firstLineIndent: 24))),
    ]
}

public extension CanvasDocument {
    /// Built-ins in their fixed order (with this note's overrides), then this note's own styles.
    var effectiveNamedStyles: [NamedStyle] {
        let overrides = Dictionary(namedStyles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let builtInIDs = Set(NamedStyle.builtIn.map(\.id))
        return NamedStyle.builtIn.map { overrides[$0.id] ?? $0 } + namedStyles.filter { !builtInIDs.contains($0.id) }
    }

    func namedStyle(_ id: String) -> NamedStyle? { effectiveNamedStyles.first { $0.id == id } }

    /// Redefines a named style and updates every text tagged with it, in one undoable batch.
    /// For each attribute, text that still has the old definition's value takes the new value;
    /// text the user formatted by hand (a different value) keeps its own formatting.
    func redefiningNamedStyle(_ updated: NamedStyle) throws -> [DocumentCommand] {
        guard let old = namedStyle(updated.id) else { throw DocumentError.invalid("Unknown named style") }
        var definitions = namedStyles.filter { $0.id != updated.id }
        definitions.append(updated)
        var commands: [DocumentCommand] = [.setNamedStyles(definitions)]
        for var block in blocks {
            guard case .text(var rich) = block.content else { continue }
            var changed = false
            for index in rich.runs.indices where rich.runs[index].style.namedStyle == updated.id {
                let restyled = rich.runs[index].style.replacingDefinition(old.style, with: updated.style)
                if restyled != rich.runs[index].style { rich.runs[index].style = restyled; changed = true }
            }
            if changed { block.content = .text(rich); commands.append(.replaceBlock(block)) }
        }
        return commands
    }
}

extension BlockStyle {
    /// Attributes equal to the old definition follow the new one; overrides stay.
    func replacingDefinition(_ old: BlockStyle, with new: BlockStyle) -> BlockStyle {
        func pick<T: Equatable>(_ current: T?, _ before: T?, _ after: T?) -> T? {
            guard before != nil || after != nil else { return current }
            return current == before ? after : current
        }
        var result = self
        result.fontName = pick(fontName, old.fontName, new.fontName)
        result.fontSize = pick(fontSize, old.fontSize, new.fontSize)
        result.bold = pick(bold, old.bold, new.bold)
        result.italic = pick(italic, old.italic, new.italic)
        result.foreground = pick(foreground, old.foreground, new.foreground)
        result.background = pick(background, old.background, new.background)
        result.alignment = pick(alignment, old.alignment, new.alignment)
        result.underline = pick(underline, old.underline, new.underline)
        result.strikethrough = pick(strikethrough, old.strikethrough, new.strikethrough)
        result.paragraph = pick(paragraph, old.paragraph, new.paragraph)
        return result
    }
}

public extension RichText {
    /// Applies a named style to every paragraph touched by `range` (UTF-16 units, as NSRange),
    /// like a word processor's style picker. Runs are split at paragraph boundaries only as
    /// needed and merged back when adjacent styles are equal. Text content never changes.
    func applyingNamedStyle(_ named: NamedStyle, utf16Range range: Range<Int>) -> RichText {
        var characters: [(Character, BlockStyle)] = []
        for run in runs { for character in run.text { characters.append((character, run.style)) } }
        guard !characters.isEmpty else {
            return RichText(runs: [TextRun("", style: (runs.first?.style ?? .init()).merging(named.style).tagged(named.id))])
        }
        // Map UTF-16 offsets to character indices.
        var utf16 = 0, startIndex = characters.count, endIndex = characters.count
        for (index, item) in characters.enumerated() {
            if startIndex == characters.count, utf16 >= range.lowerBound { startIndex = index }
            if utf16 >= range.upperBound, endIndex == characters.count { endIndex = index; break }
            utf16 += item.0.utf16.count
        }
        if startIndex == characters.count { startIndex = characters.count - 1 }   // caret at the very end
        endIndex = max(endIndex, startIndex + 1)
        // Grow to whole paragraphs; a paragraph owns its trailing newline.
        var lower = startIndex
        while lower > 0, characters[lower - 1].0 != "\n" { lower -= 1 }
        var upper = endIndex - 1
        while upper < characters.count - 1, characters[upper].0 != "\n" { upper += 1 }
        upper += 1
        for index in lower..<upper {
            characters[index].1 = characters[index].1.merging(named.style).tagged(named.id)
        }
        var merged: [TextRun] = []
        for (character, style) in characters {
            if let last = merged.last, last.style == style { merged[merged.count - 1].text.append(character) }
            else { merged.append(TextRun(String(character), style: style)) }
        }
        return RichText(runs: merged)
    }
}

extension BlockStyle {
    func tagged(_ id: String) -> BlockStyle { var copy = self; copy.namedStyle = id; return copy }
}
