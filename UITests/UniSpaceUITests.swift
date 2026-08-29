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
    func testHostingGuideOffersMacAndWindowsSetupWithMacifierDownload() {
        let app = launchApp(mode: "--ui-testing-hosting")

        XCTAssertTrue(app.staticTexts["Waiting for another device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add another Mac"].exists)
        XCTAssertTrue(app.staticTexts["Add a Windows PC"].exists)
        let downloadLink = app.descendants(matching: .any)["download-macifier"]
        XCTAssertTrue(downloadLink.exists)
        XCTAssertTrue(downloadLink.isHittable)
        let screenshot = XCTAttachment(screenshot: app.windows["UniSpace"].screenshot())
        screenshot.name = "Mac and Windows pairing guide"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testConfiguredWorkspaceOffersLeaveAction() {
        let app = launchApp(mode: "--ui-testing-configured")

        XCTAssertTrue(app.buttons["leave-workspace"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testConfiguredWorkspaceSurfacesContinuityAndTransfersInSidebar() {
        let app = launchApp(mode: "--ui-testing-configured")

        let continuity = app.staticTexts["section-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 5))
        continuity.click()
        XCTAssertTrue(app.switches["clipboard-sharing-toggle"].waitForExistence(timeout: 5))
        dismissSheetIfPresent("Clipboard sharing unavailable", in: app)

        let transfers = app.staticTexts["section-transfers"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5))
        transfers.click()
        dismissSheetIfPresent("File Transfer", in: app)
        XCTAssertTrue(app.buttons["send-files"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func launchApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [mode, "-ApplePersistenceIgnoreState", "YES"]
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

    @MainActor
    private func dismissSheetIfPresent(_ title: String, in app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 1), sheet.staticTexts[title].exists {
            sheet.buttons["OK"].click()
        }
    }
}
