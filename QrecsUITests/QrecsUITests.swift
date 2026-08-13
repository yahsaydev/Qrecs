import XCTest

final class QrecsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesRootShell() {
        let app = XCUIApplication()

        app.launch()

        XCTAssertTrue(
            app.staticTexts["Your local recordings will appear here."]
                .waitForExistence(timeout: 5)
        )
    }
}
