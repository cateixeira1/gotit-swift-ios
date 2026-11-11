import Foundation

/// Page order is the order in CanvasDocument.pages. All pages share the note's canvas settings.
public struct CanvasPage: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var textFlowID: UUID?
    public init(id: UUID = UUID(), title: String, textFlowID: UUID? = nil) { self.id = id; self.title = title; self.textFlowID = textFlowID }
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

    /// Assigns newly inserted roots to a page without colliding with other pages' global root order,
    /// and puts them on top of what is already on that page. An object moved to another page also
    /// lands on top there.
    func commands(_ commands: [DocumentCommand], on pageID: UUID) throws -> [DocumentCommand] {
        guard pages.contains(where: { $0.id == pageID }) else { throw DocumentError.invalid("Missing page") }
        var order = (blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
        let membership = pageAssignments()
        var tops: [UUID: Int] = [:]
        func top(_ page: UUID) -> Int {
            if let known = tops[page] { return known }
            let value = stackTop(on: page, membership: membership); tops[page] = value; return value
        }
        return commands.map { command in
            switch command {
            case .insertBlock(var block) where block.parentID == nil:
                block.pageID = pageID; block.order = order; order += 1
                if block.isStacked { block.layout.zIndex = top(pageID) + 1; tops[pageID] = block.layout.zIndex }
                return .insertBlock(block)
            case .replaceBlock(var block) where block.parentID == nil && block.isStacked:
                guard let target = block.pageID, let current = membership[block.id], current != target else { return command }
                block.layout.zIndex = top(target) + 1; tops[target] = block.layout.zIndex
                return .replaceBlock(block)
            default: return command
            }
        }
    }

    /// Highest stacking index among the page's objects (the page drawing is not one of them).
    func stackTop(on pageID: UUID, membership: [UUID: UUID]? = nil) -> Int {
        let membership = membership ?? pageAssignments()
        return blocks.filter { $0.parentID == nil && $0.isStacked && membership[$0.id] == pageID }.map(\.layout.zIndex).max() ?? 0
    }

    /// Back-to-front painting order: objects by stacking (index, then insertion), each followed
    /// right away by its children (a post-it's text, a shape's label) in their order.
    func paintOrder() -> [CanvasBlock] {
        var children: [UUID: [CanvasBlock]] = [:]
        for block in blocks { if let parent = block.parentID { children[parent, default: []].append(block) } }
        var result: [CanvasBlock] = [], seen = Set<UUID>()
        func visit(_ block: CanvasBlock) {
            guard seen.insert(block.id).inserted else { return }
            result.append(block)
            for child in (children[block.id] ?? []).sorted(by: { $0.order < $1.order }) { visit(child) }
        }
        for root in blocks.filter({ $0.parentID == nil }).sorted(by: CanvasBlock.stackedBelow) { visit(root) }
        return result
    }

    /// Lowest stacking index among the page's objects.
    func stackBottom(on pageID: UUID) -> Int {
        let membership = pageAssignments()
        return blocks.filter { $0.parentID == nil && $0.isStacked && membership[$0.id] == pageID }.map(\.layout.zIndex).min() ?? 0
    }
}

public extension CanvasBlock {
    /// Takes part in the stacking of objects on the page: everything but the page's drawing,
    /// which always stays above (so the pen draws over everything).
    var isStacked: Bool { if case .drawing = content { false } else { true } }

    /// Front-to-back order on a page: stacking index, then insertion order (older below).
    static func stackedBelow(_ a: CanvasBlock, _ b: CanvasBlock) -> Bool {
        a.layout.zIndex == b.layout.zIndex ? a.order < b.order : a.layout.zIndex < b.layout.zIndex
    }
}
