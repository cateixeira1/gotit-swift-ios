import Foundation

/// "Organizar esta nota": the assistant proposes a title, a folder and the note's to-dos, in a
/// fixed line format. Nothing it writes is applied as is: each item is checked against the note
/// and the folders that exist, what fails is dropped, and what is left is applied only when the
/// person chooses it (as ordinary, undoable edits).
public enum NoteProposals {
    public static let maxTasks = 8
    public static let maxTitleWords = 10

    public struct Proposal: Equatable, Sendable {
        /// A new title for the note.
        public var title: String?
        /// The name of an existing folder, as the folder list writes it.
        public var folder: String?
        /// To-dos the note itself asks for.
        public var tasks: [String]
        /// What the model wrote that was not kept, and why (for the tests and the log).
        public var dropped: [String]
        public var isEmpty: Bool { title == nil && folder == nil && tasks.isEmpty }
        public init(title: String? = nil, folder: String? = nil, tasks: [String] = [], dropped: [String] = []) {
            self.title = title; self.folder = folder; self.tasks = tasks; self.dropped = dropped
        }
    }

    public static func prompt(title: String, text: String, truncated: Bool, folders: [String]) -> String {
        let list = folders.isEmpty ? "(nenhuma pasta criada; escreva PASTA: NENHUMA)" : folders.map { "- \($0)" }.joined(separator: "\n")
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            Leia a nota abaixo e proponha como organizá-la. Responda exatamente neste formato, \
            em três partes, sem mais nada:
            TÍTULO: um título curto (até 8 palavras) que diga do que a nota trata
            PASTA: o nome exato de uma das pastas da lista abaixo, ou NENHUMA se nenhuma combinar
            TAREFAS:
            - cada tarefa que a própria nota pede, em poucas palavras, com o prazo se houver
            Se a nota não tiver tarefas, escreva "TAREFAS: NENHUMA". Não invente tarefas, \
            pastas ou datas que não estejam na nota ou na lista.

            Pastas:
            \(list)
            \(truncated ? "\nA nota foi cortada por ser longa; use só o trecho fornecido.\n" : "")
            Título atual: \(name.isEmpty ? "(sem título)" : name)
            ---
            \(text)
            ---
            """
    }

    /// The model's answer read and checked: a title of 2–80 characters (and at most
    /// `maxTitleWords` words) different from the current one; a folder only if it exists and is
    /// not the note's folder already; up to `maxTasks` to-dos, each sharing a word or a number
    /// with the note (so none is made up), without repeats.
    public static func parse(_ answer: String, note: String, currentTitle: String,
                             currentFolder: String?, folders: [String]) -> Proposal {
        var proposal = Proposal()
        var section: String?
        var titleText: String?, folderText: String?, taskLines: [String] = []
        for raw in answer.components(separatedBy: .newlines) {
            let line = clean(raw)
            guard !line.isEmpty else { continue }
            if let (key, rest) = keyed(line) {
                section = key
                switch key {
                case "titulo": titleText = rest
                case "pasta": folderText = rest
                default: if !rest.isEmpty, !isNone(rest) { taskLines.append(rest) }
                }
                continue
            }
            if section == "tarefas" { taskLines.append(line) }
        }

        if let text = titleText.map(unquoted), !text.isEmpty, !isNone(text) {
            let words = text.split(separator: " ").count
            if text.count < 2 || text.count > 80 || words > maxTitleWords { proposal.dropped.append("título: \(text)") }
            else if fold(text) == fold(currentTitle) { proposal.dropped.append("título igual ao atual") }
            else { proposal.title = text }
        }

        if let text = folderText.map(unquoted), !text.isEmpty, !isNone(text) {
            if let match = folders.first(where: { fold($0) == fold(text) }) {
                if let currentFolder, fold(currentFolder) == fold(match) { proposal.dropped.append("já está na pasta \(match)") }
                else { proposal.folder = match }
            } else { proposal.dropped.append("pasta que não existe: \(text)") }
        }

        let noteWords = Set(words(note)), noteNumbers = Set(numbers(note))
        var seen: Set<String> = []
        for line in taskLines {
            let task = unquoted(bulletless(line))
            guard !task.isEmpty, !isNone(task) else { continue }
            let key = fold(task)
            guard !seen.contains(key) else { continue }
            guard task.count >= 3, task.count <= 120 else { proposal.dropped.append("tarefa: \(task)"); continue }
            let grounded = words(task).contains(where: noteWords.contains) || numbers(task).contains(where: noteNumbers.contains)
            guard grounded else { proposal.dropped.append("tarefa sem apoio na nota: \(task)"); continue }
            guard proposal.tasks.count < maxTasks else { proposal.dropped.append("tarefa além do limite: \(task)"); continue }
            seen.insert(key)
            proposal.tasks.append(task)
        }
        return proposal
    }

    /// The to-dos as the text inserted in the note.
    public static func taskText(_ tasks: [String]) -> String {
        (["Pendências:"] + tasks.map { "• \($0)" }).joined(separator: "\n")
    }

    // MARK: Reading the answer

    /// "TÍTULO: x", "**Pasta:** x", "Tarefas:" → (key without accents, the rest).
    private static func keyed(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = fold(String(line[..<colon]))
        guard ["titulo", "pasta", "tarefas"].contains(key) else { return nil }
        return (key, clean(String(line[line.index(after: colon)...])))
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func bulletless(_ line: String) -> String {
        var text = Substring(line)
        if let first = text.first, "-*•".contains(first) { text = text.dropFirst() }
        else {
            let digits = text.prefix { $0.isNumber }
            if !digits.isEmpty, let next = text.dropFirst(digits.count).first, next == "." || next == ")" { text = text.dropFirst(digits.count + 1) }
        }
        if text.hasPrefix("[ ]") || text.hasPrefix("[x]") { text = text.dropFirst(3) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        let quotes: Set<Character> = ["\"", "“", "”", "'", "«", "»"]
        while let first = value.first, quotes.contains(first) { value.removeFirst() }
        while let last = value.last, quotes.contains(last) || last == "." { value.removeLast() }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func isNone(_ text: String) -> Bool {
        ["nenhuma", "nenhum", "nao ha", "nada", "-", "n/a"].contains(fold(unquoted(text)))
    }

    /// Lowercased, without accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Words of four letters or more, folded (short ones like "de", "com" say nothing).
    private static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !common.contains($0) }
    }
    private static let common: Set<String> = [
        "para", "como", "mais", "isso", "isto", "esta", "este", "essa", "esse", "fazer", "sobre", "entre",
        "depois", "antes", "quando", "pelo", "pela", "tudo", "cada", "nota", "notas", "tarefa", "tarefas",
        "ainda", "muito", "outra", "outro", "seus", "suas", "sera", "deve", "precisa", "preciso", "algum", "alguma",
    ]

    private static func numbers(_ text: String) -> [String] {
        text.split { !$0.isNumber }.map(String.init)
    }
}
