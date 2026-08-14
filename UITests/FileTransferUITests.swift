import XCTest

final class FileTransferUITests: XCTestCase {
    func testTransferCenterOpensFromKeyboardAndShowsProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-configured", "--ui-testing-transfers"]
        app.launch()

        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows["UniSpace Transfers"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["transfer-list"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["send-files"].exists)
        XCTAssertTrue(app.staticTexts["Quarterly Report.pdf"].exists)
        XCTAssertTrue(app.staticTexts["Transferring"].exists)
    }
}
