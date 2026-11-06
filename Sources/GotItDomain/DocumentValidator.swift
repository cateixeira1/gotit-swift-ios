import Foundation

public enum DocumentValidator {
    public static func validate(_ document: CanvasDocument) throws {
        guard document.revision >= 0,
              document.createdAt.timeIntervalSinceReferenceDate.isFinite,
              document.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DocumentError.invalid("Invalid document metadata")
        }
        try validate(style: document.defaultStyle)
        try document.canvas.size.validate()
        guard document.canvas.pixelsPerInch.isFinite, document.canvas.pixelsPerInch > 0 else {
            throw DocumentError.invalid("Invalid document pixel density")
        }
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
        var previousFlow: [UUID: UUID] = [:]
        for siblings in Dictionary(grouping: document.blocks, by: \.parentID).values {
            let flow = siblings.filter { $0.layout.mode == .flow }.sorted { $0.order < $1.order }
            for index in flow.indices.dropFirst() { previousFlow[flow[index].id] = flow[index - 1].id }
        }
        var orders: [UUID?: Set<Int>] = [:]
        var dependencyCounts: [UUID: Int] = [:]
        var dependents: [UUID: [UUID]] = [:]
        for block in document.blocks {
            guard block.order >= 0, orders[block.parentID, default: []].insert(block.order).inserted else {
                throw DocumentError.invalid("Sibling orders must be unique and nonnegative")
            }
            if let parent = block.parentID {
                guard let parentBlock = byID[parent], parentBlock.content.allowsChildren else {
                    throw DocumentError.invalid("Parent must be an existing container or closed shape")
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
            let dependencies = Set([block.parentID, block.layout.anchorID, previousFlow[block.id]].compactMap { $0 })
            dependencyCounts[block.id] = dependencies.count
            for dependency in dependencies { dependents[dependency, default: []].append(block.id) }
            try validate(style: block.style)
            let presentation = block.effectivePresentation
            guard presentation.textPadding.isFinite, presentation.textPadding >= 0,
                  presentation.rotationRadians.isFinite else { throw DocumentError.invalid("Invalid object presentation") }
            if let crop = presentation.imageCrop {
                guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite),
                      crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
                      crop.x + crop.width <= 1, crop.y + crop.height <= 1 else {
                    throw DocumentError.invalid("Crop must fit normalized image bounds")
                }
                switch block.content {
                case .image, .sticker: break
                default: throw DocumentError.invalid("Crop requires an image or sticker")
                }
            }
            switch block.content {
            case .ink(let ink): try validate(ink: ink)
            case .noteReference(let reference):
                guard document.kind == .web, reference.documentID != document.id else {
                    throw DocumentError.invalid("Note cards belong to Teias and cannot reference themselves")
                }
            case .text(let text): for run in text.runs { try validate(style: run.style) }
            case .shape(let shape):
                if let ink = shape.originalStroke { try validate(ink: ink) }
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
            if let ink = relation.originalStroke { try validate(ink: ink) }
            if let style = relation.style {
                try validate(color: style.color)
                guard style.width.isFinite, style.width > 0 else { throw DocumentError.invalid("Invalid connector width") }
            }
            guard byID[relation.sourceID] != nil, byID[relation.targetID] != nil,
                  relation.sourceID != relation.targetID else { throw DocumentError.invalid("Invalid relation endpoints") }
        }
    }

    private static func validate(style: BlockStyle) throws {
        if let paragraph = style.paragraph {
            guard [paragraph.lineSpacing, paragraph.paragraphSpacing, paragraph.headIndent, paragraph.firstLineIndent].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw DocumentError.invalid("Invalid paragraph format")
            }
        }
        if let size = style.fontSize, !size.isFinite || size <= 0 { throw DocumentError.invalid("Invalid font size") }
        if let foreground = style.foreground { try validate(color: foreground) }
        if let background = style.background { try validate(color: background) }
    }

    private static func validate(ink: InkStroke) throws {
        guard ink.points.count >= 2, ink.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              ink.width.isFinite, ink.width > 0 else { throw DocumentError.invalid("Invalid ink stroke") }
        try validate(color: ink.color)
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
