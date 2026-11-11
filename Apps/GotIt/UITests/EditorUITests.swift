import XCTest

@MainActor
final class EditorUITests: XCTestCase {
    /// An error alert blocks every tap after it; report its text instead of a confusing timeout.
    private func failIfAlert(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts.firstMatch
        guard alert.exists else { return }
        let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTFail("Alerta na etapa \(step): \(text)", file: file, line: line)
    }

    /// Edits on screen but never committed (saves held back) come back after the app is killed.
    func testEditsShownBeforeTheAppIsKilledAreRecovered() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--no-autofocus", "--ui-testing", "--reset-test-data", "--hold-saves"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas-1"].firstMatch.waitForExistence(timeout: 20))
        failIfAlert(app, "abertura")
        if app.buttons["showPages"].exists { app.buttons["showPages"].tap() }
        let addPage = app.buttons["addPage"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 10)); addPage.tap()
        XCTAssertTrue(app.buttons["page-2"].waitForExistence(timeout: 10))
        failIfAlert(app, "nova página")
        app.terminate()
        app.launchArguments = ["--no-autofocus", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas-1"].firstMatch.waitForExistence(timeout: 20))
        failIfAlert(app, "recuperação")
        if app.buttons["showPages"].exists { app.buttons["showPages"].tap() }
        XCTAssertTrue(app.buttons["page-2"].waitForExistence(timeout: 10), "A página criada antes de o app ser encerrado não foi recuperada")
    }

    private func insertSticker(_ app: XCUIApplication, _ identifier: String) {
        if app.buttons["showTools"].exists { app.buttons["showTools"].tap() }
        let sticker = app.buttons["Sticker"]
        XCTAssertTrue(sticker.waitForExistence(timeout: 10)); sticker.tap()
        let choice = app.buttons[identifier]
        XCTAssertTrue(choice.waitForExistence(timeout: 10)); choice.tap()
    }

    /// Opening a note: the caret is already in its text and typing goes there right away.
    func testOpeningANoteIsReadyToType() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas-1"].firstMatch.waitForExistence(timeout: 20))
        let focused = app.textViews.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 15), "no text box has the caret after opening")
        app.typeText("Pronto")
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS 'Pronto'")).firstMatch.waitForExistence(timeout: 10))
    }

    /// Post-it and calendar: insert, type in the post-it, double-tap the calendar and pick a day;
    /// the app must stay responsive throughout (both froze on the device on 08/11).
    func testPostItAndCalendarStayResponsive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--no-autofocus", "--ui-testing", "--reset-test-data"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas-1"].firstMatch.waitForExistence(timeout: 20))
        insertSticker(app, "stickyNoteSticker")
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Post-it'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); failIfAlert(app, "post-it")
        // Objects inside the page's scroll view cannot be "scrolled to visible" by AX: tap the spot.
        let inside = note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        inside.tap(); inside.tap()
        app.typeText("Comprar pão")
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS 'Comprar'")).firstMatch.waitForExistence(timeout: 10))
        // Close the keyboard (it covers the bottom toolbar on iPhone).
        let done = app.buttons["Concluir"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        insertSticker(app, "calendarSticker")
        let calendar = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Calendário,'")).firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 10)); failIfAlert(app, "calendário")
        let day = calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        day.doubleTap()
        XCTAssertTrue(app.navigationBars["Data do calendário"].waitForExistence(timeout: 10), "o seletor de data não abriu")
        app.navigationBars["Data do calendário"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        day.doubleTap(); day.doubleTap()
        if app.navigationBars["Data do calendário"].waitForExistence(timeout: 5) { app.navigationBars["Data do calendário"].buttons.element(boundBy: 1).tap() }
        // Still responsive: the options menu opens.
        let options = app.buttons["documentOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Medir desempenho do aparelho"].waitForExistence(timeout: 10))
    }

    func testPagesDrawingAndReopenInAdaptiveEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--no-autofocus", "--ui-testing", "--reset-test-data"]
        app.launch()
        let pages = app.buttons["showPages"]
        let addPage = app.buttons["addPage"]
        XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas-1"].firstMatch.waitForExistence(timeout: 20))
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
        failIfAlert(app, "opções do canvas")
        let pen = app.buttons["tool-pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 10)); pen.tap()
        // Pages are stacked; selecting page 2 scrolls it into view and it has its own canvas.
        let drawing = app.descendants(matching: .any)["drawingCanvas-2"].firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(drawing.frame.minX, 0)
        XCTAssertGreaterThanOrEqual(drawing.frame.minY, 0)
        let start = drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let end = drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: end)
        failIfAlert(app, "desenho")
        let ink = NSPredicate(format: "value != %@", "0 traços")
        expectation(for: ink, evaluatedWith: drawing)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor-native-layout"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
        app.launchArguments = ["--no-autofocus", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["showPages"].waitForExistence(timeout: 10) || app.buttons["addPage"].exists)
        if app.buttons["showPages"].exists { app.buttons["showPages"].tap() }
        XCTAssertTrue(app.buttons["page-2"].waitForExistence(timeout: 10)); app.buttons["page-2"].tap()
        let restored = app.descendants(matching: .any)["drawingCanvas-2"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.value as? String, "1 traços")
    }
}
