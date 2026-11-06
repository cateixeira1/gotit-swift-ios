import XCTest
import PencilKit
import GotItDomain
import GotItCanvasUI
@testable import GotItDemo

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
        let model = DemoModel()
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
}
