import XCTest

final class QrecsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishLaunchShowsNativeLibrarySplit() {
        let app = launch(language: "en")
        XCTAssertTrue(app.splitGroups.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All reciters"].exists)
        XCTAssertTrue(app.staticTexts["Favorites"].exists)
    }

    @MainActor
    func testRussianLaunchOverrideAppliesImmediately() {
        let app = launch(language: "ru")
        XCTAssertTrue(app.splitGroups.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Все чтецы"].exists)
        XCTAssertTrue(app.staticTexts["Избранное"].exists)
    }

    @MainActor
    func testSelectingTrackRevealsPlayerAndSoundsPopover() {
        let app = launch(language: "en")
        XCTAssertTrue(app.outlines["tracks.table"].waitForExistence(timeout: 5))
        app.outlines["tracks.table"].children(matching: .tableRow).element(boundBy: 0).click()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 2))
        app.buttons["player.sounds"].click()
        XCTAssertTrue(app.checkBoxes["sound.fire.enabled"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testOfflineEmptyStateIsVisible() {
        let app = launch(language: "en", additionalArguments: ["--offline-empty"])
        XCTAssertTrue(app.otherElements["offline.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No offline recordings"].exists)
    }

    @MainActor
    func testSettingsHasGeneralCacheAndAboutTabs() {
        let app = launch(language: "en")
        XCTAssertTrue(app.splitGroups.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.scrollViews["settings.tabs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["General"].exists)
        XCTAssertTrue(app.buttons["Cache"].exists)
        XCTAssertTrue(app.buttons["About"].exists)
    }

    @MainActor
    private func launch(
        language: String,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--language=\(language)"] + additionalArguments
        app.launch()
        return app
    }
}
