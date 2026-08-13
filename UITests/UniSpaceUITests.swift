import XCTest

final class UniSpaceUITests: XCTestCase {
    func testApplicationLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5) || app.state == .runningBackground)
        app.terminate()
    }
}
