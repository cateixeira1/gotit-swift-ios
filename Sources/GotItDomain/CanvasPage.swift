import Foundation

/// Page order is the order in CanvasDocument.pages. All pages share the note's canvas settings.
public struct CanvasPage: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public init(id: UUID = UUID(), title: String) { self.id = id; self.title = title }
}

public extension CanvasDocument {
    func pageID(for blockID: UUID) -> UUID? { pageAssignments()[blockID] }

    /// Resolves inherited membership once, iteratively, including deeply nested documents.
    func pageAssignments() -> [UUID: UUID] {
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [UUID: UUID] = [:]
        var invalid: Set<UUID> = []
        for block in blocks where resolved[block.id] == nil && !invalid.contains(block.id) {
            var chain: [UUID] = []
            var visited: Set<UUID> = []
            var current: UUID? = block.id
            var page: UUID?
            while let id = current {
                if let known = resolved[id] { page = known; break }
                guard !invalid.contains(id), visited.insert(id).inserted, let item = byID[id] else { break }
                chain.append(id)
                if let explicit = item.pageID { page = explicit; break }
                if item.parentID == nil { page = pages.first?.id; break }
                current = item.parentID
            }
            if let page { for id in chain { resolved[id] = page } }
            else { invalid.formUnion(chain) }
        }
        return resolved
    }

    /// A read projection; edits are applied to the complete document by the host.
    func pageDocument(_ pageID: UUID) throws -> CanvasDocument {
        guard let page = pages.first(where: { $0.id == pageID }) else { throw DocumentError.invalid("Missing page") }
        var result = self
        let membership = pageAssignments()
        result.blocks = blocks.filter { membership[$0.id] == pageID }
        let ids = Set(result.blocks.map(\.id))
        result.relations = relations.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) }
        result.pages = [page]
        return result
    }

    /// Assigns newly inserted roots to a page without colliding with other pages' global root order.
    func commands(_ commands: [DocumentCommand], on pageID: UUID) throws -> [DocumentCommand] {
        guard pages.contains(where: { $0.id == pageID }) else { throw DocumentError.invalid("Missing page") }
        var order = (blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
        return commands.map { command in
            guard case .insertBlock(var block) = command, block.parentID == nil else { return command }
            block.pageID = pageID; block.order = order; order += 1
            return .insertBlock(block)
        }
    }
}
