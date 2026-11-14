import Foundation
import GotItDomain

public struct NoteCardMetadata: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public init(id: UUID, title: String, createdAt: Date) { self.id = id; self.title = title; self.createdAt = createdAt }
}

public struct ChronologyLink: Equatable, Sendable {
    public var sourceCardID: UUID
    public var targetCardID: UUID
}

public enum TeiaEngine {
    public static func addNotes(_ notes: [NoteCardMetadata], to web: CanvasDocument) throws -> [DocumentCommand] {
        guard web.kind == .web else { throw DocumentError.invalid("Expected a Teia") }
        var present = Set(web.blocks.compactMap { block -> UUID? in
            if case .noteReference(let reference) = block.content { reference.documentID } else { nil }
        })
        let ordered = notes.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        var order = (web.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
        var commands: [DocumentCommand] = []
        for note in ordered where present.insert(note.id).inserted {
            guard note.id != web.id else { throw DocumentError.invalid("A Teia cannot reference itself") }
            let frame = LogicalRect(x: 24 + Double(order % 2) * 270, y: 24 + Double(order / 2) * 220, width: 240, height: 190)
            commands.append(.insertBlock(CanvasBlock(order: order, layout: .init(mode: .absolute, frame: frame), content: .noteReference(.init(documentID: note.id)))))
            order += 1
        }
        return commands
    }

    /// Creation chronology is a derived layer, independent of user positioning and manual links.
    public static func chronology(in web: CanvasDocument, metadata: [UUID: NoteCardMetadata]) -> [ChronologyLink] {
        let cards = web.blocks.compactMap { block -> (UUID, NoteCardMetadata)? in
            guard case .noteReference(let ref) = block.content, let note = metadata[ref.documentID] else { return nil }
            return (block.id, note)
        }.sorted { $0.1.createdAt == $1.1.createdAt ? $0.1.id.uuidString < $1.1.id.uuidString : $0.1.createdAt < $1.1.createdAt }
        return cards.indices.dropFirst().map { .init(sourceCardID: cards[$0 - 1].0, targetCardID: cards[$0].0) }
    }
}
