import Foundation

/// What of a note can be found by searching: its title, its text (the note's text, text boxes,
/// post-its, transcriptions), table cells and the captions of pictures, PDFs, audio and video.
/// Handwriting stays ink until it is converted to text; it is not searched.
public enum SearchText {
    /// Raised when what is indexed changes, so stored indexes are built again.
    /// 2: links between notes are indexed with the text.
    /// 3: each entry has its own row number (`rowID`), so an edit replaces or removes it directly.
    public static let indexVersion = 3

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
    /// touches the blocks it changed; a block equal to what it was is not even read for its text.
    public static func changes(from old: CanvasDocument?, to new: CanvasDocument) -> (removed: [UUID?], written: [Entry]) {
        guard let old else { return ([], entries(new)) }
        var removed: [UUID?] = [], written: [Entry] = []
        func compare(_ key: UUID?, _ before: Entry?, _ after: Entry?) {
            guard before != after else { return }
            if before != nil { removed.append(key) }
            if let after { written.append(after) }
        }
        func title(_ document: CanvasDocument) -> Entry? {
            let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : Entry(blockID: nil, kind: .title, text: title)
        }
        if old.title != new.title { compare(nil, title(old), title(new)) }
        var before = Dictionary(old.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        for block in new.blocks where seen.insert(block.id).inserted {
            let previous = before.removeValue(forKey: block.id)
            if let previous, previous.content == block.content { continue }
            compare(block.id, previous.flatMap(entry(for:)), entry(for: block))
        }
        for (id, block) in before { compare(id, entry(for: block), nil) }
        return (removed, written)
    }

    /// The row an entry takes in the index: always the same for a note and block (nil: the
    /// title), so the row is replaced or removed by its number. Looking an entry up by its note
    /// and block instead reads every row of the index, the whole library, on each edit.
    /// 63 bits of FNV-1a over the two identifiers; never zero.
    public static func rowID(document: UUID, block: UUID?) -> Int64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ id: UUID) {
            withUnsafeBytes(of: id.uuid) { bytes in
                for byte in bytes { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            }
        }
        mix(document)
        // A marker byte keeps the title's row apart from any block's.
        value = (value ^ (block == nil ? 0x54 : 0x42)) &* 0x0000_0100_0000_01b3
        if let block { mix(block) }
        let row = Int64(value & UInt64(Int64.max))
        return row == 0 ? 1 : row
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
