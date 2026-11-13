import Foundation

/// What the assistant (Gemma 4 E2B, on the device) is asked: the instructions, the note's text
/// cut to what fits the model's window, and passages from other notes numbered as sources.
public enum AssistantPrompts {
    /// Text of one note handed to the model, in characters (about 3 000 tokens of Portuguese),
    /// leaving room in a 4 096-token window for the instructions and the answer.
    public static let noteLimit = 9_000
    /// Text of all the sources of a question together, in characters.
    public static let sourcesLimit = 6_000
    /// Sources given for one question.
    public static let maxSources = 6

    public static let system = """
        Você é o assistente do Got It!, um app de notas. Responda sempre em português do Brasil, \
        de forma clara e direta. Use apenas o que está no texto fornecido; não invente fatos, \
        datas, nomes ou números. Se a informação pedida não estiver no texto, diga isso.
        """

    /// A passage of a note given to the model as a numbered source.
    public struct Source: Equatable, Sendable, Identifiable {
        public var documentID: UUID
        public var blockID: UUID
        public var title: String
        public var text: String
        public var id: String { documentID.uuidString + blockID.uuidString + String(text.count) }
        public init(documentID: UUID, blockID: UUID, title: String, text: String) {
            self.documentID = documentID; self.blockID = blockID; self.title = title; self.text = text
        }
    }

    /// The note's text in reading order (title, texts, post-its, transcripts, tables, captions),
    /// cut at `limit` characters on a paragraph or sentence when possible.
    public static func noteText(_ document: CanvasDocument, limit: Int = noteLimit) -> (text: String, truncated: Bool) {
        let parts = SearchText.entries(document).filter { $0.kind != .title }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let whole = parts.joined(separator: "\n\n")
        guard whole.count > limit else { return (whole, false) }
        let head = String(whole.prefix(limit))
        for mark in ["\n\n", ". ", "\n", " "] {
            if let cut = head.range(of: mark, options: .backwards), head.distance(from: head.startIndex, to: cut.lowerBound) > limit / 2 {
                return (String(head[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) + (mark == ". " ? "." : ""), true)
            }
        }
        return (head, true)
    }

    private static func heading(_ title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Nota sem título" : "Nota: \(name)"
    }

    public static func summary(title: String, text: String, truncated: Bool) -> String {
        """
        Resuma a nota abaixo em até 6 tópicos curtos, com o essencial (decisões, datas, nomes, \
        pendências). Depois dos tópicos, se houver tarefas ou prazos, liste-os em "Pendências:".
        \(truncated ? "A nota foi cortada por ser longa; resuma só o trecho fornecido.\n" : "")
        \(heading(title))
        ---
        \(text)
        ---
        """
    }

    public static func studyQuestions(title: String, text: String, truncated: Bool) -> String {
        """
        Escreva 5 perguntas para revisar o conteúdo da nota abaixo, cada uma seguida da resposta \
        curta tirada da própria nota, no formato "1. Pergunta" e na linha seguinte "Resposta: …".
        \(truncated ? "A nota foi cortada por ser longa; use só o trecho fornecido.\n" : "")
        \(heading(title))
        ---
        \(text)
        ---
        """
    }

    /// The question with the passages found in the notes, numbered [1], [2]…; the model is asked
    /// to cite them by number.
    public static func question(_ question: String, sources: [Source]) -> String {
        let numbered = sources.enumerated().map { index, source in
            "[\(index + 1)] \(heading(source.title))\n\(source.text)"
        }.joined(separator: "\n\n")
        return """
            Responda à pergunta usando somente os trechos das notas abaixo. Depois de cada \
            informação, indique de qual trecho ela veio, como [1] ou [2]. Se os trechos não \
            responderem à pergunta, diga que não encontrou isso nas notas.

            Trechos:
            \(numbered)

            Pergunta: \(question.trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }

    /// Up to `maxSources` passages, best first, one per block, within `sourcesLimit` characters
    /// (a long passage is cut rather than dropping the next ones).
    public static func pick(_ candidates: [Source], limit: Int = sourcesLimit, count: Int = maxSources) -> [Source] {
        var seen: Set<String> = [], picked: [Source] = [], used = 0
        for candidate in candidates where picked.count < count {
            let key = candidate.documentID.uuidString + candidate.blockID.uuidString
            guard !seen.contains(key), used < limit else { continue }
            seen.insert(key)
            var source = candidate
            if source.text.count > limit - used { source.text = String(source.text.prefix(limit - used)) + "…" }
            used += source.text.count
            picked.append(source)
        }
        return picked
    }

    /// Source numbers cited in an answer ("[2]", "[1, 3]", "[1][2]"), in order of first citation,
    /// only those between 1 and `count`.
    public static func citations(in answer: String, count: Int) -> [Int] {
        var found: [Int] = []
        var rest = answer[...]
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            let inside = rest[rest.index(after: open)..<close]
            for piece in inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
                if let number = Int(piece), (1...max(count, 1)).contains(number), count > 0, !found.contains(number) { found.append(number) }
            }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }
}

public extension AssistantPrompts {
    /// The model's Markdown as plain text for a note: no ** or __, list marks as "•", headings
    /// without #.
    static func plainText(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line -> String in
            var text = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            let trimmed = text.drop { $0 == " " }
            let indent = String(repeating: " ", count: text.count - trimmed.count)
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") { text = indent + "• " + trimmed.dropFirst(2) }
            else if trimmed.hasPrefix("#") { text = String(trimmed.drop { $0 == "#" }.drop { $0 == " " }) }
            return text
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
