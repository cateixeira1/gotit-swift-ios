import Foundation
import GotItDomain

/// Where a new object goes on a page: the first free spot, reading from the top-left corner of
/// the page's content (the margin where the first block sits) row by row, that overlaps no other
/// object. Empty text boxes and the page's drawing layer do not count as occupied. When nothing
/// is free the object goes to the corner anyway (the user asked for it on a full page).
public enum Placement {
    public static let margin = 24.0
    public static let gap = 8.0

    /// Objects that take room on the page (not empty text boxes, not the drawing layer).
    static func obstacles(on page: CanvasDocument, except excluded: Set<UUID> = []) -> [LogicalRect] {
        let frames = (try? CanvasLayoutEngine.frames(in: page)) ?? [:]
        return page.blocks.compactMap { block in
            guard block.parentID == nil, !excluded.contains(block.id) else { return nil }
            let frame = frames[block.id] ?? block.layout.frame
            switch block.content {
            case .drawing: return nil
            case .text(let rich) where rich.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return nil
            default: return frame
            }
        }
    }

    /// Where an object that belongs to another one goes (a transcription next to its audio):
    /// to its right if there is room on the page and nothing is in the way, else to its left,
    /// else below, else above. With no free side it goes below (or as near as the page allows).
    public static func beside(_ anchor: LogicalRect, width: Double, height: Double, on page: CanvasDocument, except excluded: Set<UUID> = []) -> CanvasPoint {
        let obstacles = obstacles(on: page, except: excluded)
        let size = page.canvas.size
        let gap = 12.0
        let candidates = [
            CanvasPoint(x: anchor.x + anchor.width + gap, y: anchor.y),
            CanvasPoint(x: anchor.x - gap - width, y: anchor.y),
            CanvasPoint(x: anchor.x, y: anchor.y + anchor.height + gap),
            CanvasPoint(x: anchor.x, y: anchor.y - gap - height),
        ]
        func onPage(_ p: CanvasPoint) -> Bool { p.x >= 8 && p.y >= 8 && p.x + width <= size.width - 8 && p.y + height <= size.height - 8 }
        for candidate in candidates where onPage(candidate) {
            let rect = LogicalRect(x: candidate.x, y: candidate.y, width: width, height: height)
            if !obstacles.contains(where: { overlaps($0, rect) }) { return candidate }
        }
        if let fits = candidates.first(where: onPage) { return fits }
        return CanvasPoint(x: min(max(8, anchor.x), max(8, size.width - width - 8)), y: min(anchor.y + anchor.height + gap, max(8, size.height - height - 8)))
    }

    public static func firstFreeSpot(width: Double, height: Double, on page: CanvasDocument) -> CanvasPoint {
        // The page's text area: where its first block sits (24 pt in older notes, Word margins in new ones).
        let area = page.canvas.textArea
        let origin = CanvasPoint(x: area.x, y: area.y)
        let obstacles = obstacles(on: page)
        let rows = ([origin.y] + obstacles.map { $0.y + $0.height + gap }).filter { $0 >= origin.y }.sorted()
        let columns = ([origin.x] + obstacles.map { $0.x + $0.width + gap }).filter { $0 >= origin.x }.sorted()
        for y in rows where y + height <= area.y + area.height + 1e-9 {
            for x in columns where x + width <= area.x + area.width + 1e-9 {
                let candidate = LogicalRect(x: x, y: y, width: width, height: height)
                if !obstacles.contains(where: { overlaps($0, candidate) }) { return .init(x: x, y: y) }
            }
        }
        return origin
    }

    private static func overlaps(_ a: LogicalRect, _ b: LogicalRect) -> Bool {
        a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap && b.y < a.y + a.height + gap
    }
}
