import Testing
import Foundation
import GotItDomain
@testable import GotItCanvas

@Test func aStickyNoteIsYellowPaperWithATextInside() throws {
    let commands = Stickers.stickyNote(at: .init(x: 40, y: 80), order: 0)
    let document = try CommandEngine.applying(commands, to: CanvasDocument(title: "N"))
    let paper = try #require(document.blocks.first { $0.parentID == nil })
    guard case .shape(let shape) = paper.content else { Issue.record("Expected a shape"); return }
    #expect(shape.kind == .stickyNote)
    #expect(StickyNoteColor(hex: shape.fill) == .yellow)
    let text = try #require(document.blocks.first { $0.parentID == paper.id })
    guard case .text(let rich) = text.content else { Issue.record("Expected text"); return }
    #expect(rich.plainText.isEmpty)
    #expect(text.style.fontName == Stickers.stickyNoteFont)
    // The text box sits inside the paper, below the glued strip.
    #expect(text.layout.frame.y > 20); #expect(text.layout.frame.x + text.layout.frame.width < paper.layout.frame.width)
}

@Test func stickyNotesComeInFiveColours() throws {
    #expect(StickyNoteColor.allCases.count == 5)
    #expect(StickyNoteColor.allCases.first == .yellow)
    #expect(Set(StickyNoteColor.allCases.map(\.hex)).count == 5)
    let document = try CommandEngine.applying(Stickers.stickyNote(at: .init(x: 0, y: 0), order: 0), to: CanvasDocument(title: "N"))
    let paper = try #require(document.blocks.first { $0.parentID == nil })
    let pink = try Stickers.settingColor(.pink, of: paper)
    let changed = try CommandEngine.applying([.replaceBlock(pink)], to: document)
    guard case .shape(let shape) = changed.blocks.first(where: { $0.id == paper.id })?.content else { Issue.record("Expected a shape"); return }
    #expect(StickyNoteColor(hex: shape.fill) == .pink)
}

@Test func aCalendarShowsTodayAndCanShowAnotherDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    // 01:30 on 8 Nov in São Paulo: the local day, not the UTC one, is what the sticker shows.
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 1, minute: 30)))
    let commands = Stickers.calendar(at: .init(x: 40, y: 80), day: now, calendar: calendar, order: 0)
    let document = try CommandEngine.applying(commands, to: CanvasDocument(title: "C"))
    let block = try #require(document.blocks.first)
    guard case .shape(let shape) = block.content else { Issue.record("Expected a shape"); return }
    #expect(shape.kind == .calendar); #expect(shape.date == "2026-11-08")
    #expect(!block.content.allowsChildren)
    #expect(CanvasTransforms.keepsAspectRatio(block.content))
    let christmas = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 25)))
    let changed = try Stickers.settingDay(christmas, of: block, calendar: calendar)
    guard case .shape(let moved) = changed.content else { Issue.record("Expected a shape"); return }
    #expect(moved.date == "2026-12-25")
    let parsed = try #require(Stickers.day(from: moved.date, calendar: calendar))
    #expect(Stickers.dayString(parsed, calendar: calendar) == "2026-12-25")
    #expect(Stickers.day(from: "2026-02-30", calendar: calendar) == nil)
    #expect(Stickers.day(from: "amanhã", calendar: calendar) == nil)
}

@Test func shapesSavedBeforeVerticesAndDatesStillLoad() throws {
    let old = ##"{"kind":"triangle","stroke":"#000000","lineWidth":1}"##
    let shape = try JSONDecoder().decode(Shape.self, from: Data(old.utf8))
    #expect(shape.vertices == nil); #expect(shape.date == nil)
    #expect(shape.triangleCorners == [.init(x: 0.5, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
}
