import XCTest
import PencilKit
import GotItDomain
import GotItCanvas
@testable import GotItCanvasUI
@testable import GotItApp

/// Ruled notebook paper, simple notes, folding transcription cards and reading block letters.
@MainActor
final class NotebookAndFoldTests: XCTestCase {
    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        return window
    }

    /// On notebook paper a story's lines are one band tall and its first line sits in a band:
    /// the box's text starts on a band top and the caret ends on the rule.
    func testTextOnNotebookPaperSitsOnTheRules() throws {
        var document = CanvasDocument(title: "Caderno", defaultStyle: .init(fontSize: 18))
        document.canvas.margins = .word
        document.canvas.paper = PaperStyle(kind: .notebook)
        let lines = try XCTUnwrap(document.canvas.ruledLines)
        let area = document.canvas.textArea
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: area.x, y: area.y, width: area.width, height: 44)), content: .text(.init("")))
        block.textFlowID = block.id
        document = try CommandEngine.applying([.insertBlock(block)], to: document)
        block.content = .text(RichText(String(repeating: "Linha de um caderno amarelo. ", count: 40)))
        document = try CommandEngine.applying(TextPagination.reflow(block, in: document, selection: .init(location: 0, length: 0)).commands, to: document)
        // Every paragraph of the stored text has no extra spacing (the rules set it).
        guard case .text(let stored)? = document.blocks.first(where: { $0.id == block.id })?.content else { return XCTFail("No text") }
        XCTAssertTrue(stored.runs.allSatisfy { ($0.style.paragraph?.lineSpacing ?? 0) == 0 })

        let controller = CanvasViewController(configuration: CanvasEditor(document: document, onCommands: { _ in }))
        let window = try show(controller)
        defer { window.isHidden = true }
        let text = try XCTUnwrap(controller.view.descendants(UITextView.self).first { $0.attributedText.length > 100 })
        let style = try XCTUnwrap(text.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.minimumLineHeight, CGFloat(lines.spacing), accuracy: 0.001)
        XCTAssertEqual(style.maximumLineHeight, CGFloat(lines.spacing), accuracy: 0.001)
        // The text starts on a band top.
        let start = Double(text.frame.minY + text.textContainerInset.top)
        XCTAssertEqual(lines.offset(below: start), 0, accuracy: 0.01)
        // The first line's caret ends at the band's bottom (the rule), a few points above at most.
        let caret = text.caretRect(for: text.beginningOfDocument)
        let bottom = Double(text.convert(caret, to: text.superview).maxY)
        let rule = start + lines.spacing
        // (The caret reaches a point or so past the descender.)
        XCTAssertLessThanOrEqual(bottom, rule + 2)
        XCTAssertGreaterThan(bottom, rule - 8, "the letters sit at the bottom of the band, not at its top")
        // The second line is exactly one band lower.
        let secondLine = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: 60))
        let lower = text.caretRect(for: secondLine)
        let step = (lower.maxY - caret.maxY) / CGFloat(lines.spacing)
        XCTAssertEqual(step, step.rounded(), accuracy: 0.05, "lines are whole bands apart")
        XCTAssertGreaterThanOrEqual(step.rounded(), 1)
    }

    /// Large type takes two bands; paragraph spacing becomes whole lines.
    func testLargeTypeTakesWholeBands() {
        let lines = RuledLines(origin: PaperStyle.notebookTop, spacing: PaperStyle.notebookLine)
        let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 12; paragraph.lineSpacing = 6
        let text = NSMutableAttributedString(string: "Título\nCorpo", attributes: [.font: UIFont.systemFont(ofSize: 18), .paragraphStyle: paragraph])
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 32), range: NSRange(location: 0, length: 6))
        XCTAssertTrue(TextBridge.rule(text, lines: lines))
        let title = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let body = text.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(title?.minimumLineHeight ?? 0, CGFloat(2 * lines.spacing), accuracy: 0.001)
        XCTAssertEqual(body?.maximumLineHeight ?? 0, CGFloat(lines.spacing), accuracy: 0.001)
        XCTAssertEqual(body?.lineSpacing, 0)
        XCTAssertEqual(body?.paragraphSpacing ?? 0, CGFloat(lines.spacing), accuracy: 0.001)
        XCTAssertFalse(TextBridge.rule(text, lines: lines), "already on the lines: nothing to change")
    }

    /// A simple note: no drawing (even with the pen chosen) and nothing to insert on the page;
    /// a tap on the page continues the text.
    func testSimpleNoteHoldsTextOnly() throws {
        var document = CanvasDocument(title: "Simples", defaultStyle: .init(fontSize: 18), canvas: .simpleNote())
        let area = document.canvas.textArea
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: area.x, y: area.y, width: area.width, height: 44)), content: .text(.init("Compras")))
        block.textFlowID = block.id
        document = try CommandEngine.applying([.insertBlock(block)], to: document)
        var commands: [[DocumentCommand]] = []
        let controller = CanvasViewController(configuration: CanvasEditor(document: document, tool: .pen, onCommands: { commands.append($0) }))
        let window = try show(controller)
        defer { window.isHidden = true }
        XCTAssertFalse(controller.fingerDraws, "no ink on a simple note")
        let menu = controller.contextMenuInteraction(UIContextMenuInteraction(delegate: controller), configurationForMenuAtLocation: CGPoint(x: 200, y: 400))
        XCTAssertNil(menu)
        let text = try XCTUnwrap(controller.view.descendants(UITextView.self).first { $0.text == "Compras" })
        XCTAssertGreaterThan(text.textContainerInset.top, 4, "its first line moves down to the first band")
    }

    /// A tap on the header folds the transcription card to a square beside its audio and hides
    /// its text; a tap on the square opens it again.
    func testTranscriptionCardFoldsAndOpensWithATap() throws {
        let hash = String(repeating: "d", count: 64)
        let audio = CanvasBlock(order: 0, layout: .init(mode: .absolute, frame: .init(x: 40, y: 60, width: 200, height: 60)), content: .audio(.init(hash: hash)))
        var document = try CommandEngine.applying([.registerAsset(Asset(hash: hash, mediaType: "audio/wav", byteCount: 1)), .insertBlock(audio)], to: CanvasDocument(title: "Áudio"))
        document = try CommandEngine.applying(Stickers.transcript(at: .init(x: 252, y: 60), width: 240, height: 200, text: "Texto transcrito", order: 1), to: document)
        let card = try XCTUnwrap(document.blocks.first { if case .shape = $0.content { return true }; return false })
        var controller: CanvasViewController!
        func editor() -> CanvasEditor {
            CanvasEditor(document: document, onCommands: { commands in
                document = try! CommandEngine.applying(commands, to: document)
                controller.configure(editor())
            })
        }
        controller = CanvasViewController(configuration: editor())
        let window = try show(controller)
        defer { window.isHidden = true }
        XCTAssertNotNil(controller.view.descendants(UITextView.self).first { $0.text == "Texto transcrito" })
        var view = try XCTUnwrap(controller.view.descendants(CanvasObjectView.self).first { $0.id == card.id })
        controller.handleObjectTap(view, at: CGPoint(x: 100, y: 120))
        XCTAssertFalse(document.blocks.contains { Stickers.isFolded($0) }, "a tap on the text area does not fold")
        controller.handleObjectTap(view, at: CGPoint(x: 100, y: 12))
        let folded = try XCTUnwrap(document.blocks.first { $0.id == card.id })
        XCTAssertTrue(Stickers.isFolded(folded))
        XCTAssertEqual(folded.layout.frame.width, 68, accuracy: 0.001)
        XCTAssertEqual(folded.layout.frame.height, 68, accuracy: 0.001)
        XCTAssertNil(controller.view.descendants(UITextView.self).first { $0.text == "Texto transcrito" }, "the text is hidden")
        view = try XCTUnwrap(controller.view.descendants(CanvasObjectView.self).first { $0.id == card.id })
        // The label is set when the square is drawn.
        _ = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.draw(view.bounds) }
        XCTAssertEqual(view.accessibilityLabel, "Transcrição recolhida")
        controller.handleObjectTap(view, at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(document.blocks.first { $0.id == card.id }?.layout.frame, card.layout.frame)
        XCTAssertNotNil(controller.view.descendants(UITextView.self).first { $0.text == "Texto transcrito" })
    }

    /// Block letters written with a grey pencil are redrawn as even black lines and read.
    func testBlockLettersAreRead() throws {
        // "LEITE" in straight strokes, 40 pt tall, each line its own stroke.
        func line(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
            let points = (0...24).map { step -> PKStrokePoint in
                let t = CGFloat(step) / 24
                return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(step) * 0.01,
                                     size: CGSize(width: 1.5, height: 1.5), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pencil, color: .gray), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        var strokes: [PKStroke] = []
        var x: CGFloat = 20
        let top: CGFloat = 30, bottom: CGFloat = 70
        func e() {
            strokes += [line(.init(x: x, y: top), .init(x: x, y: bottom)), line(.init(x: x, y: top), .init(x: x + 22, y: top)),
                        line(.init(x: x, y: 50), .init(x: x + 17, y: 50)), line(.init(x: x, y: bottom), .init(x: x + 22, y: bottom))]
            x += 36
        }
        strokes += [line(.init(x: x, y: top), .init(x: x, y: bottom)), line(.init(x: x, y: bottom), .init(x: x + 22, y: bottom))]; x += 36
        e()
        strokes += [line(.init(x: x, y: top), .init(x: x, y: bottom))]; x += 16
        strokes += [line(.init(x: x, y: top), .init(x: x + 26, y: top)), line(.init(x: x + 13, y: top), .init(x: x + 13, y: bottom))]; x += 40
        e()
        let bounds = strokes.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(HandwritingReader.letterHeight(strokes.map(\.renderBounds.height)), bounds.height, accuracy: 3)
        let image = try XCTUnwrap(HandwritingReader.picture(of: strokes, bounds: bounds))
        // Letters about 60 px tall in the picture.
        XCTAssertEqual(CGFloat(image.height), (bounds.height + 2 * max(12, bounds.height * 0.6)) * min(6, max(1.5, 60 / bounds.height)), accuracy: 4)
        let reading = try XCTUnwrap(HandwritingReader.read(image, languages: ["pt-BR", "en-US"]))
        XCTAssertEqual(reading.text.uppercased().filter { !$0.isWhitespace }, "LEITE", reading.text)
    }
}

private extension UIView {
    func descendants<T: UIView>(_ type: T.Type) -> [T] { ((self as? T).map { [$0] } ?? []) + subviews.flatMap { $0.descendants(type) } }
}
