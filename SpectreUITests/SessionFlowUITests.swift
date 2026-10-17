import XCTest

final class SessionFlowUITests: XCTestCase {
    func testSensorsStayVisibleAndCaptureSaves() {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Sensor permission") { alert in
            let button = alert.buttons["Allow"].exists ? alert.buttons["Allow"] : alert.buttons["OK"]
            if button.exists {
                button.tap()
                return true
            }
            return false
        }
        app.launch()
        app.tap()

        let motion = app.buttons["sensor-deviceMotion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        XCTAssertTrue(
            motion.label.contains("Live") || motion.label.contains("Unavailable")
        )

        let sensitivity = app.descendants(matching: .any)["sensitivity-dial"]
        XCTAssertTrue(sensitivity.waitForExistence(timeout: 2))

        let detections = app.buttons["detections-button"]
        XCTAssertTrue(detections.waitForExistence(timeout: 2))
        detections.tap()

        let leads = app.staticTexts["lead-status"]
        XCTAssertTrue(leads.waitForExistence(timeout: 2))
        XCTAssertTrue(
            leads.label.contains("Set the phone down")
                || leads.label.contains("Learning the room")
                || leads.label.contains("Watching for magnetic")
        )
        app.navigationBars.buttons["Spectre"].tap()

        let clock = app.staticTexts["session-clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 2))
        let started = clock.label
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", started),
            object: clock
        )
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 3), .completed)

        let place = app.textFields["place-name"]
        XCTAssertTrue(place.waitForExistence(timeout: 2))
        place.tap()
        place.typeText("Hallway")
        app.buttons["capture-save"].tap()

        XCTAssertTrue(app.staticTexts["saved-Hallway"].waitForExistence(timeout: 3))
        XCTAssertTrue(motion.exists)
    }
}
