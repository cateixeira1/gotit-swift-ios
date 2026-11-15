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

    /// Words of `text` (runs of letters or digits).
    public static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    /// How long a summary may be: about a fifth of the note (20 to 120 words), in 1 to 6 topics.
    /// The model is asked for that, given only the tokens it needs, and what runs over is cut.
    public struct SummaryPlan: Equatable, Sendable {
        public var noteWords: Int
        public var maxWords: Int
        public var topics: Int
        /// Output tokens: Portuguese takes about 2 tokens a word, plus room for the to-do list.
        public var maxTokens: Int { min(700, maxWords * 2 + 160) }
        /// Notes this short are not summarized: the summary would be as long as the note.
        public static let minimumWords = 40
        public var worthSummarizing: Bool { noteWords >= Self.minimumWords }
        public init(noteWords: Int) {
            self.noteWords = noteWords
            maxWords = min(120, max(20, noteWords / 5))
            topics = min(6, max(1, maxWords / 18))
        }
    }

    public static func summary(title: String, text: String, truncated: Bool) -> String {
        let plan = SummaryPlan(noteWords: wordCount(text))
        let shape = plan.topics == 1
            ? "em UMA frase curta"
            : "em no máximo \(plan.topics) tópicos (cada um com até 12 palavras)"
        return """
            Faça um RESUMO da nota abaixo \(shape). O resumo inteiro deve ter no máximo \(plan.maxWords) \
            palavras; a nota tem \(plan.noteWords). Resumir é condensar: junte as ideias, fique só com o \
            essencial (decisões, datas, nomes, valores) e deixe de fora exemplos, explicações e \
            detalhes. Não reescreva a nota trecho por trecho, não copie frases inteiras dela e não \
            acrescente nada que não esteja nela. Não escreva introdução nem conclusão.
            Depois do resumo, só se a nota tiver tarefas ou prazos, escreva "Pendências:" e liste \
            cada uma em poucas palavras (com o prazo, se houver). Se não houver, não escreva essa parte.
            \(truncated ? "A nota foi cortada por ser longa; resuma só o trecho fornecido.\n" : "")
            \(heading(title))
            ---
            \(text)
            ---
            """
    }

    /// The model's summary held to `plan`: at most `plan.topics` topics before "Pendências:"
    /// (the to-do list is kept whole), and an introduction line before the topics dropped.
    public static func trimmedSummary(_ answer: String, plan: SummaryPlan) -> String {
        let lines = answer.components(separatedBy: "\n")
        let todo = lines.firstIndex { $0.lowercased().replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces).hasPrefix("pendências") }
        let head = Array(lines[..<(todo ?? lines.count)]), tail = todo.map { Array(lines[$0...]) } ?? []
        func isTopic(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["* ", "- ", "• "].contains(where: trimmed.hasPrefix) { return true }
            let digits = trimmed.prefix { $0.isNumber }
            return !digits.isEmpty && (trimmed.dropFirst(digits.count).hasPrefix(". ") || trimmed.dropFirst(digits.count).hasPrefix(") "))
        }
        guard head.contains(where: isTopic) else { return answer.trimmingCharacters(in: .whitespacesAndNewlines) }
        var kept: [String] = [], topics = 0
        for line in head {
            if isTopic(line) {
                topics += 1
                if topics <= max(plan.topics, 1) { kept.append(line) }
            } else if topics > 0 && !line.trimmingCharacters(in: .whitespaces).isEmpty && topics <= plan.topics {
                kept.append(line)   // A topic that runs over two lines.
            }
        }
        let summary = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let list = tail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return list.isEmpty ? summary : summary + "\n\n" + list
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
