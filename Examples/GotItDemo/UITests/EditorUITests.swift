import XCTest

@MainActor
final class EditorUITests: XCTestCase {
    func testPagesToolsAndTextInAdaptiveEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"]
        app.launch()
        let pages = app.buttons["showPages"]
        let addPage = app.buttons["addPage"]
        XCTAssertTrue(app.otherElements["pageEditor"].waitForExistence(timeout: 20) || addPage.waitForExistence(timeout: 10) || pages.exists)
        if pages.exists { pages.tap() }
        XCTAssertTrue(addPage.waitForExistence(timeout: 10)); addPage.tap()
        let second = app.buttons["page-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 10)); second.tap()
        if app.buttons["showTools"].exists { app.buttons["showTools"].tap() }
        let pen = app.buttons["tool-pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 10)); pen.tap()
        let drawing = app.descendants(matching: .any)["drawingCanvas"].firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
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
