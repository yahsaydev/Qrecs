import Foundation
import XCTest
@testable import Qrecs

final class AppPathsAndOfflinePolicyTests: XCTestCase {
    func testPathsUseApplicationSupportSubdirectoriesAndPrepareThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try AppPaths(baseDirectory: root)

        XCTAssertEqual(paths.rootDirectory, root.appendingPathComponent("Qrecs", isDirectory: true))
        XCTAssertEqual(paths.audioCacheDirectory, paths.rootDirectory.appendingPathComponent("AudioCache", isDirectory: true))
        XCTAssertEqual(paths.userDataDirectory, paths.rootDirectory.appendingPathComponent("UserData", isDirectory: true))
        XCTAssertEqual(paths.userDatabaseURL, paths.userDataDirectory.appendingPathComponent("user.sqlite"))

        try paths.prepareDirectories()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioCacheDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.userDataDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPathsRejectNonFileBaseURL() {
        XCTAssertThrowsError(try AppPaths(baseDirectory: URL(string: "https://example.com/support")!))
    }

    func testOfflinePolicyTruthTable() {
        XCTAssertFalse(OfflinePolicy.effectiveOffline(manualOffline: false, networkAvailable: true))
        XCTAssertTrue(OfflinePolicy.effectiveOffline(manualOffline: false, networkAvailable: false))
        XCTAssertTrue(OfflinePolicy.effectiveOffline(manualOffline: true, networkAvailable: true))
        XCTAssertTrue(OfflinePolicy.effectiveOffline(manualOffline: true, networkAvailable: false))
    }

    func testNetworkMonitorStartStopAreIdempotentAndRestartable() async {
        let monitor = NWPathNetworkMonitor()

        await monitor.start()
        await monitor.start()
        await monitor.stop()
        await monitor.stop()
        let availableAfterStop = await monitor.isNetworkAvailable()
        XCTAssertFalse(availableAfterStop)

        await monitor.start()
        await monitor.stop()
        let availableAfterRestart = await monitor.isNetworkAvailable()
        XCTAssertFalse(availableAfterRestart)
    }
}
