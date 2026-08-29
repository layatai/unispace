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
        let mainWindow = app.windows["UniSpace"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)["transfer-list"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(mainWindow.buttons["send-files"].exists)
        XCTAssertTrue(mainWindow.staticTexts["Quarterly Report.pdf"].exists)
        XCTAssertTrue(mainWindow.staticTexts["Transferring"].exists)
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        app.terminate()
    }
}
