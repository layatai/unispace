import XCTest

final class UniSpaceUITests: XCTestCase {
    @MainActor
    func testApplicationLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows["UniSpace"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "UniSpace main window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}
