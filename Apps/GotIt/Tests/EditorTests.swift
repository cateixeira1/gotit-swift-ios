import XCTest
import PencilKit
import PDFKit
import GotItDomain
@testable import GotItCanvasUI
@testable import GotItApp

@MainActor
final class EditorTests: XCTestCase {
    func testNativeInkToolsAndDrawingRoundTrip() throws {
        XCTAssertEqual(CanvasTool.allCases.filter { $0.isDrawing && $0 != .eraser }.count, 5)
        let points = [
            PKStrokePoint(location: CGPoint(x: 25, y: 30), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.4, azimuth: 0.2, altitude: 0.8),
            PKStrokePoint(location: CGPoint(x: 90, y: 80), timeOffset: 0.2, size: CGSize(width: 7, height: 7), opacity: 1, force: 0.8, azimuth: 0.4, altitude: 0.9)
        ]
        let stroke = PKStroke(ink: PKInk(.fountainPen, color: .systemBlue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let original = PKDrawing(strokes: [stroke])
        let loaded = try PKDrawing(data: original.dataRepresentation())
        XCTAssertEqual(loaded.strokes.count, 1)
        XCTAssertEqual(loaded.strokes[0].ink.inkType, .fountainPen)
        XCTAssertEqual(loaded.strokes[0].path.count, 2)
        XCTAssertEqual(loaded.strokes[0].path[1].force, 0.8, accuracy: 0.001)
        XCTAssertEqual(loaded.strokes[0].path[1].location, points[1].location)
    }

    func testDrawingCreatesOnlyOneLayerAndEraserCanRemoveIt() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let document = try XCTUnwrap(model.document)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let point = PKStrokePoint(location: CGPoint(x: 20, y: 20), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point], creationDate: Date()))
        let bytes = PKDrawing(strokes: [stroke]).dataRepresentation()
        model.saveDrawing(bytes, extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        XCTAssertFalse(model.writeFailed)
        XCTAssertEqual(model.document?.blocks.count, 1)
        model.saveDrawing(bytes, extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        XCTAssertEqual(model.document?.blocks.count, 1)
        await model.open(document.id)
        let hash = try XCTUnwrap(model.document?.blocks.first?.content.assetHash)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(model.assetData(hash))).strokes.count, 1)
        model.saveDrawing(PKDrawing().dataRepresentation(), extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        XCTAssertTrue(model.document?.blocks.isEmpty == true)
        await model.history(undo: true)
        XCTAssertEqual(model.document?.blocks.count, 1)
    }
    func testPaginationPreservesRichTextAndMovesOverflowToNewPages() throws {
        var document = CanvasDocument(title: "Flow")
        let rich = RichText(runs: [TextRun(String(repeating: "Olá 👨‍👩‍👧‍👦 漢字 café. ", count: 180), style: .init(fontSize: 20, bold: true))])
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 240, height: 180)), content: .text(.init("")))
        block.textFlowID = block.id; document.blocks = [block]
        block.content = .text(rich)
        let result = try TextPagination.reflow(block, in: document, selection: NSRange(location: (rich.plainText as NSString).length, length: 0))
        let paginated = try CommandEngine.applying(result.commands, to: document)
        XCTAssertGreaterThan(paginated.pages.count, 1)
        let combined = paginated.pages.flatMap { page in paginated.blocks.filter { paginated.pageID(for: $0.id) == page.id } }.compactMap { block -> String? in
            if case .text(let text) = block.content { return text.plainText }; return nil
        }.joined()
        XCTAssertEqual(combined, rich.plainText)
        XCTAssertEqual(result.focus.pageID, paginated.pages.last?.id)
        XCTAssertTrue(paginated.blocks.allSatisfy { $0.textFlowID == block.id })
    }

    func testTableDrawsCellsAndBordersAtItsFrameSize() throws {
        var table = CanvasTable(rows: 2, columns: 2, width: 200)
        table = try table.settingText(RichText("Data"), row: 0, column: 0)
        table.cells[1][1].background = "#DBEAFE"
        let size = CGSize(width: table.width, height: table.height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in TableRendering.draw(table, in: CGRect(origin: .zero, size: size)) }
        // Sample the coloured cell centre and a border pixel: drawing really happened.
        let cg = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cg.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let scale = Int(image.scale), offset = (y * scale) * cg.bytesPerRow + (x * scale) * (cg.bitsPerPixel / 8)
            return Array(data[offset..<(offset + 4)])
        }
        XCTAssertNotEqual(pixel(150, 54), [0, 0, 0, 0])   // filled cell (row 2, column 2)
        XCTAssertNotEqual(pixel(100, 18), [0, 0, 0, 0])   // vertical border between columns
    }

    func testTextBridgeKeepsNamedStyleThroughEditing() throws {
        let heading = try XCTUnwrap(NamedStyle.builtIn.first { $0.id == "heading1" })
        let styled = RichText("Fatos\nPedido").applyingNamedStyle(heading, utf16Range: 0..<0)
        let roundTrip = TextBridge.richText(TextBridge.attributed(styled, base: .init(fontSize: 18)))
        XCTAssertEqual(roundTrip.plainText, styled.plainText)
        XCTAssertEqual(roundTrip.runs.first?.style.namedStyle, "heading1")
        XCTAssertEqual(roundTrip.runs.first?.style.fontSize, 24)
        XCTAssertNil(roundTrip.runs.last?.style.namedStyle)
    }

    func testPagesAreStackedAndOnlyNearbyPagesAreRealized() throws {
        var document = CanvasDocument(title: "Stack")
        for index in 2...12 { document.pages.append(CanvasPage(title: "Página \(index)")) }
        let editors = try document.pages.map { CanvasEditor(document: try document.pageDocument($0.id), onCommands: { _ in }) }
        var visible: [UUID] = []
        let controller = PagedCanvasViewController(configuration: PagedCanvasEditor(
            pages: editors, tool: .select, session: EditorSession(), focusPageID: document.pages.first?.id,
            onVisiblePage: { visible.append($0) }))
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.realizedPageCount, 0)
        XCTAssertLessThan(controller.realizedPageCount, 12)   // 12 A4 pages, only those near the viewport
        XCTAssertTrue(visible.isEmpty || visible.first == document.pages.first?.id)
    }

    func testStoryBoxesShrinkToTheirTextAndFillPagesBeforeContinuing() throws {
        var document = CanvasDocument(title: "Auto")
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 100, width: 300, height: 600)), content: .text(.init("")))
        block.textFlowID = block.id; document.blocks = [block]
        block.content = .text(RichText("Olá"))
        let short = try CommandEngine.applying(TextPagination.reflow(block, in: document, selection: NSRange(location: 3, length: 0)).commands, to: document)
        let height = try XCTUnwrap(short.blocks.first?.layout.frame.height)
        XCTAssertGreaterThanOrEqual(height, 44)
        XCTAssertLessThan(height, 120)                         // one line plus room, not 600
        block.content = .text(RichText(String(repeating: "texto longo ", count: 900)))
        let long = try CommandEngine.applying(TextPagination.reflow(block, in: document, selection: NSRange(location: 0, length: 0)).commands, to: document)
        XCTAssertGreaterThan(long.pages.count, 1)
        let first = try XCTUnwrap(long.blocks.first { $0.id == block.id })
        XCTAssertEqual(first.layout.frame.height, document.canvas.size.height - 100 - 24, accuracy: 0.5)   // grew to the margin
    }

    func testFocusCarriesTheBoxFrameSoTheViewGrowsAtOnce() throws {
        var document = CanvasDocument(title: "Grow")
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 100, width: 300, height: 44)), content: .text(.init("")))
        block.textFlowID = block.id; document.blocks = [block]
        block.content = .text(RichText("uma\nduas\ntrês"))
        let result = try TextPagination.reflow(block, in: document, selection: NSRange(location: 12, length: 0))
        let frame = try XCTUnwrap(result.focus.frame)
        XCTAssertGreaterThan(frame.height, 44)            // three lines: taller than one
    }

    func testPageFillsTheWidthAndCannotDriftSideways() throws {
        var document = CanvasDocument(title: "Fit")
        document.pages.append(CanvasPage(title: "Página 2"))
        let editors = try document.pages.map { CanvasEditor(document: try document.pageDocument($0.id), onCommands: { _ in }) }
        let controller = PagedCanvasViewController(configuration: PagedCanvasEditor(
            pages: editors, tool: .select, session: EditorSession(), focusPageID: document.pages.first?.id, onVisiblePage: { _ in }))
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let scroll = controller.pagesScrollView
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)          // nothing to scroll sideways
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width - 2)          // the page fills the width
        // Rotating (or a wider window) refits instead of leaving the old zoom.
        controller.view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 2)
    }

    func testCaretMovesToTheNextPageAtOnceAndQueuedKeysFollowIt() throws {
        var document = CanvasDocument(title: "Flow")
        document.pages.append(CanvasPage(title: "Continuação"))
        let story = UUID()
        let first = CanvasBlock(id: story, layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 300, height: 60)),
                                content: .text(.init("abc")), textFlowID: story)
        let second = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 300, height: 60)),
                                 content: .text(.init("def")), pageID: document.pages[1].id, textFlowID: story)
        document.blocks = [first, second]
        let session = EditorSession()
        let editors = try document.pages.map { CanvasEditor(document: try document.pageDocument($0.id), session: session, onCommands: { _ in }) }
        let controller = PagedCanvasViewController(configuration: PagedCanvasEditor(
            pages: editors, tool: .select, session: session, focusPageID: document.pages[1].id, onVisiblePage: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        // Pagination moved "X" to the start of page 2 while a "Y" was being typed: the caret lands there
        // synchronously and the queued key follows it, in order.
        let focus = TextFlowFocus(blockID: second.id, pageID: document.pages[1].id, range: NSRange(location: 1, length: 0), text: RichText("Xdef"))
        session.queuedInput = [.insert("Y")]
        XCTAssertEqual(session.focusRouter?(focus), true)
        func firstResponder(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.isFirstResponder { return text }
            return view.subviews.lazy.compactMap(firstResponder).first
        }
        let editing = try XCTUnwrap(firstResponder(in: window))
        XCTAssertEqual(editing.text, "XYdef")
        XCTAssertEqual(editing.selectedRange.location, 2)
        window.isHidden = true
    }

    func testBackspaceAtTheStartOfAPageJoinsThePreviousPage() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let document = try XCTUnwrap(model.document)
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 300, height: 44)), content: .text(.init("")))
        block.textFlowID = block.id
        model.enqueue([.insertBlock(block)], pageID: try XCTUnwrap(document.pages.first?.id), documentID: document.id)
        while model.isSaving { await Task.yield() }
        var long = try XCTUnwrap(model.document?.blocks.first { $0.id == block.id })
        long.content = .text(RichText(String(repeating: "palavra ", count: 700)))
        _ = model.editText(long, group: nil, selection: NSRange(location: 0, length: 0))
        while model.isSaving { await Task.yield() }
        func storyText() throws -> String {
            try XCTUnwrap(model.document).textFlowFragments(story: block.id).compactMap { fragment -> String? in
                if case .text(let text) = fragment.content { return text.plainText }; return nil
            }.joined()
        }
        let fragments = try XCTUnwrap(model.document).textFlowFragments(story: block.id)
        XCTAssertGreaterThan(fragments.count, 1)
        let before = try storyText()
        let focus = try XCTUnwrap(model.backspaceAcrossFragments(fragments[1].id, group: "join"))
        // The caret stays at the same place in the story (the page boundary), on either side of it.
        XCTAssertTrue(fragments.map(\.id).contains(focus.blockID))
        while model.isSaving { await Task.yield() }
        XCTAssertEqual(try storyText().count, before.count - 1)
    }

    func testNoteOpenedFromATeiaGoesBackToTheTeiaFirst() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let note = try XCTUnwrap(model.document?.id)
        await model.createWeb(including: note)
        let web = try XCTUnwrap(model.document?.id)
        await model.open(note, returningTo: web)
        XCTAssertEqual(model.document?.id, note)
        XCTAssertEqual(model.returnStack, [web])
        await model.goBack()
        XCTAssertEqual(model.document?.id, web)
        XCTAssertTrue(model.returnStack.isEmpty)
        await model.open(note)                     // from the list: no way "back" to a Teia
        XCTAssertTrue(model.returnStack.isEmpty)
    }

    func testOffscreenBlocksAreNotInstantiated() {
        var document = CanvasDocument(title: "Viewport")
        for i in 0..<1000 {
            document.blocks.append(CanvasBlock(order: i, layout: .init(mode: .absolute, frame: .init(x: 24, y: Double(i) * 220, width: 100, height: 100)), content: .shape(.init(kind: .rectangle))))
        }
        let controller = CanvasViewController(configuration: CanvasEditor(document: document, onCommands: { _ in }))
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.realizedBlockViewCount, 0)
        XCTAssertLessThan(controller.realizedBlockViewCount, 12)
    }

    func testPrumoReaderNavigatesAndSearchesPastFirstPage() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            for word in ["Primeira", "Segunda", "Terceira"] {
                context.beginPage(); (word as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
            }
        }
        let view = PDFView(); view.document = try XCTUnwrap(PDFDocument(data: data))
        let model = ReaderModel(); model.attach(view); model.pageChanged()
        XCTAssertEqual(model.pageCount, 3)
        model.go(toPage: 3); model.pageChanged(); XCTAssertEqual(model.currentPage, 3)
        model.search("Segunda"); XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(view.document?.index(for: try XCTUnwrap(model.results.first?.pages.first)), 1)
    }

}
