import XCTest

final class UniSpaceUITests: XCTestCase {
    @MainActor
    func testApplicationLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-onboarding"]
        app.launch()
        XCTAssertTrue(app.windows["UniSpace"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "UniSpace main window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testJoinWorkspaceOffersTailscaleAddressEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-onboarding"]
        app.launch()

        app.buttons["join-workspace"].click()

        XCTAssertTrue(app.textFields["tailscale-address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connect through Tailscale"].exists)
        app.terminate()
    }
}
