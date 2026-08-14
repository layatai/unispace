import AppKit
import XCTest

final class UniSpaceUITests: XCTestCase {
    @MainActor
    func testApplicationLaunches() {
        let app = launchApp(mode: "--ui-testing-onboarding")
        XCTAssertTrue(app.windows["UniSpace"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.windows["UniSpace"].screenshot())
        screenshot.name = "UniSpace main window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testClosingMainWindowHidesDockIconAndMenuReopensIt() throws {
        let app = launchApp(mode: "--ui-testing-onboarding")

        let window = app.windows["UniSpace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let runningApplication = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.layatai.unispace")
                .filter { !$0.isTerminated }
                .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        )
        XCTAssertEqual(runningApplication.activationPolicy, NSApplication.ActivationPolicy.regular)

        window.buttons[XCUIIdentifierCloseWindow].click()

        let dockIconHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                runningApplication.activationPolicy == NSApplication.ActivationPolicy.accessory
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dockIconHidden], timeout: 5), .completed)
        XCTAssertEqual(app.state, .runningBackground)

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        app.menuItems["Open UniSpace…"].click()

        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(runningApplication.activationPolicy, NSApplication.ActivationPolicy.regular)
        app.terminate()
    }

    @MainActor
    func testJoinWorkspaceOffersTailscaleAddressEntry() {
        let app = launchApp(mode: "--ui-testing-onboarding")

        app.buttons["join-workspace"].click()

        XCTAssertTrue(app.textFields["tailscale-address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connect through Tailscale"].exists)
        app.terminate()
    }

    @MainActor
    func testConfiguredWorkspaceOffersLeaveAction() {
        let app = launchApp(mode: "--ui-testing-configured")

        XCTAssertTrue(app.buttons["leave-workspace"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func launchApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [mode]
        app.launch()
        openMainWindowIfNeeded(in: app)
        return app
    }

    @MainActor
    private func openMainWindowIfNeeded(in app: XCUIApplication) {
        guard !app.windows["UniSpace"].waitForExistence(timeout: 1) else { return }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        app.menuItems["Open UniSpace…"].click()
        XCTAssertTrue(app.windows["UniSpace"].waitForExistence(timeout: 5))
    }
}
