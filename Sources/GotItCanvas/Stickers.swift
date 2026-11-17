import Foundation
import GotItDomain

/// Paper colours of a sticky note. Yellow is the default.
public enum StickyNoteColor: String, CaseIterable, Sendable {
    case yellow, pink, blue, green, orange

    public var hex: String {
        switch self {
        case .yellow: "#FFF27A"
        case .pink: "#FFB8D2"
        case .blue: "#A9DDF7"
        case .green: "#C6EBA1"
        case .orange: "#FFC98A"
        }
    }
    public var title: String {
        switch self {
        case .yellow: "Amarelo"
        case .pink: "Rosa"
        case .blue: "Azul"
        case .green: "Verde"
        case .orange: "Laranja"
        }
    }
    /// The colour a paper fill stands for, if it is one of these.
    public init?(hex: String?) {
        guard let hex else { return nil }
        let wanted = hex.uppercased().prefix(7)
        guard let match = Self.allCases.first(where: { $0.hex.uppercased() == wanted }) else { return nil }
        self = match
    }
}

/// Built-in stickers that are drawn, not pictures: a sticky note with a text inside and a desk
/// calendar showing a day. Each insert is one undoable operation.
public enum Stickers {
    public static let stickyNoteSide = 200.0
    public static let calendarSize = (width: 132.0, height: 148.0)
    /// Handwriting-like face for the note's text; the system font is used where it is missing.
    public static let stickyNoteFont = "Noteworthy-Bold"

    /// Paper plus an empty text box, which starts below the glued strip at the top.
    public static func stickyNote(at origin: CanvasPoint, color: StickyNoteColor = .yellow, order: Int) -> [DocumentCommand] {
        let side = stickyNoteSide
        let paper = CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(x: origin.x, y: origin.y, width: side, height: side)),
                                content: .shape(.init(kind: .stickyNote, stroke: "#00000000", fill: color.hex, lineWidth: 0)),
                                presentation: .init(wrap: .none))
        let text = CanvasBlock(parentID: paper.id, layout: .init(mode: .absolute, frame: .init(x: 14, y: 30, width: side - 28, height: side - 44)),
                               style: .init(fontName: stickyNoteFont, fontSize: 20, foreground: "#2B2B2B"),
                               content: .text(RichText("")))
        return [.insertBlock(paper), .insertBlock(text)]
    }

    /// A transcription card: a header with an icon, and the text as its child (so it moves with it).
    public static func transcript(at origin: CanvasPoint, width: Double, height: Double, text: String, order: Int) -> [DocumentCommand] {
        let card = CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(x: origin.x, y: origin.y, width: width, height: height)),
                               content: .shape(.init(kind: .transcript, stroke: "#C7CFDB", fill: "#F5F7FB", lineWidth: 1)),
                               presentation: .init(wrap: .none))
        let body = CanvasBlock(parentID: card.id, layout: .init(mode: .absolute, frame: .init(x: transcriptInset, y: transcriptHeader, width: width - 2 * transcriptInset, height: height - transcriptHeader - transcriptInset)),
                               style: .init(fontSize: transcriptFontSize, foreground: "#1F2937", alignment: .leading),
                               content: .text(RichText(text)))
        return [.insertBlock(card), .insertBlock(body)]
    }
    public static let transcriptHeader = 34.0
    public static let transcriptInset = 12.0
    public static let transcriptFontSize = 14.0
    /// Height of a new audio player; a folded card is a square a little wider than that.
    public static let audioHeight = 60.0
    public static let foldMargin = 8.0

    public static func isFolded(_ block: CanvasBlock) -> Bool {
        if case .shape(let shape) = block.content, shape.kind == .transcript, shape.folded != nil { return true }
        return false
    }

    /// Blocks hidden inside folded cards (the text of a folded transcription, and its children).
    public static func foldedContent(in document: CanvasDocument) -> Set<UUID> {
        let folded = document.blocks.filter(isFolded).map(\.id)
        guard !folded.isEmpty else { return [] }
        let children = Dictionary(grouping: document.blocks, by: \.parentID)
        var hidden: Set<UUID> = [], pending = folded
        while let parent = pending.popLast() {
            for child in children[parent, default: []] where hidden.insert(child.id).inserted { pending.append(child.id) }
        }
        return hidden
    }

    /// The audio player the card belongs to: the nearest one on the page, if it is close (the card
    /// is placed right beside it). Cards do not store their audio.
    public static func audio(near card: CanvasBlock, in document: CanvasDocument) -> LogicalRect? {
        let frames = (try? CanvasLayoutEngine.frames(in: document)) ?? [:]
        let box = frames[card.id] ?? card.layout.frame
        func gap(_ a: LogicalRect) -> Double {
            let dx = max(0, max(a.x - (box.x + box.width), box.x - (a.x + a.width)))
            let dy = max(0, max(a.y - (box.y + box.height), box.y - (a.y + a.height)))
            return (dx * dx + dy * dy).squareRoot()
        }
        return document.blocks.compactMap { block -> LogicalRect? in
            guard block.parentID == nil, case .audio = block.content else { return nil }
            return frames[block.id] ?? block.layout.frame
        }.filter { gap($0) <= 48 }.min { gap($0) < gap($1) }
    }

    /// Folds an open transcription card to a square a little wider than its audio's height, on
    /// the side that faces the audio (beside it: centred on the player).
    public static func folding(_ card: CanvasBlock, audio: LogicalRect?) throws -> CanvasBlock {
        guard case .shape(var shape) = card.content, shape.kind == .transcript, shape.folded == nil else { throw DocumentError.invalid("Not an open transcription card") }
        let open = card.layout.frame
        let side = (audio?.height ?? audioHeight) + foldMargin
        var square = LogicalRect(x: open.x, y: open.y, width: side, height: side)
        if let audio {
            if open.x + open.width / 2 < audio.x + audio.width / 2 { square.x = open.x + open.width - side }
            let besideIt = open.y < audio.y + audio.height && audio.y < open.y + open.height
            if besideIt { square.y = audio.y + audio.height / 2 - side / 2 }
            else if open.y + open.height / 2 < audio.y + audio.height / 2 { square.y = open.y + open.height - side }
        }
        shape.folded = FoldedCard(expanded: open, folded: square)
        var changed = card
        changed.content = .shape(shape)
        changed.layout.frame = square
        return changed
    }

    /// Opens a folded card at its open size, moved as far as the square was moved, kept on the page.
    public static func unfolding(_ card: CanvasBlock, page: CanvasSize) throws -> CanvasBlock {
        guard case .shape(var shape) = card.content, shape.kind == .transcript, let fold = shape.folded else { throw DocumentError.invalid("Not a folded transcription card") }
        let now = card.layout.frame
        var open = fold.expanded
        // The same shift keeps the edge it was folded towards (left, right, top or bottom) in place.
        open.x += now.x - fold.folded.x; open.y += now.y - fold.folded.y
        open.x = min(max(0, open.x), max(0, page.width - open.width))
        open.y = min(max(0, open.y), max(0, page.height - open.height))
        shape.folded = nil
        var changed = card
        changed.content = .shape(shape)
        changed.layout.frame = open
        return changed
    }

    /// A calendar page showing `day` (today, unless the caller says otherwise).
    public static func calendar(at origin: CanvasPoint, day: Date = Date(), calendar: Calendar = .current, order: Int) -> [DocumentCommand] {
        let block = CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(x: origin.x, y: origin.y, width: calendarSize.width, height: calendarSize.height)),
                                content: .shape(.init(kind: .calendar, stroke: "#00000000", fill: "#FFFFFF", lineWidth: 0, date: dayString(day, calendar: calendar))),
                                presentation: .init(wrap: .none))
        return [.insertBlock(block)]
    }

    /// The same calendar sticker showing another day.
    public static func settingDay(_ day: Date, of block: CanvasBlock, calendar: Calendar = .current) throws -> CanvasBlock {
        guard case .shape(var shape) = block.content, shape.kind == .calendar else { throw DocumentError.invalid("Not a calendar sticker") }
        shape.date = dayString(day, calendar: calendar)
        var changed = block
        changed.content = .shape(shape)
        return changed
    }

    /// The same sticky note on another paper colour.
    public static func settingColor(_ color: StickyNoteColor, of block: CanvasBlock) throws -> CanvasBlock {
        guard case .shape(var shape) = block.content, shape.kind == .stickyNote else { throw DocumentError.invalid("Not a sticky note") }
        shape.fill = color.hex
        var changed = block
        changed.content = .shape(shape)
        return changed
    }

    /// "yyyy-MM-dd" in the given calendar (the day as the user sees it, not in UTC).
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The day a sticker shows, at noon (so time zone changes never move it to another day).
    public static func day(from text: String?, calendar: Calendar = .current) -> Date? {
        guard let text else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        components.calendar = calendar
        guard let date = calendar.date(from: components), dayString(date, calendar: calendar) == text else { return nil }
        return date
    }
}
