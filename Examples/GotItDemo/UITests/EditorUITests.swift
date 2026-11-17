import XCTest

@MainActor
final class EditorUITests: XCTestCase {
    func testPagesDrawingAndReopenInAdaptiveEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"]
        app.launch()
        let pages = app.buttons["showPages"]
        let addPage = app.buttons["addPage"]
        XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 20))
        if pages.exists { pages.tap() }
        XCTAssertTrue(addPage.waitForExistence(timeout: 10)); addPage.tap()
        let second = app.buttons["page-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 10)); second.tap()
        // SwiftUI Menu's nested AX button can report non-hittable despite a visible
        // toolbar frame. Tap its observed center instead of AX scroll-to-visible.
        let options = app.buttons["documentOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Tamanho e opções do canvas"].tap()
        let recognize = app.switches["Reconhecer diagramas"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 10))
        XCTAssertEqual(recognize.value as? String, "1")
        recognize.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        XCTAssertEqual(recognize.value as? String, "0", "Freehand test requires recognition to be off")
        app.buttons["Aplicar"].tap()
        if app.buttons["showTools"].exists { app.buttons["showTools"].tap() }
        let pen = app.buttons["tool-pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 10)); pen.tap()
        let drawing = app.descendants(matching: .any)["drawingCanvas"].firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(drawing.frame.minX, 0)
        XCTAssertGreaterThanOrEqual(drawing.frame.minY, 0)
        let start = drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let end = drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: end)
        let ink = NSPredicate(format: "value != %@", "0 traços")
        expectation(for: ink, evaluatedWith: drawing)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor-native-layout"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["showPages"].waitForExistence(timeout: 10) || app.buttons["addPage"].exists)
        if app.buttons["showPages"].exists { app.buttons["showPages"].tap() }
        XCTAssertTrue(app.buttons["page-2"].waitForExistence(timeout: 10)); app.buttons["page-2"].tap()
        let restored = app.descendants(matching: .any)["drawingCanvas"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.value as? String, "1 traços")
    }
}
