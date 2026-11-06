import Foundation
import GotItDomain

public enum CanvasTransforms {
    /// Resizes a node and its nested contents as one undoable batch.
    public static func resize(_ id: UUID, width: Double, height: Double, in document: CanvasDocument) throws -> [DocumentCommand] {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              var root = document.blocks.first(where: { $0.id == id }),
              root.layout.frame.width > 0, root.layout.frame.height > 0 else { throw DocumentError.invalid("Invalid resize") }
        let sx = width / root.layout.frame.width, sy = height / root.layout.frame.height
        root.layout.frame.width = width; root.layout.frame.height = height
        var commands: [DocumentCommand] = [.replaceBlock(root)]
        let children = Dictionary(grouping: document.blocks, by: \.parentID)
        var pending = [id]
        var visited: Set<UUID> = [id]
        while let parent = pending.popLast() {
            for var child in children[parent, default: []] where visited.insert(child.id).inserted {
                child.layout.frame.x *= sx; child.layout.frame.y *= sy
                child.layout.frame.width *= sx; child.layout.frame.height *= sy
                commands.append(.replaceBlock(child)); pending.append(child.id)
            }
        }
        return commands
    }
}
