import AppKit
import XCTest

final class FileTransferUITests: XCTestCase {
    @MainActor
    func testTransferCenterOpensFromKeyboardAndShowsProgress() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-configured",
            "--ui-testing-transfers",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        app.launch()

        app.typeKey("t", modifierFlags: [.command, .shift])
        let transferWindow = app.windows["UniSpace Transfers"]
        XCTAssertTrue(transferWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["transfer-list"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["send-files"].exists)
        XCTAssertTrue(app.staticTexts["Quarterly Report.pdf"].exists)
        XCTAssertTrue(app.staticTexts["Transferring"].exists)
        transferWindow.buttons[XCUIIdentifierCloseWindow].click()
        app.terminate()
    }
}
