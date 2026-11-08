import XCTest
import PencilKit
import PDFKit
import GotItDomain
import GotItCanvas
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
        model.saveDrawing(.full(bytes), extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        XCTAssertFalse(model.writeFailed)
        XCTAssertEqual(model.document?.blocks.count, 1)
        model.saveDrawing(.full(bytes), extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        XCTAssertEqual(model.document?.blocks.count, 1)
        await model.open(document.id)
        let hash = try XCTUnwrap(model.document?.blocks.first?.content.assetHash)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(model.assetData(hash))).strokes.count, 1)
        model.saveDrawing(.full(PKDrawing().dataRepresentation()), extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        XCTAssertTrue(model.document?.blocks.isEmpty == true)
        await model.history(undo: true)
        XCTAssertEqual(model.document?.blocks.count, 1)
    }
    /// New strokes are saved as small parts over the page's drawing; erasing writes it whole again
    /// and frees the parts; undo brings the parts back.
    func testNewStrokesAreSavedAsPartsAndAWholeSaveReplacesThem() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let document = try XCTUnwrap(model.document)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        func stroke(_ x: CGFloat) -> PKStroke {
            let points = (0..<20).map { PKStrokePoint(location: CGPoint(x: x + CGFloat($0), y: 40), timeOffset: Double($0) / 60, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: 1) }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date().addingTimeInterval(Double(x))))
        }
        let base = PKDrawing(strokes: [stroke(10), stroke(40)])
        model.saveDrawing(.full(base.dataRepresentation()), extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        for x in [80.0, 120.0, 160.0] {
            model.saveDrawing(.appended(PKDrawing(strokes: [stroke(CGFloat(x))]).dataRepresentation()), extra: [], pageID: pageID, documentID: document.id)
            while model.isSaving { await Task.yield() }
        }
        guard case .drawing(let reference)? = model.document?.blocks.first?.content else { return XCTFail("No drawing") }
        XCTAssertEqual(reference.parts?.count, 3)
        let assembled = try DrawingStorage.drawing(reference, data: model.assetData)
        XCTAssertEqual(assembled.strokes.count, 5)
        // In the order they were drawn: base first, then each part.
        XCTAssertEqual(assembled.strokes.map { Double($0.path[0].location.x).rounded() }, [10, 40, 80, 120, 160])
        // Each part holds only its own stroke.
        for hash in try XCTUnwrap(reference.parts) { XCTAssertEqual(try PKDrawing(data: XCTUnwrap(model.assetData(hash))).strokes.count, 1) }
        // Reopened from disk, the same five strokes.
        await model.open(document.id)
        guard case .drawing(let reopened)? = model.document?.blocks.first?.content else { return XCTFail("No drawing") }
        XCTAssertEqual(try DrawingStorage.drawing(reopened, data: model.assetData).strokes.count, 5)
        // Erasing one stroke: the whole drawing again, parts released.
        model.saveDrawing(.full(PKDrawing(strokes: Array(assembled.strokes.dropFirst())).dataRepresentation()), extra: [], pageID: pageID, documentID: document.id)
        while model.isSaving { await Task.yield() }
        guard case .drawing(let whole)? = model.document?.blocks.first?.content else { return XCTFail("No drawing") }
        XCTAssertNil(whole.parts)
        XCTAssertEqual(model.document?.assets.count, 1)
        await model.history(undo: true)
        guard case .drawing(let restored)? = model.document?.blocks.first?.content else { return XCTFail("No drawing") }
        XCTAssertEqual(restored.parts?.count, 3)
        XCTAssertEqual(try DrawingStorage.drawing(restored, data: model.assetData).strokes.count, 5)
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

    /// The table gestures: one tap on the first cell of a line picks it (tint, resize handle),
    /// a quick second tap offers duplicate/delete, a slow one edits; "+" adds rows and columns.
    func testTableLinesArePickedResizedDuplicatedAndAdded() throws {
        let grid = CanvasTable(rows: 3, columns: 3, width: 300)
        let table = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 40, y: 40, width: grid.width, height: grid.height)), content: .table(grid))
        var document = try CommandEngine.applying([.insertBlock(table)], to: CanvasDocument(title: "Tabela"))
        var controller: CanvasViewController!
        func editor() -> CanvasEditor {
            CanvasEditor(document: document, onCommands: { commands in
                document = try! CommandEngine.applying(commands, to: document)
                controller.configure(editor())
            })
        }
        controller = CanvasViewController(configuration: editor())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        func current() throws -> CanvasTable {
            guard case .table(let t) = try XCTUnwrap(document.blocks.first { $0.id == table.id }).content else { throw CancellationError() }
            return t
        }
        func pause() { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }

        controller.tapTableCell(table.id, row: 1, column: 1)            // selects: "+" buttons, nothing picked
        var chrome = try XCTUnwrap(controller.tableChromeForTesting)
        XCTAssertNil(controller.tableFocus)
        XCTAssertTrue(chrome.rowHandle.isHidden && chrome.columnHandle.isHidden)
        pause()
        controller.tapTableCell(table.id, row: 0, column: 2)            // first cell of column 3
        XCTAssertEqual(controller.tableFocus, TableFocus(block: table.id, row: nil, column: 2))
        chrome = try XCTUnwrap(controller.tableChromeForTesting)
        chrome.layoutIfNeeded()
        XCTAssertFalse(chrome.columnHandle.isHidden); XCTAssertTrue(chrome.rowHandle.isHidden)
        XCTAssertEqual(chrome.columnHandle.frame.midX, 300, accuracy: 1)   // on the column's right edge
        chrome.onResize?(.column, 2, 160, true)
        XCTAssertEqual(try current().columnWidths, [100, 100, 160])
        XCTAssertEqual(document.blocks.first { $0.id == table.id }?.layout.frame.width, 360)

        pause()
        controller.tapTableCell(table.id, row: 2, column: 0)            // first cell of row 3
        controller.tapTableCell(table.id, row: 2, column: 0)            // quick second tap
        XCTAssertEqual(controller.tableFocus, TableFocus(block: table.id, row: 2, column: nil))
        XCTAssertEqual(controller.lineMenu?.children.map(\.title), ["Duplicar linha", "Excluir linha"])
        XCTAssertNil(controller.editingCellForTesting)
        controller.applyTableAction(.duplicateRow(2), to: table.id)
        XCTAssertEqual(try current().rowCount, 4)
        XCTAssertEqual(controller.tableFocus?.row, 3, "the copy is picked")

        let corner = try XCTUnwrap(TableFocus.picked(block: table.id, row: 0, column: 0))
        XCTAssertEqual(controller.lineActions(for: corner).map { $0.title }, ["Duplicar linha", "Excluir linha", "Duplicar coluna", "Excluir coluna"])
        XCTAssertNil(TableFocus.picked(block: table.id, row: 1, column: 1))

        pause()
        controller.tapTableCell(table.id, row: 1, column: 0)
        XCTAssertNil(controller.editingCellForTesting, "the tap that picks the line does not open the keyboard")
        pause()
        controller.tapTableCell(table.id, row: 1, column: 0)            // slow second tap: edit the text
        XCTAssertEqual(controller.editingCellForTesting?.row, 1)
        let cellEditor = try XCTUnwrap(controller.view.firstResponderView as? UITextView)
        XCTAssertEqual((cellEditor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment, .justified)
        cellEditor.resignFirstResponder()

        chrome = try XCTUnwrap(controller.tableChromeForTesting)
        chrome.addRow.sendActions(for: .touchUpInside)
        chrome = try XCTUnwrap(controller.tableChromeForTesting)
        chrome.addColumn.sendActions(for: .touchUpInside)
        XCTAssertEqual(try current().rowCount, 5); XCTAssertEqual(try current().columnCount, 4)
        controller.applyTableAction(.deleteColumn(3), to: table.id)
        XCTAssertEqual(try current().columnCount, 3)
        XCTAssertEqual(TableRendering.base(header: false).alignment, .justified)
        window.isHidden = true
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

    func testEveryTeiaCardIsShownWhenTheTeiaOpensAgain() throws {
        var web = CanvasDocument(title: "Teia", kind: .web)
        // Spread over the page, one partly and one wholly past its right edge (dragged aside).
        let spots: [(Double, Double)] = [(24, 24), (330, 24), (24, 600), (330, 620), (420, 860), (640, 300)]
        for (index, spot) in spots.enumerated() {
            web.blocks.append(CanvasBlock(order: index, layout: .init(mode: .absolute, frame: .init(x: spot.0, y: spot.1, width: 240, height: 190)),
                                          content: .noteReference(.init(documentID: UUID()))))
        }
        let editors = try web.pages.map { CanvasEditor(document: try web.pageDocument($0.id), onCommands: { _ in }) }
        let controller = PagedCanvasViewController(configuration: PagedCanvasEditor(
            pages: editors, tool: .select, session: EditorSession(), focusPageID: web.pages.first?.id, onVisiblePage: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let page = try XCTUnwrap(controller.children.compactMap { $0 as? CanvasViewController }.first)
        XCTAssertEqual(page.realizedBlockViewCount, spots.count)
        window.isHidden = true
    }

    func testStickyNoteAndCalendarAreDrawnLikePaper() throws {
        func pixel(_ image: UIImage, _ x: Int, _ y: Int) throws -> [CGFloat] {
            let cg = try XCTUnwrap(image.cgImage)
            var data = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height - 1 - y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
            return data.map { CGFloat($0) / 255 }
        }
        func draw(_ block: CanvasBlock, size: CGSize) -> UIImage {
            let view = CanvasObjectView(frame: CGRect(origin: .zero, size: size)); view.block = block
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in view.draw(view.bounds) }
        }
        let note = try CommandEngine.applying(Stickers.stickyNote(at: .init(x: 0, y: 0), order: 0), to: CanvasDocument(title: "S"))
        let paper = try XCTUnwrap(note.blocks.first { $0.parentID == nil })
        let drawnNote = draw(paper, size: CGSize(width: 200, height: 200))
        let middle = try pixel(drawnNote, 100, 120)
        XCTAssertGreaterThan(middle[0], 0.85); XCTAssertGreaterThan(middle[1], 0.8); XCTAssertLessThan(middle[2], 0.65)   // yellow paper
        XCTAssertLessThan(try pixel(drawnNote, 199, 199)[3], 0.1)                                                       // lifted corner
        let calendar = try CommandEngine.applying(Stickers.calendar(at: .init(x: 0, y: 0), order: 0), to: CanvasDocument(title: "C"))
        let drawnCalendar = draw(try XCTUnwrap(calendar.blocks.first), size: CGSize(width: 132, height: 148))
        let band = try pixel(drawnCalendar, 12, 45)
        XCTAssertGreaterThan(band[0], 0.7); XCTAssertLessThan(band[1], 0.45)                                           // red month band
        let body = try pixel(drawnCalendar, 10, 125)
        XCTAssertGreaterThan(body[0], 0.95); XCTAssertGreaterThan(body[1], 0.95)                                        // white page
    }

    /// A text box on screen, first responder, reporting what the editor sends to the host.
    private func typingHarness(onText: @escaping (String, String?) -> Void) throws -> (UIWindow, UITextView) {
        var document = CanvasDocument(title: "Teclado")
        document.blocks = [CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 300, height: 60)), content: .text(.init("")))]
        let controller = CanvasViewController(configuration: CanvasEditor(document: document,
            onTextCommands: { changed, group, _ in
                if case .text(let text) = changed.content { onText(text.plainText, group) }
                return nil
            }, onCommands: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first }
        let text = try XCTUnwrap(find(controller.view))
        XCTAssertTrue(text.becomeFirstResponder())
        return (window, text)
    }

    func testEndingACompositionSendsTheComposedTextOnce() throws {
        var sent: [String] = []
        let (window, text) = try typingHarness { plain, _ in sent.append(plain) }
        // A dead key on a hardware keyboard, or a kana being composed: marked text first.
        text.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0))
        text.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(sent.isEmpty, "nothing is saved in the middle of a composition")
        text.unmarkText()
        XCTAssertEqual(sent.last, "é")
        XCTAssertEqual(sent.filter { $0 == "é" }.count, 1)
        text.insertText(" ok")
        XCTAssertEqual(sent.last, "é ok")
        window.isHidden = true
    }

    func testTypingIsOneUndoStepAndAPasteIsItsOwn() throws {
        var groups: [String?] = []
        let (window, text) = try typingHarness { _, group in groups.append(group) }
        // The keyboard asks the delegate before inserting; programmatic insertText does not.
        func key(_ string: String) {
            if text.delegate?.textView?(text, shouldChangeTextIn: text.selectedRange, replacementText: string) ?? true { text.insertText(string) }
        }
        key("a"); key("b")
        key("texto colado")                           // several characters at once: a paste
        XCTAssertEqual(groups.count, 3)
        XCTAssertNotNil(groups[0])
        XCTAssertEqual(groups[0], groups[1])
        XCTAssertNotEqual(groups[1], groups[2])
        window.isHidden = true
    }

    /// Swipe to delete sends a note or Teia to the Lixeira; it can come back whole or go for good.
    func testDeletedNotesAndTeiasGoToTheTrashAndCanComeBack() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let note = try XCTUnwrap(model.document)
        model.enqueue([.insertBlock(CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 200, height: 44)), content: .text(.init("guardar"))))],
                      pageID: note.pages[0].id, documentID: note.id)
        while model.isSaving { try await Task.sleep(for: .milliseconds(20)) }
        await model.createWeb(including: note.id)
        XCTAssertEqual(model.document?.kind, .web)
        let web = try XCTUnwrap(model.document)
        await model.moveToTrash(web.id)                 // the open Teia
        XCTAssertNil(model.document)
        await model.moveToTrash(note.id)
        XCTAssertFalse(model.activeSummaries.contains { $0.id == note.id || $0.id == web.id })
        XCTAssertEqual(model.trashedSummaries.prefix(2).map(\.id), [note.id, web.id], "most recent first")
        await model.open(note.id)
        XCTAssertNotNil(model.error, "a note in the Lixeira does not open"); model.error = nil
        await model.restoreFromTrash(note.id)
        XCTAssertTrue(model.activeSummaries.contains { $0.id == note.id })
        await model.open(note.id)
        let restored = try XCTUnwrap(model.document)
        XCTAssertTrue(restored.blocks.contains { if case .text(let t) = $0.content { t.plainText == "guardar" } else { false } })
        await model.deleteForever(web.id)
        XCTAssertFalse(model.summaries.contains { $0.id == web.id })
        await model.moveToTrash(note.id)
        await model.emptyTrash()
        XCTAssertTrue(model.trashedSummaries.isEmpty)
        XCTAssertFalse(model.summaries.contains { $0.id == note.id })
        XCTAssertNil(model.error)
    }

    func testUndoAfterTextFlowsOntoNewPagesRestoresOnePageAndRedoBringsThemBack() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let document = try XCTUnwrap(model.document)
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 300, height: 44)), content: .text(.init("")))
        block.textFlowID = block.id
        model.enqueue([.insertBlock(block)], pageID: try XCTUnwrap(document.pages.first?.id), documentID: document.id)
        while model.isSaving { await Task.yield() }
        var long = try XCTUnwrap(model.document?.blocks.first { $0.id == block.id })
        let pasted = String(repeating: "palavra ", count: 700)
        long.content = .text(RichText(pasted))
        _ = model.editText(long, group: "colar", selection: NSRange(location: (pasted as NSString).length, length: 0))
        while model.isSaving { await Task.yield() }
        func story() throws -> String {
            try XCTUnwrap(model.document).textFlowFragments(story: block.id).compactMap { fragment -> String? in
                if case .text(let text) = fragment.content { return text.plainText }; return nil
            }.joined()
        }
        let pages = try XCTUnwrap(model.document?.pages.count)
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(try story(), pasted)
        await model.history(undo: true)              // the paste and its new pages are one step
        XCTAssertEqual(model.document?.pages.count, 1)
        XCTAssertEqual(try story(), "")
        await model.history(undo: false)
        XCTAssertEqual(model.document?.pages.count, pages)
        XCTAssertEqual(try story(), pasted)
    }

    func testInkExportCarriesTheOriginalStrokesOfShapes() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let document = try XCTUnwrap(model.document)
        let stroke = InkStroke(points: [.init(x: 0, y: 0), .init(x: 120, y: 2), .init(x: 118, y: 80), .init(x: 1, y: 79), .init(x: 0, y: 1)])
        let box = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 40, y: 40, width: 120, height: 80)),
                              content: .shape(.init(kind: .rectangle, originalStroke: stroke)))
        model.enqueue([.insertBlock(box)], pageID: try XCTUnwrap(document.pages.first?.id), documentID: document.id)
        while model.isSaving { await Task.yield() }
        let url = try model.exportInk(of: try XCTUnwrap(model.document))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(InkSampleFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.strokes.count, 1)
        XCTAssertEqual(file.strokes.first?.kind, "rectangle")
        XCTAssertEqual(file.strokes.first?.points.count, 5)
        XCTAssertEqual(file.strokes.first?.page, 1)
    }

    /// Runs the on-device measurement once (here in the simulator) and prints it in the test log.
    func testDeviceMeasurementRunsAndReportsEveryPart() async throws {
        var steps: [String] = []
        let lines = await DevicePerformance.run { steps.append($0) }
        let report = DevicePerformance.report(lines)
        print("MEDICAO\n" + report)
        XCTAssertFalse(lines.contains { $0.title == "Medição interrompida" }, report)
        XCTAssertTrue(lines.contains { $0.title.hasPrefix("Digitar no fim") })
        XCTAssertTrue(lines.contains { $0.title.hasPrefix("Gravar no banco") })
        XCTAssertTrue(lines.contains { $0.title.hasPrefix("Salvar desenho") })
        XCTAssertTrue(lines.contains { $0.title == "Memória" })
        XCTAssertGreaterThanOrEqual(steps.count, 5)
        XCTAssertEqual(DevicePerformance.summary([3, 1, 2]), "mediana 2,0 ms · p95 3,0 ms · máx 3,0 ms")
    }

    /// Laying out only from the page before the edit, and stopping where pages line up again, gives
    /// exactly what laying out the whole story gives, for typing, new lines, pastes and deletions.
    /// A story of several pages, laid out.
    private func longStory(paragraphs: Int = 40) throws -> (CanvasDocument, UUID, String) {
        var document = CanvasDocument(title: "Seleção", defaultStyle: .init(fontSize: 18))
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: document.canvas.size.width - 48, height: 44)),
                                content: .text(.init("")))
        block.textFlowID = block.id
        document.blocks = [block]
        let sentence = "Frase de teste para encher várias páginas com texto corrido. "
        let story = (0..<paragraphs).map { "\($0): " + String(repeating: sentence, count: 3 + $0 % 3) }.joined(separator: "\n")
        block.content = .text(RichText(story))
        document = try CommandEngine.applying(TextPagination.reflow(block, in: document, selection: .init(location: 0, length: 0), incremental: false).commands, to: document)
        return (document, block.id, story)
    }

    func testEditingASelectionAcrossPagesEditsTheWholeStory() throws {
        let (document, story, text) = try longStory()
        XCTAssertGreaterThanOrEqual(document.pages.count, 4)
        let fragments = document.textFlowFragments(story: story)
        func length(_ block: CanvasBlock) -> Int { if case .text(let rich) = block.content { return (rich.plainText as NSString).length }; return 0 }
        // From the middle of page 1 to the middle of page 3.
        let start = length(fragments[0]) / 2
        let end = length(fragments[0]) + length(fragments[1]) + length(fragments[2]) / 2
        let range = NSRange(location: start, length: end - start)
        let whole = text as NSString
        func storyText(_ d: CanvasDocument) throws -> String { try StoryEditing.joined(story: story, in: d).text.string }

        let deleted = try StoryEditing.apply(.delete, to: range, story: story, in: document)
        let afterDelete = try CommandEngine.applying(deleted.commands, to: document)
        XCTAssertEqual(try storyText(afterDelete), whole.replacingCharacters(in: range, with: ""))
        XCTAssertLessThan(afterDelete.pages.count, document.pages.count)

        let typed = try StoryEditing.apply(.replace("X"), to: range, story: story, in: document)
        let afterTyping = try CommandEngine.applying(typed.commands, to: document)
        XCTAssertEqual(try storyText(afterTyping), whole.replacingCharacters(in: range, with: "X"))
        // The caret lands right after the X, in whichever box holds it now.
        let focusStart = afterTyping.textFlowFragments(story: story).prefix { $0.id != typed.focus.blockID }.reduce(0) { $0 + length($1) }
        XCTAssertEqual(focusStart + typed.focus.range.location, start + 1)

        let bold = try StoryEditing.apply(.format(.bold), to: range, story: story, in: document)
        let afterBold = try CommandEngine.applying(bold.commands, to: document)
        let joined = try StoryEditing.joined(story: story, in: afterBold).text
        XCTAssertEqual(joined.string, text)
        XCTAssertEqual(afterBold.pages.count >= document.pages.count, true)
        func isBold(_ index: Int) -> Bool { ((joined.attribute(.font, at: index, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold)) ?? false }
        XCTAssertTrue(isBold(start)); XCTAssertTrue(isBold(end - 1)); XCTAssertTrue(isBold(length(fragments[0]) + 3))
        XCTAssertFalse(isBold(start - 1)); XCTAssertFalse(isBold(end))
        // Again: bold is turned off.
        let plain = try CommandEngine.applying(StoryEditing.apply(.format(.bold), to: range, story: story, in: afterBold).commands, to: afterBold)
        let unbolded = try StoryEditing.joined(story: story, in: plain).text
        XCTAssertFalse(((unbolded.attribute(.font, at: start, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold)) ?? true)
    }

    func testDeletingAcrossPagesIsOneUndoStep() async throws {
        let model = AppModel()
        await model.start()
        await model.createNote()
        let document = try XCTUnwrap(model.document)
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 400, height: 44)), content: .text(.init("")))
        block.textFlowID = block.id
        model.enqueue([.insertBlock(block)], pageID: try XCTUnwrap(document.pages.first?.id), documentID: document.id)
        while model.isSaving { await Task.yield() }
        var long = try XCTUnwrap(model.document?.blocks.first { $0.id == block.id })
        let text = String(repeating: "texto de várias páginas ", count: 500)
        long.content = .text(RichText(text))
        _ = model.editText(long, group: "colar", selection: NSRange(location: 0, length: 0))
        while model.isSaving { await Task.yield() }
        let pages = try XCTUnwrap(model.document?.pages.count)
        XCTAssertGreaterThan(pages, 2)
        _ = model.editStory(block.id, range: NSRange(location: 10, length: (text as NSString).length - 20), edit: .delete)
        while model.isSaving { await Task.yield() }
        XCTAssertEqual(model.document?.pages.count, 1)
        XCTAssertEqual(try StoryEditing.joined(story: block.id, in: XCTUnwrap(model.document)).text.length, 20)
        await model.history(undo: true)
        XCTAssertEqual(model.document?.pages.count, pages)
        XCTAssertEqual(try StoryEditing.joined(story: block.id, in: XCTUnwrap(model.document)).text.string, text)
    }

    func testASelectionAcrossPagesIsShownOnEachPageWithTwoHandles() throws {
        let (document, story, _) = try longStory()
        let session = EditorSession()
        let editors = try document.pages.map { CanvasEditor(document: try document.pageDocument($0.id), onTextCommands: { _, _, _ in nil }, onCommands: { _ in }) }
        let controller = PagedCanvasViewController(configuration: PagedCanvasEditor(
            pages: editors, tool: .select, session: session, focusPageID: document.pages.first?.id,
            onStoryEdit: { _, _, _ in nil }, onVisiblePage: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let fragments = document.textFlowFragments(story: story)
        XCTAssertEqual(session.fragmentRanges.count, fragments.count)
        XCTAssertTrue(session.spansPages(story))
        let first = try XCTUnwrap(session.fragmentRanges[fragments[0].id]?.range)
        session.storySelection = StorySelection(story: story, range: NSRange(location: first.length - 30, length: 60))
        func highlighted() -> [UITextView] {
            func all(_ view: UIView) -> [UITextView] { ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return all(controller.view).filter { $0.layer.sublayers?.contains { $0.name == "storySelection" } == true }
        }
        XCTAssertEqual(highlighted().count, 2, "the end of page 1 and the start of page 2")
        XCTAssertTrue(controller.storyHandlesVisible)
        session.storySelection = nil
        XCTAssertTrue(highlighted().isEmpty)
        XCTAssertFalse(controller.storyHandlesVisible)
        window.isHidden = true
    }

    func testAnObjectDroppedOnTheNextPageMovesThere() throws {
        var document = CanvasDocument(title: "Mover")
        document = try CommandEngine.applying([.appendPage(CanvasPage(title: "Página 2"))], to: document)
        let session = EditorSession()
        let editors = try document.pages.map { CanvasEditor(document: try document.pageDocument($0.id), onCommands: { _ in }) }
        let controller = PagedCanvasViewController(configuration: PagedCanvasEditor(
            pages: editors, tool: .select, session: session, focusPageID: document.pages.first?.id, onVisiblePage: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let first = try XCTUnwrap(controller.children.compactMap { $0 as? CanvasViewController }.first { $0.view.frame.minY < 100 })
        let height = document.canvas.size.height
        // Dragged 60 points past the bottom of page 1 (beyond the gap): lands near the top of page 2.
        let drop = try XCTUnwrap(session.pageForDrop?(first, CGRect(x: 100, y: height + 60, width: 120, height: 120)))
        XCTAssertEqual(drop.page, document.pages[1].id)
        XCTAssertEqual(drop.origin.x, 100, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(drop.origin.y, 0); XCTAssertLessThan(drop.origin.y, 60)
        // Moved within its own page: stays.
        XCTAssertNil(session.pageForDrop?(first, CGRect(x: 100, y: 300, width: 120, height: 120)))
        window.isHidden = true
    }

    func testIncrementalReflowMatchesTheFullLayout() throws {
        var document = CanvasDocument(title: "Reflow", defaultStyle: .init(fontSize: 18))
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: document.canvas.size.width - 48, height: 44)),
                                content: .text(.init("")))
        block.textFlowID = block.id
        document.blocks = [block]
        let sentence = "Uma frase com palavras de tamanhos variados para quebrar as linhas em lugares diferentes. "
        let story = (0..<60).map { String(repeating: sentence, count: 1 + $0 % 4) }.joined(separator: "\n")
        block.content = .text(RichText(story))
        document = try CommandEngine.applying(TextPagination.reflow(block, in: document, selection: .init(location: 0, length: 0), incremental: false).commands, to: document)
        XCTAssertGreaterThan(document.pages.count, 5)
        // Laying out saved text again changes nothing (fonts survive being saved).
        let first = try XCTUnwrap(document.textFlowFragments(story: block.id).first)
        let again = try TextPagination.reflow(first, in: document, selection: .init(location: 0, length: 0), incremental: false)
        XCTAssertTrue(again.commands.isEmpty, "saved text is laid out differently when laid out again: \(again.commands.count) changes")
        var seed: UInt64 = 7
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }
        func layout(_ d: CanvasDocument) -> [String] {
            d.textFlowFragments(story: block.id).map { fragment in
                let text: String; if case .text(let rich) = fragment.content { text = rich.plainText } else { text = "?" }
                return "\(text)|\(fragment.layout.frame)"
            }
        }
        for step in 0..<40 {
            let fragments = document.textFlowFragments(story: block.id)
            var target = fragments[random(fragments.count)]
            guard case .text(let rich) = target.content else { continue }
            let plain = rich.plainText as NSString
            let location = random(plain.length + 1)
            let insertions = ["a", "palavra-bem-comprida ", "\n", sentence + sentence, ""]
            let insert = insertions[random(insertions.count)]
            let edited: String, caret: Int
            if insert.isEmpty, location > 0 {
                edited = plain.replacingCharacters(in: NSRange(location: location - 1, length: 1), with: ""); caret = location - 1
            } else {
                edited = plain.replacingCharacters(in: NSRange(location: location, length: 0), with: insert); caret = location + (insert as NSString).length
            }
            target.content = .text(RichText(edited))
            let selection = NSRange(location: caret, length: 0)
            let quick = try TextPagination.reflow(target, in: document, selection: selection)
            let full = try TextPagination.reflow(target, in: document, selection: selection, incremental: false)
            let a = try CommandEngine.applying(quick.commands, to: document)
            let b = try CommandEngine.applying(full.commands, to: document)
            XCTAssertEqual(layout(a), layout(b), "step \(step): \(insert.isEmpty ? "delete" : insert.debugDescription) at \(location)")
            XCTAssertEqual(a.pages.count, b.pages.count, "step \(step)")
            XCTAssertEqual(quick.focus.blockID, full.focus.blockID, "step \(step)")
            XCTAssertEqual(quick.focus.range, full.focus.range, "step \(step)")
            XCTAssertLessThanOrEqual(quick.commands.count, full.commands.count)
            document = b
        }
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

private extension UIView {
    var firstResponderView: UIView? { isFirstResponder ? self : subviews.lazy.compactMap(\.firstResponderView).first }
}
