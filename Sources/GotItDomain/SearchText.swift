import Foundation

/// What of a note can be found by searching: its title, its text (the note's text, text boxes,
/// post-its, transcriptions), table cells and the captions of pictures, PDFs, audio and video.
/// Handwriting stays ink until it is converted to text; it is not searched.
public enum SearchText {
    /// Raised when what is indexed changes, so stored indexes are built again.
    /// 2: links between notes are indexed with the text.
    public static let indexVersion = 2

    public enum Kind: String, Codable, Sendable { case title, text, table, caption }

    public struct Entry: Equatable, Sendable {
        /// Nil for the title.
        public var blockID: UUID?
        public var kind: Kind
        public var text: String
        public init(blockID: UUID?, kind: Kind, text: String) { self.blockID = blockID; self.kind = kind; self.text = text }
    }

    public static func entries(_ document: CanvasDocument) -> [Entry] {
        var result: [Entry] = []
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { result.append(Entry(blockID: nil, kind: .title, text: title)) }
        for block in document.blocks {
            if let entry = entry(for: block) { result.append(entry) }
        }
        return result
    }

    static func entry(for block: CanvasBlock) -> Entry? {
        let kind: Kind, text: String
        switch block.content {
        case .text(let rich): kind = .text; text = rich.plainText
        case .table(let table): kind = .table; text = table.cells.map { $0.map(\.text.plainText).joined(separator: " ") }.joined(separator: "\n")
        case .image(let ref), .pdf(let ref), .audio(let ref), .video(let ref), .sticker(let ref): kind = .caption; text = ref.caption ?? ""
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Entry(blockID: block.id, kind: kind, text: trimmed)
    }

    /// What to change in an index going from `old` to `new`: the entries to remove (by block; nil
    /// is the title) and the entries to write. Unchanged blocks are left alone, so an edit only
    /// touches the blocks it changed.
    public static func changes(from old: CanvasDocument?, to new: CanvasDocument) -> (removed: [UUID?], written: [Entry]) {
        let before = Dictionary((old.map(entries) ?? []).map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(entries(new).map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        var removed: [UUID?] = [], written: [Entry] = []
        for (key, entry) in before where after[key] != entry { removed.append(key) }
        for (key, entry) in after where before[key] != entry { written.append(entry) }
        return (removed, written)
    }

    /// The words typed, as an FTS5 query: every word must appear, each as the start of a word
    /// ("proc" finds "processo"). Accents and case do not matter (the index ignores them).
    /// Nil when nothing searchable was typed.
    public static func query(_ input: String) -> String? {
        let words = input.split { !($0.isLetter || $0.isNumber) }.map(String.init).prefix(12)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Where the first typed word appears in `text` (case and accents ignored), for putting the
    /// caret on what was found.
    public static func firstMatch(of input: String, in text: String) -> NSRange? {
        let words = input.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard let word = words.first else { return nil }
        let range = (text as NSString).range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        return range.location == NSNotFound ? nil : range
    }
}
