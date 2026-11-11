import Foundation

public enum DocumentError: Error, Equatable, Sendable {
    case invalid(String)
    case missingBlock(UUID)
    case missingDocument(UUID)
    case revisionConflict(expected: Int64, actual: Int64)
    case nothingToUndo
    case nothingToRedo
}

/// The only editing gateway. UI gestures and future AI proposals use the same validation.
public enum DocumentCommand: Codable, Equatable, Sendable {
    case rename(String)
    case setDefaultStyle(BlockStyle)
    case setCanvasSettings(CanvasSettings)
    case appendPage(CanvasPage)
    case insertPage(CanvasPage, after: UUID)
    case removePage(UUID)
    /// Paper of one page (nil: only the note's paper).
    case setPagePaper(UUID, PaperFill?)
    case insertBlock(CanvasBlock)
    case replaceBlock(CanvasBlock)
    case removeSubtree(UUID)
    case registerAsset(Asset)
    case unregisterAsset(String)
    case setRelation(BlockRelation)
    case removeRelation(UUID)
    /// Replaces the note's named-style definitions (overrides of built-ins and custom styles).
    case setNamedStyles([NamedStyle])
}

public enum CommandEngine {
    /// Applies a batch to a value copy; invalid batches leave the caller's value intact.
    public static func applying(_ commands: [DocumentCommand], to original: CanvasDocument) throws -> CanvasDocument {
        guard !commands.isEmpty else { throw DocumentError.invalid("Empty command batch") }
        var document = original
        for command in commands {
            switch command {
            case .rename(let title): document.title = title
            case .setDefaultStyle(let style): document.defaultStyle = style
            case .setCanvasSettings(let settings): document.canvas = settings
            case .appendPage(let page): document.pages.append(page)
            case .insertPage(let page, let previous):
                guard let index = document.pages.firstIndex(where: { $0.id == previous }) else { throw DocumentError.invalid("Missing previous page") }
                document.pages.insert(page, at: index + 1)
            case .setPagePaper(let id, let paper):
                guard let index = document.pages.firstIndex(where: { $0.id == id }) else { throw DocumentError.invalid("Missing page") }
                try paper?.style.validate()
                document.pages[index].paper = paper
            case .removePage(let id):
                guard document.pages.count > 1, !document.blocks.contains(where: { document.pageID(for: $0.id) == id }) else { throw DocumentError.invalid("Page is not empty") }
                document.pages.removeAll { $0.id == id }
            case .insertBlock(let block):
                guard !document.blocks.contains(where: { $0.id == block.id }) else {
                    throw DocumentError.invalid("Duplicate block ID")
                }
                document.blocks.append(block)
            case .replaceBlock(let block):
                guard let index = document.blocks.firstIndex(where: { $0.id == block.id }) else {
                    throw DocumentError.missingBlock(block.id)
                }
                document.blocks[index] = block
            case .removeSubtree(let id):
                guard document.blocks.contains(where: { $0.id == id }) else { throw DocumentError.missingBlock(id) }
                var deleted: Set<UUID> = [id]
                var children: [UUID: [UUID]] = [:]
                for block in document.blocks {
                    if let parent = block.parentID { children[parent, default: []].append(block.id) }
                }
                var pending = [id]
                while let parent = pending.popLast() {
                    for child in children[parent, default: []] where deleted.insert(child).inserted { pending.append(child) }
                }
                document.blocks.removeAll { deleted.contains($0.id) }
                document.relations.removeAll { deleted.contains($0.sourceID) || deleted.contains($0.targetID) }
            case .registerAsset(let asset):
                if let existing = document.assets.first(where: { $0.hash == asset.hash }) {
                    guard existing == asset else { throw DocumentError.invalid("Asset hash already has different metadata") }
                } else { document.assets.append(asset) }
            case .unregisterAsset(let hash):
                guard !document.blocks.contains(where: { $0.content.assetHashes.contains(hash) }), !document.canvas.bandAssetHashes.contains(hash) else {
                    throw DocumentError.invalid("Asset is still in use")
                }
                document.assets.removeAll { $0.hash == hash }
            case .setRelation(let relation):
                document.relations.removeAll { $0.id == relation.id }
                document.relations.append(relation)
            case .removeRelation(let id):
                guard document.relations.contains(where: { $0.id == id }) else {
                    throw DocumentError.invalid("Missing relation")
                }
                document.relations.removeAll { $0.id == id }
            case .setNamedStyles(let styles): document.namedStyles = styles
            }
        }
        try DocumentValidator.validate(document)
        return document
    }
}
