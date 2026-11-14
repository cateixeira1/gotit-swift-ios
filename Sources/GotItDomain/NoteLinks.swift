import Foundation

/// Links from one note to another. A link names the other note by its identifier, never by its
/// title or folder, so it keeps working when the note is renamed or moved. Teia cards count as
/// references too (a Teia "cites" the notes on it).
public enum NoteLinks {
    public static let prefix = "gotit://nota/"

    public static func url(for id: UUID) -> String { prefix + id.uuidString }

    /// The note a link points to, if it is a link to a note.
    public static func target(of link: String?) -> UUID? {
        guard let link, link.lowercased().hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(link.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Every other note this one points to: links in its text and table cells, and Teia cards.
    public static func targets(in document: CanvasDocument) -> Set<UUID> {
        var found: Set<UUID> = []
        func scan(_ rich: RichText) { for run in rich.runs { if let id = target(of: run.style.link) { found.insert(id) } } }
        for block in document.blocks {
            switch block.content {
            case .text(let rich): scan(rich)
            case .table(let table): for row in table.cells { for cell in row { scan(cell.text) } }
            case .noteReference(let reference): found.insert(reference.documentID)
            default: break
            }
        }
        found.remove(document.id)
        return found
    }
}
