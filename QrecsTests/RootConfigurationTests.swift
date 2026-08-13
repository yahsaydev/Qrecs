import XCTest
@testable import Qrecs

final class RootConfigurationTests: XCTestCase {
    func testStandardConfigurationUsesProductName() {
        XCTAssertEqual(RootConfiguration.standard.appName, "Qrecs")
    }
}
