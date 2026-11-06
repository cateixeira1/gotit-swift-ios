import Foundation

public enum DocumentValidator {
    public static func validate(_ document: CanvasDocument) throws {
        guard document.revision >= 0,
              document.createdAt.timeIntervalSinceReferenceDate.isFinite,
              document.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DocumentError.invalid("Invalid document metadata")
        }
        try validate(style: document.defaultStyle)
        guard Set(document.blocks.map(\.id)).count == document.blocks.count else {
            throw DocumentError.invalid("Duplicate block ID")
        }
        let byID = Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.id, $0) })
        let hashes = Set(document.assets.map(\.hash))
        guard hashes.count == document.assets.count else { throw DocumentError.invalid("Duplicate asset hash") }
        for asset in document.assets {
            try validate(hash: asset.hash, mediaType: asset.mediaType, byteCount: asset.byteCount)
            guard Set(asset.derivatives.map(\.role)).count == asset.derivatives.count else {
                throw DocumentError.invalid("Duplicate derivative role")
            }
            for derivative in asset.derivatives {
                guard !derivative.role.isEmpty else { throw DocumentError.invalid("Empty derivative role") }
                try validate(hash: derivative.hash, mediaType: derivative.mediaType, byteCount: derivative.byteCount)
            }
        }
        var orders: [UUID?: Set<Int>] = [:]
        var dependencyCounts: [UUID: Int] = [:]
        var dependents: [UUID: [UUID]] = [:]
        for block in document.blocks {
            guard block.order >= 0, orders[block.parentID, default: []].insert(block.order).inserted else {
                throw DocumentError.invalid("Sibling orders must be unique and nonnegative")
            }
            if let parent = block.parentID {
                guard let parentBlock = byID[parent], case .container = parentBlock.content else {
                    throw DocumentError.invalid("Parent must be an existing container")
                }
            }
            let frame = block.layout.frame
            guard [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width >= 0, frame.height >= 0 else { throw DocumentError.invalid("Invalid frame") }
            if block.layout.mode == .anchored {
                guard let anchor = block.layout.anchorID, byID[anchor] != nil else {
                    throw DocumentError.invalid("Anchored layout requires an existing anchor")
                }
            } else if block.layout.anchorID != nil {
                throw DocumentError.invalid("Only anchored layout can have an anchor")
            }
            // Parent and anchor dependencies form one DAG; iterative traversal avoids stack overflow.
            let dependencies = Set([block.parentID, block.layout.anchorID].compactMap { $0 })
            dependencyCounts[block.id] = dependencies.count
            for dependency in dependencies { dependents[dependency, default: []].append(block.id) }
            try validate(style: block.style)
            switch block.content {
            case .text(let text): for run in text.runs { try validate(style: run.style) }
            case .shape(let shape):
                guard shape.lineWidth.isFinite, shape.lineWidth >= 0 else { throw DocumentError.invalid("Invalid line width") }
                try validate(color: shape.stroke)
                if let fill = shape.fill { try validate(color: fill) }
            default: break
            }
            if let hash = block.content.assetHash, !hashes.contains(hash) {
                throw DocumentError.invalid("Block references an unregistered asset")
            }
        }
        var ready = dependencyCounts.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let id = ready.popLast() {
            visited += 1
            for dependent in dependents[id, default: []] {
                dependencyCounts[dependent, default: 0] -= 1
                if dependencyCounts[dependent] == 0 { ready.append(dependent) }
            }
        }
        guard visited == document.blocks.count else { throw DocumentError.invalid("Parent/anchor cycle") }
        guard Set(document.relations.map(\.id)).count == document.relations.count else {
            throw DocumentError.invalid("Duplicate relation ID")
        }
        for relation in document.relations {
            guard byID[relation.sourceID] != nil, byID[relation.targetID] != nil,
                  relation.sourceID != relation.targetID else { throw DocumentError.invalid("Invalid relation endpoints") }
        }
    }

    private static func validate(style: BlockStyle) throws {
        if let size = style.fontSize, !size.isFinite || size <= 0 { throw DocumentError.invalid("Invalid font size") }
        if let foreground = style.foreground { try validate(color: foreground) }
        if let background = style.background { try validate(color: background) }
    }

    private static func validate(color: String) throws {
        let bytes = Array(color.utf8)
        guard (bytes.count == 7 || bytes.count == 9), bytes.first == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw DocumentError.invalid("Colors must be #RRGGBB or #RRGGBBAA")
        }
    }

    private static func validate(hash: String, mediaType: String, byteCount: Int64) throws {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !mediaType.isEmpty, byteCount >= 0 else { throw DocumentError.invalid("Invalid asset metadata") }
    }
}
