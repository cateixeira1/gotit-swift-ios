import Foundation

/// The pieces of a note that are searched by meaning: each text (the note's text, text boxes,
/// post-its, transcriptions, tables, captions) split into passages of at most `maxCharacters`,
/// cut at paragraph or sentence ends. Each passage is turned into a vector by the embedding model;
/// a passage whose text did not change keeps its vector.
public enum SemanticChunks {
    /// About 200–300 tokens of Portuguese: one embedding call of the smaller input sizes.
    public static let maxCharacters = 900

    public struct Chunk: Equatable, Sendable {
        public var blockID: UUID
        /// Position of the passage in its block (0, 1, …).
        public var index: Int
        public var text: String
        /// Changes when the passage's text changes (FNV-1a 64 over its UTF-8).
        public var hash: String
        public init(blockID: UUID, index: Int, text: String) {
            self.blockID = blockID; self.index = index; self.text = text; self.hash = SemanticChunks.hash(text)
        }
    }

    public static func chunks(_ document: CanvasDocument) -> [Chunk] {
        SearchText.entries(document).compactMap { entry -> [Chunk]? in
            guard let block = entry.blockID else { return nil }
            return split(entry.text).enumerated().map { Chunk(blockID: block, index: $0.offset, text: $0.element) }
        }.flatMap { $0 }
    }

    /// Passages of at most `limit` characters: whole paragraphs together while they fit, a long
    /// paragraph cut at sentence ends, and a sentence longer than the limit cut at a space.
    public static func split(_ text: String, limit: Int = maxCharacters) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var pieces: [String] = []
        for paragraph in paragraphs {
            if paragraph.count <= limit { pieces.append(paragraph); continue }
            var sentence = ""
            for character in paragraph {
                sentence.append(character)
                if ".!?;".contains(character) || sentence.count >= limit {
                    pieces.append(contentsOf: cut(sentence.trimmingCharacters(in: .whitespaces), limit)); sentence = ""
                }
            }
            if !sentence.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(contentsOf: cut(sentence.trimmingCharacters(in: .whitespaces), limit)) }
        }
        var result: [String] = [], current = ""
        for piece in pieces where !piece.isEmpty {
            if current.isEmpty { current = piece }
            else if current.count + 1 + piece.count <= limit { current += "\n" + piece }
            else { result.append(current); current = piece }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func cut(_ text: String, _ limit: Int) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = [], rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let end = window.lastIndex(of: " ") ?? window.endIndex
            result.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
            rest = rest[end...].drop { $0 == " " }
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result.filter { !$0.isEmpty }
    }

    /// What the model reads for a passage, as EmbeddingGemma 2 expects documents.
    public static func documentPrompt(title: String, text: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "title: \(title.isEmpty ? "none" : title) | text: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// What the model reads for a search, as EmbeddingGemma 2 expects queries.
    public static func queryPrompt(_ query: String) -> String {
        "task: search result | query: \(query.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(value, radix: 16)
    }

    /// Cosine similarity of two vectors already scaled to length 1 (their dot product).
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }

    /// Scaled to length 1 (the engine normally does this; vectors read back are checked again).
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }
}
