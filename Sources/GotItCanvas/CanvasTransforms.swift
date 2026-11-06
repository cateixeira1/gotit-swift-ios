import Foundation
import GotItDomain

public enum CanvasTransforms {
    /// Resizes a node and its nested contents as one undoable batch.
    public static func resize(_ id: UUID, width: Double, height: Double, in document: CanvasDocument) throws -> [DocumentCommand] {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              var root = document.blocks.first(where: { $0.id == id }),
              root.layout.frame.width > 0, root.layout.frame.height > 0 else { throw DocumentError.invalid("Invalid resize") }
        let sx = width / root.layout.frame.width, sy = height / root.layout.frame.height
        if case .table(let table) = root.content {
            // Grid sizes have minimums, so the frame follows the scaled grid exactly.
            let scaled = table.scaled(toWidth: width, height: height)
            root.content = .table(scaled)
            root.layout.frame.width = scaled.width; root.layout.frame.height = scaled.height
            return [.replaceBlock(root)]
        }
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

public extension CanvasTransforms {
    /// Crops an image by dragging one corner, as in Keynote/Word: the edges under that corner
    /// move by (dx, dy) in the object's own axes, the frame shrinks or grows with them, and the
    /// pixels that stay visible do not move or rescale. Dragging outward reveals previously
    /// cropped content, never beyond the original image. A crop that ends up covering the whole
    /// image is stored as `nil`.
    static func cropByDraggingCorner(_ block: CanvasBlock, left: Bool, top: Bool, dx: Double, dy: Double,
                                     minimumSize: Double = 24) throws -> CanvasBlock {
        switch block.content { case .image, .sticker: break; default: throw DocumentError.invalid("Only images can be cropped") }
        guard dx.isFinite, dy.isFinite, minimumSize > 0 else { throw DocumentError.invalid("Invalid crop drag") }
        let frame = block.layout.frame
        let crop = block.effectivePresentation.imageCrop ?? LogicalRect(x: 0, y: 0, width: 1, height: 1)
        guard frame.width > 0, frame.height > 0, crop.width > 0, crop.height > 0 else { throw DocumentError.invalid("Invalid crop state") }

        // One axis: the visible window [start, end] over an image of `full` points.
        func axis(origin: Double, size: Double, cropStart: Double, cropSize: Double, moveStart: Bool, delta: Double)
            -> (origin: Double, size: Double, cropStart: Double, cropSize: Double) {
            let full = size / cropSize
            let imageOrigin = origin - cropStart * full
            var start = cropStart * full, end = (cropStart + cropSize) * full
            let minimum = min(minimumSize, full)
            if moveStart { start = min(max(0, start + delta), end - minimum) }
            else { end = max(min(full, end + delta), start + minimum) }
            return (imageOrigin + start, end - start, start / full, (end - start) / full)
        }
        let h = axis(origin: frame.x, size: frame.width, cropStart: crop.x, cropSize: crop.width, moveStart: left, delta: dx)
        let v = axis(origin: frame.y, size: frame.height, cropStart: crop.y, cropSize: crop.height, moveStart: top, delta: dy)

        var result = block
        result.layout.frame = LogicalRect(x: h.origin, y: v.origin, width: h.size, height: v.size)
        var presentation = block.effectivePresentation
        let epsilon = 1e-9
        let next = LogicalRect(x: max(0, h.cropStart), y: max(0, v.cropStart),
                               width: min(1 - max(0, h.cropStart), h.cropSize), height: min(1 - max(0, v.cropStart), v.cropSize))
        presentation.imageCrop = next.x < epsilon && next.y < epsilon && next.width > 1 - epsilon && next.height > 1 - epsilon ? nil : next
        result.presentation = presentation
        return result
    }
}
