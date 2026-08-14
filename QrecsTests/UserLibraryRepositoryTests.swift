import Foundation
import GRDB
import XCTest
@testable import Qrecs

final class UserLibraryRepositoryTests: XCTestCase {
    func testMigrationCreatesExpectedTablesAndColumns() async throws {
        let fixture = try UserLibraryFixture()
        defer { fixture.remove() }
        _ = try GRDBUserLibraryRepository(databaseURL: fixture.databaseURL)

        let queue = try DatabaseQueue(path: fixture.databaseURL.path)
        let favorites = try await queue.read { database in
            try database.columns(in: "favorites").map(\.name)
        }
        let downloads = try await queue.read { database in
            try database.columns(in: "downloads").map(\.name)
        }

        XCTAssertEqual(favorites, ["reciter_id", "created_at"])
        XCTAssertEqual(downloads, ["track_id", "reciter_id", "relative_path", "byte_count", "etag", "updated_at"])
    }

    func testFavoriteSetToggleAndListAreIdempotent() async throws {
        let fixture = try UserLibraryFixture()
        defer { fixture.remove() }
        let repository = try GRDBUserLibraryRepository(databaseURL: fixture.databaseURL)

        try await repository.setFavorite(true, reciterID: "r2")
        try await repository.setFavorite(true, reciterID: "r1")
        try await repository.setFavorite(true, reciterID: "r1")
        let favoritesBeforeToggle = try await repository.favoriteReciterIDs()
        let isFavorite = try await repository.isFavorite(reciterID: "r1")
        XCTAssertEqual(favoritesBeforeToggle, Set(["r1", "r2"]))
        XCTAssertTrue(isFavorite)

        let removed = try await repository.toggleFavorite(reciterID: "r1")
        let restored = try await repository.toggleFavorite(reciterID: "r1")
        XCTAssertFalse(removed)
        XCTAssertTrue(restored)
        try await repository.setFavorite(false, reciterID: "r2")
        let favoritesAfterToggle = try await repository.favoriteReciterIDs()
        XCTAssertEqual(favoritesAfterToggle, Set(["r1"]))
    }

    func testDownloadCRUDIDsGroupsAndTotals() async throws {
        let fixture = try UserLibraryFixture()
        defer { fixture.remove() }
        let repository = try GRDBUserLibraryRepository(databaseURL: fixture.databaseURL)
        let first = CachedDownload(
            trackID: "track-1",
            reciterID: "reciter-1",
            relativePath: "one.mp3",
            byteCount: 10,
            etag: "v1",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let second = CachedDownload(
            trackID: "track-2",
            reciterID: "reciter-1",
            relativePath: "two.mp3",
            byteCount: 20,
            etag: nil,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let third = CachedDownload(
            trackID: "track-3",
            reciterID: "reciter-2",
            relativePath: "three.mp3",
            byteCount: 5,
            etag: nil,
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        try await repository.upsertDownload(first)
        try await repository.upsertDownload(second)
        try await repository.upsertDownload(third)
        let storedFirst = try await repository.download(trackID: "track-1")
        let trackIDs = try await repository.cachedTrackIDs()
        let reciterIDs = try await repository.cachedReciterIDs()
        let initialTotal = try await repository.totalDownloadedBytes()
        XCTAssertEqual(storedFirst, first)
        XCTAssertEqual(trackIDs, Set(["track-1", "track-2", "track-3"]))
        XCTAssertEqual(reciterIDs, Set(["reciter-1", "reciter-2"]))
        XCTAssertEqual(initialTotal, 35)
        let groups = try await repository.downloadGroups()
        XCTAssertEqual(
            groups,
            [
                CachedDownloadGroup(reciterID: "reciter-1", trackCount: 2, byteCount: 30),
                CachedDownloadGroup(reciterID: "reciter-2", trackCount: 1, byteCount: 5),
            ]
        )

        let replacement = CachedDownload(
            trackID: "track-1",
            reciterID: "reciter-2",
            relativePath: "replacement.mp3",
            byteCount: 99,
            etag: "v2",
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        try await repository.upsertDownload(replacement)
        let storedReplacement = try await repository.download(trackID: "track-1")
        let replacementTotal = try await repository.totalDownloadedBytes()
        XCTAssertEqual(storedReplacement, replacement)
        XCTAssertEqual(replacementTotal, 124)

        try await repository.removeDownload(trackID: "track-2")
        let removedDownload = try await repository.download(trackID: "track-2")
        let remainingIDs = try await repository.downloads().map(\.trackID)
        XCTAssertNil(removedDownload)
        XCTAssertEqual(remainingIDs, ["track-1", "track-3"])

        try await repository.removeDownloads(trackIDs: ["track-1", "track-3"])
        let downloadsAfterBatchRemoval = try await repository.downloads()
        XCTAssertTrue(downloadsAfterBatchRemoval.isEmpty)
    }

    func testBatchDownloadRemovalRollsBackEveryRowWhenOneDeleteFails() async throws {
        let fixture = try UserLibraryFixture()
        defer { fixture.remove() }
        let repository = try GRDBUserLibraryRepository(databaseURL: fixture.databaseURL)
        for trackID in ["first", "blocked"] {
            try await repository.upsertDownload(CachedDownload(
                trackID: trackID,
                reciterID: "r1",
                relativePath: "\(trackID).mp3",
                byteCount: 1,
                etag: nil,
                updatedAt: .now
            ))
        }
        let queue = try DatabaseQueue(path: fixture.databaseURL.path)
        try await queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_blocked_download
                BEFORE DELETE ON downloads
                WHEN OLD.track_id = 'blocked'
                BEGIN
                    SELECT RAISE(ABORT, 'blocked for transaction test');
                END
                """)
        }

        do {
            try await repository.removeDownloads(trackIDs: ["first", "blocked"])
            XCTFail("Expected the trigger to abort the batch")
        } catch {
            // The transaction must restore any row deleted before the trigger fired.
        }

        let remainingTrackIDs = try await repository.cachedTrackIDs()
        XCTAssertEqual(remainingTrackIDs, ["first", "blocked"])
    }
}

private struct UserLibraryFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = directory.appendingPathComponent("user.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
