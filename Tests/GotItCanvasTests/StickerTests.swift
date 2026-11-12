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

// MARK: Folding a transcription card

private func cardBesideAudio(cardX: Double, cardY: Double = 100, audioX: Double = 40) throws -> (CanvasDocument, CanvasBlock, LogicalRect) {
    let audioFrame = LogicalRect(x: audioX, y: 100, width: 200, height: 60)
    let audio = CanvasBlock(order: 0, layout: .init(mode: .absolute, frame: audioFrame), content: .audio(AssetReference(hash: String(repeating: "a", count: 64))))
    var document = try CommandEngine.applying([.registerAsset(Asset(hash: String(repeating: "a", count: 64), mediaType: "audio/mp4", byteCount: 1)), .insertBlock(audio)],
                                              to: CanvasDocument(title: "A"))
    document = try CommandEngine.applying(Stickers.transcript(at: .init(x: cardX, y: cardY), width: 240, height: 220, text: "Olá", order: 1), to: document)
    let card = try #require(document.blocks.first { if case .shape = $0.content { return true }; return false })
    return (document, card, audioFrame)
}

@Test func aTranscriptionCardFoldsToASquareBesideItsAudio() throws {
    let (document, card, audio) = try cardBesideAudio(cardX: 252)
    #expect(Stickers.audio(near: card, in: document) == audio)
    let folded = try Stickers.folding(card, audio: audio)
    #expect(Stickers.isFolded(folded))
    // A little wider than the player is tall, centred on it, on the side facing it.
    #expect(folded.layout.frame == LogicalRect(x: 252, y: 96, width: 68, height: 68))
    let changed = try CommandEngine.applying([.replaceBlock(folded)], to: document)
    let text = try #require(changed.blocks.first { $0.parentID == card.id })
    #expect(Stickers.foldedContent(in: changed) == [text.id])
    // Its text is untouched, and opening it gives the card back as it was.
    #expect(text == document.blocks.first { $0.id == text.id })
    let opened = try Stickers.unfolding(folded, page: changed.canvas.size)
    #expect(opened.layout.frame == card.layout.frame)
    #expect(!Stickers.isFolded(opened))
    #expect(Stickers.foldedContent(in: try CommandEngine.applying([.replaceBlock(opened)], to: changed)).isEmpty)
}

@Test func aCardLeftOfItsAudioFoldsTowardsIt() throws {
    let (_, card, audio) = try cardBesideAudio(cardX: 48, audioX: 300)
    let folded = try Stickers.folding(card, audio: audio)
    // The right edge (towards the audio) stays put.
    #expect(folded.layout.frame.x + folded.layout.frame.width == card.layout.frame.x + card.layout.frame.width)
    // Moved while folded: it opens where it now is, still growing away from the audio side.
    var moved = folded
    moved.layout.frame.x += 30; moved.layout.frame.y += 40
    let opened = try Stickers.unfolding(moved, page: CanvasSize.a4)
    #expect(opened.layout.frame == LogicalRect(x: card.layout.frame.x + 30, y: card.layout.frame.y + 40, width: 240, height: 220))
}

@Test func aFoldedCardOpensInsideThePage() throws {
    let (_, card, _) = try cardBesideAudio(cardX: 300)
    var folded = try Stickers.folding(card, audio: nil)
    #expect(folded.layout.frame.width == Stickers.audioHeight + Stickers.foldMargin)
    folded.layout.frame.x = CanvasSize.a4.width - 70
    let opened = try Stickers.unfolding(folded, page: CanvasSize.a4)
    #expect(opened.layout.frame.x + opened.layout.frame.width <= CanvasSize.a4.width + 1e-9)
    #expect(throws: DocumentError.self) { try Stickers.folding(folded, audio: nil) }
    #expect(throws: DocumentError.self) { try Stickers.unfolding(card, page: CanvasSize.a4) }
}

@Test func aFoldedCardDecodesFromOlderNotesAsOpen() throws {
    let json = ##"{"kind":"transcript","stroke":"#C7CFDB","fill":"#F5F7FB","lineWidth":1}"##
    let shape = try JSONDecoder().decode(Shape.self, from: Data(json.utf8))
    #expect(shape.folded == nil)
}
