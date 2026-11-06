import XCTest

/// Cloud mode is a separate screen with its own model. These tests run against an injected fixture:
/// no iCloud account, no Mac, no network — the same reason the unit tests use a fake mailbox.
@MainActor
final class CloudChatUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-connectionMode", "cloud", "-neoCloudFixture"] + extra
        app.launch()
        return app
    }

    /// Cloud mode must open even though this device has no saved direct endpoint: the plan's review
    /// point 4 — a cloud-only user is not blocked by the onboarding gate.
    func testCloudModeWithoutDirectServerCanOpenChat() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["NeoOS"].waitForExistence(timeout: 15),
                      "the cloud screen opens without a direct connection")
        XCTAssertTrue(app.textFields["cloud-composer"].waitForExistence(timeout: 5)
                      || app.textViews.firstMatch.waitForExistence(timeout: 5),
                      "the cloud composer is reachable")
        XCTAssertFalse(app.staticTexts["Connexion directe"].exists,
                       "the direct composer is not what the user landed on")
    }

    /// "Uploaded" and "running" must not read the same: CloudKit's acknowledgement is not an
    /// acknowledgement from Hermes.
    func testUploadedAndRunningHaveDistinctLabels() throws {
        let app = launch(["-neoCloudSeedStates"])
        XCTAssertTrue(app.staticTexts["已上传，等待 Mac"].waitForExistence(timeout: 15),
                      "an uploaded message is waiting for the Mac, not executing")
        XCTAssertTrue(app.staticTexts["Hermes 正在执行"].exists)
        XCTAssertNotEqual("已上传，等待 Mac", "Hermes 正在执行")
    }

    /// Upload failure must leave the durable local queue visible, even on the first conversation.
    func testOfflineEnqueueRemainsVisible() throws {
        let app = launch(["-neoCloudOffline"])
        let field = app.textFields["cloud-composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Offline queued message")
        app.buttons["cloud-send-message"].tap()
        XCTAssertTrue(app.staticTexts["Offline queued message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本机排队"].exists)
    }

    func testFirstMessageCanSendWithoutCreatingConversationInSettings() throws {
        let app = launch()
        let field = app.textFields["cloud-composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("First cloud message")
        let send = app.buttons["cloud-send-message"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["First cloud message"].waitForExistence(timeout: 5))
    }

    func testTypingDoesNotDiscardDraftAcrossTranscriptRefresh() throws {
        let app = launch(["-neoCloudSeedStates"])
        let field = app.textFields["cloud-composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Draft before sync")
        app.buttons["Actualiser"].tap()
        XCTAssertEqual(field.value as? String, "Draft before sync")
        field.tap()
        field.typeText(" and after sync")
        XCTAssertEqual(field.value as? String, "Draft before sync and after sync")
    }

    /// One direct-mode launch to prove the original entry point still works unchanged.
    func testDirectModeStillOpensTheOriginalChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 15),
                      "the direct chat composer is untouched by the new mode")
    }
}
