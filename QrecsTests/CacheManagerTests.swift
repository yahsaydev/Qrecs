import Foundation
import XCTest
@testable import Qrecs

final class CacheManagerTests: XCTestCase {
    func testCacheFinalizesAtomicallyPersistsMetadataAndExistingTrackIsNoOp() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.remove() }
        let track = makeTrack(id: "track/../unsafe", reciterID: "r1")

        try await fixture.manager.cache(track: track)
        await fixture.downloader.waitUntilStarted(track.url)
        try await fixture.downloader.succeed(track.url, bytes: Data("audio".utf8), etag: "v1")
        let cached = try await fixture.waitUntilCached(track.id)

        XCTAssertEqual(cached.byteCount, 5)
        XCTAssertEqual(cached.etag, "v1")
        XCTAssertFalse(cached.relativePath.contains("/"))
        XCTAssertFalse(cached.relativePath.contains(".."))
        let finalURL = fixture.paths.audioCacheDirectory.appendingPathComponent(cached.relativePath)
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("audio".utf8))
        let stored = try await fixture.repository.download(trackID: track.id)
        XCTAssertEqual(stored, cached)
        XCTAssertEqual(try cacheDirectoryEntries(fixture.paths), [cached.relativePath])

        try await fixture.manager.cache(track: track)
        let startCount = await fixture.downloader.startCount(for: track.url)
        XCTAssertEqual(startCount, 1)
    }

    func testCancelLeavesNoFileOrRowAndRetryCanComplete() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.remove() }
        let track = makeTrack(id: "cancel-me", reciterID: "r1")

        try await fixture.manager.cache(track: track)
        await fixture.downloader.waitUntilStarted(track.url)
        await fixture.manager.cancel(trackID: track.id)

        let state = await fixture.manager.state(trackID: track.id)
        let storedAfterCancellation = try await fixture.repository.download(trackID: track.id)
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(storedAfterCancellation)
        XCTAssertEqual(try cacheDirectoryEntries(fixture.paths), [])

        try await fixture.manager.retry(trackID: track.id)
        await fixture.downloader.waitUntilStartCount(2, for: track.url)
        try await fixture.downloader.succeed(track.url, bytes: Data("retry".utf8), etag: nil)
        _ = try await fixture.waitUntilCached(track.id)
        let startCount = await fixture.downloader.startCount(for: track.url)
        XCTAssertEqual(startCount, 2)
    }

    func testCancelDuringMetadataPersistenceRollsBackFinalFileAndRow() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(repository: repository)
        let downloader = ControllableDownloadClient(
            temporaryDirectory: root.appendingPathComponent("Transfers", isDirectory: true)
        )
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths
        )
        let track = makeTrack(id: "cancel-during-persist", reciterID: "r1")

        try await manager.cache(track: track)
        await downloader.waitUntilStarted(track.url)
        try await downloader.succeed(track.url, bytes: Data("audio".utf8), etag: nil)
        await pausingRepository.waitUntilUpsertStarted()
        let cancellation = Task { await manager.cancel(trackID: track.id) }
        await pausingRepository.waitUntilUpsertCancellation()
        await pausingRepository.resumeUpsert()
        await cancellation.value

        let state = await manager.state(trackID: track.id)
        let stored = try await repository.download(trackID: track.id)
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(stored)
        XCTAssertEqual(try cacheDirectoryEntries(paths), [])
    }

    func testCancelAfterMetadataCommitCompensatesRowAndFinalFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseAfterUpsertCommit: true
        )
        let downloader = ControllableDownloadClient(
            temporaryDirectory: root.appendingPathComponent("Transfers", isDirectory: true)
        )
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths
        )
        let track = makeTrack(id: "cancel-after-commit", reciterID: "r1")

        try await manager.cache(track: track)
        await downloader.waitUntilStarted(track.url)
        try await downloader.succeed(track.url, bytes: Data("audio".utf8), etag: nil)
        await pausingRepository.waitUntilUpsertCommitted()
        let cancellation = Task { await manager.cancel(trackID: track.id) }
        await pausingRepository.waitUntilUpsertCancellation()
        await pausingRepository.resumeAfterUpsertCommit()
        await cancellation.value

        let state = await manager.state(trackID: track.id)
        let stored = try await repository.download(trackID: track.id)
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(stored)
        XCTAssertEqual(try cacheDirectoryEntries(paths), [])
    }

    func testCancelAfterMetadataVerificationStillWinsAndCompensates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseAfterDownloadLookupNumber: 2
        )
        let downloader = ControllableDownloadClient(
            temporaryDirectory: root.appendingPathComponent("Transfers", isDirectory: true)
        )
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths
        )
        let track = makeTrack(id: "cancel-after-verify", reciterID: "r1")

        try await manager.cache(track: track)
        await downloader.waitUntilStarted(track.url)
        try await downloader.succeed(track.url, bytes: Data("audio".utf8), etag: nil)
        await pausingRepository.waitUntilPausedDownloadLookupCompleted()
        let cancellation = Task { await manager.cancel(trackID: track.id) }
        await pausingRepository.waitUntilUpsertCancellation()
        await pausingRepository.resumePausedDownloadLookup()
        await cancellation.value

        let state = await manager.state(trackID: track.id)
        let stored = try await repository.download(trackID: track.id)
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(stored)
        XCTAssertEqual(try cacheDirectoryEntries(paths), [])
    }

    func testTrackReciterAndAllDeletionUpdateFilesystemDatabaseAndTotals() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.remove() }
        let tracks = [
            makeTrack(id: "one", reciterID: "r1"),
            makeTrack(id: "two", reciterID: "r1"),
            makeTrack(id: "three", reciterID: "r2"),
        ]
        for (index, track) in tracks.enumerated() {
            try await fixture.manager.cache(track: track)
            await fixture.downloader.waitUntilStarted(track.url)
            try await fixture.downloader.succeed(track.url, bytes: Data(repeating: UInt8(index), count: index + 2), etag: nil)
            _ = try await fixture.waitUntilCached(track.id)
        }
        let initialTotal = try await fixture.manager.totalBytes()
        XCTAssertEqual(initialTotal, 9)

        try await fixture.manager.remove(trackID: "one")
        let totalAfterTrackRemoval = try await fixture.manager.totalBytes()
        let removedTrack = try await fixture.repository.download(trackID: "one")
        XCTAssertEqual(totalAfterTrackRemoval, 7)
        XCTAssertNil(removedTrack)

        try await fixture.manager.removeAll(reciterID: "r1")
        let totalAfterReciterRemoval = try await fixture.manager.totalBytes()
        let remainingAfterReciterRemoval = try await fixture.repository.cachedTrackIDs()
        XCTAssertEqual(totalAfterReciterRemoval, 4)
        XCTAssertEqual(remainingAfterReciterRemoval, Set(["three"]))

        try await fixture.manager.clearAll()
        let finalTotal = try await fixture.manager.totalBytes()
        let finalTrackIDs = try await fixture.repository.cachedTrackIDs()
        XCTAssertEqual(finalTotal, 0)
        XCTAssertEqual(finalTrackIDs, [])
        XCTAssertEqual(try cacheDirectoryEntries(fixture.paths), [])
    }

    func testCacheDuringClearAllIsCancelledAndCanBeRetriedAfterClear() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseDownloadsCallNumber: 2
        )
        let downloader = ControllableDownloadClient(temporaryDirectory: root.appendingPathComponent("Transfers"))
        let manager = try await CacheManager.make(repository: pausingRepository, downloader: downloader, paths: paths)
        let track = makeTrack(id: "cache-during-clear", reciterID: "r1")

        let clearing = Task { try await manager.clearAll() }
        await pausingRepository.waitUntilDownloadsPaused()
        try await manager.cache(track: track)
        await pausingRepository.resumeDownloads()
        try await clearing.value

        let startsAfterClear = await downloader.startCount(for: track.url)
        XCTAssertEqual(startsAfterClear, 0)
        let cachedTrackIDsAfterClear = try await repository.cachedTrackIDs()
        XCTAssertEqual(cachedTrackIDsAfterClear, [])
        XCTAssertEqual(try cacheDirectoryEntries(paths), [])

        try await manager.retry(trackID: track.id)
        await downloader.waitUntilStarted(track.url)
        try await downloader.succeed(track.url, bytes: Data("retry".utf8), etag: nil)
        _ = try await awaitCached(manager: manager, trackID: track.id)
        let retriedDownload = try await repository.download(trackID: track.id)
        XCTAssertEqual(retriedDownload?.byteCount, 5)
    }

    func testCacheForReciterDuringRemoveAllIsCancelled() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseDownloadsCallNumber: 2
        )
        let downloader = ControllableDownloadClient(temporaryDirectory: root.appendingPathComponent("Transfers"))
        let manager = try await CacheManager.make(repository: pausingRepository, downloader: downloader, paths: paths)
        let oldTrack = makeTrack(id: "old-r1", reciterID: "r1")
        let newTrack = makeTrack(id: "new-r1", reciterID: "r1")
        try await manager.cache(track: oldTrack)
        await downloader.waitUntilStarted(oldTrack.url)
        try await downloader.succeed(oldTrack.url, bytes: Data("old".utf8), etag: nil)
        _ = try await awaitCached(manager: manager, trackID: oldTrack.id)

        let removing = Task { try await manager.removeAll(reciterID: "r1") }
        await pausingRepository.waitUntilDownloadsPaused()
        try await manager.cache(track: newTrack)
        await pausingRepository.resumeDownloads()
        try await removing.value

        let newStarts = await downloader.startCount(for: newTrack.url)
        XCTAssertEqual(newStarts, 0)
        let cachedTrackIDsAfterRemoval = try await repository.cachedTrackIDs()
        XCTAssertEqual(cachedTrackIDsAfterRemoval, [])
        XCTAssertEqual(try cacheDirectoryEntries(paths), [])
    }

    func testCacheSameTrackDuringRemoveDoesNotEscapeDeletion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseFirstRemoveDownload: true
        )
        let downloader = ControllableDownloadClient(temporaryDirectory: root.appendingPathComponent("Transfers"))
        let manager = try await CacheManager.make(repository: pausingRepository, downloader: downloader, paths: paths)
        let track = makeTrack(id: "remove-race", reciterID: "r1")
        try await manager.cache(track: track)
        await downloader.waitUntilStarted(track.url)
        try await downloader.succeed(track.url, bytes: Data("old".utf8), etag: nil)
        _ = try await awaitCached(manager: manager, trackID: track.id)

        let removing = Task { try await manager.remove(trackID: track.id) }
        await pausingRepository.waitUntilRemoveDownloadPaused()
        try await manager.cache(track: track)
        await pausingRepository.resumeRemoveDownload()
        try await removing.value

        let starts = await downloader.startCount(for: track.url)
        XCTAssertEqual(starts, 1)
        let persistedDownload = try await repository.download(trackID: track.id)
        XCTAssertNil(persistedDownload)
        XCTAssertEqual(try cacheDirectoryEntries(paths), [])
    }

    func testClearWaitsForStaleCacheRepositoryMutationBeforeAllowingRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseFirstRemoveDownload: true
        )
        let waitObserver = ReservationWaitObserver()
        let downloader = ControllableDownloadClient(temporaryDirectory: root.appendingPathComponent("Transfers"))
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths,
            reservationWaitObserver: { waitObserver.record(trackID: $0) }
        )
        let track = makeTrack(id: "stale-repository-remove", reciterID: "r1")
        try await repository.upsertDownload(CachedDownload(
            trackID: track.id,
            reciterID: track.reciterID,
            relativePath: CacheManager.finalFileName(trackID: track.id),
            byteCount: 99,
            etag: nil,
            updatedAt: .now
        ))

        let staleCache = Task { try await manager.cache(track: track) }
        await pausingRepository.waitUntilRemoveDownloadPaused()
        let clearing = Task { try await manager.clearAll() }
        waitObserver.waitUntilObserved(trackID: track.id)
        await pausingRepository.resumeRemoveDownload()
        try await clearing.value
        try await manager.retry(trackID: track.id)
        await downloader.waitUntilStarted(track.url)
        try await downloader.succeed(track.url, bytes: Data("fresh".utf8), etag: nil)
        _ = try await awaitCached(manager: manager, trackID: track.id)
        try await staleCache.value

        let persistedDownload = try await repository.download(trackID: track.id)
        XCTAssertEqual(persistedDownload?.byteCount, 5)
        XCTAssertEqual(try cacheDirectoryEntries(paths).count, 1)
    }

    func testStartupReconciliationDeletesMissingRowsOrphansAndStagingButKeepsIndexedFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let keptName = CacheManager.finalFileName(trackID: "kept")
        try Data("kept".utf8).write(to: paths.audioCacheDirectory.appendingPathComponent(keptName))
        try Data("orphan".utf8).write(to: paths.audioCacheDirectory.appendingPathComponent("orphan.mp3"))
        try Data("partial".utf8).write(to: paths.audioCacheDirectory.appendingPathComponent("partial.staging"))
        try Data("transfer".utf8).write(to: paths.audioCacheDirectory.appendingPathComponent("transfer.download"))
        let outsideURL = paths.audioCacheDirectory.deletingLastPathComponent().appendingPathComponent("outside.mp3")
        try Data("outside".utf8).write(to: outsideURL)
        try await repository.upsertDownload(CachedDownload(
            trackID: "kept", reciterID: "r1", relativePath: keptName,
            byteCount: 4, etag: nil, updatedAt: .now
        ))
        try await repository.upsertDownload(CachedDownload(
            trackID: "missing", reciterID: "r1", relativePath: "missing.mp3",
            byteCount: 99, etag: nil, updatedAt: .now
        ))
        try await repository.upsertDownload(CachedDownload(
            trackID: "traversal", reciterID: "r1", relativePath: "../outside.mp3",
            byteCount: 7, etag: nil, updatedAt: .now
        ))
        let downloader = ControllableDownloadClient(temporaryDirectory: root.appendingPathComponent("Transfers"))

        _ = try await CacheManager.make(repository: repository, downloader: downloader, paths: paths)

        let reconciledTrackIDs = try await repository.cachedTrackIDs()
        XCTAssertEqual(reconciledTrackIDs, Set(["kept"]))
        XCTAssertEqual(try cacheDirectoryEntries(paths), [keptName])
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("outside".utf8))
    }

    func testCatalogReconciliationRemovesOnlyStaleDownloadsAndIsIdempotent() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.remove() }
        let valid = makeTrack(id: "valid", reciterID: "r1")
        let stale = makeTrack(id: "stale", reciterID: "r2")

        for track in [valid, stale] {
            let fileName = CacheManager.finalFileName(trackID: track.id)
            try Data(track.id.utf8).write(
                to: fixture.paths.audioCacheDirectory.appendingPathComponent(fileName)
            )
            try await fixture.repository.upsertDownload(CachedDownload(
                trackID: track.id,
                reciterID: track.reciterID,
                relativePath: fileName,
                byteCount: Int64(track.id.utf8.count),
                etag: nil,
                updatedAt: .now
            ))
        }

        try await fixture.manager.reconcile(validTrackIDs: [valid.id])
        try await fixture.manager.reconcile(validTrackIDs: [valid.id])

        let cachedTrackIDs = try await fixture.repository.cachedTrackIDs()
        XCTAssertEqual(cachedTrackIDs, [valid.id])
        XCTAssertEqual(
            try cacheDirectoryEntries(fixture.paths),
            [CacheManager.finalFileName(trackID: valid.id)]
        )
        let state = await fixture.manager.state(trackID: valid.id)
        guard case let .cached(download) = state else {
            return XCTFail("Expected valid download to remain cached")
        }
        XCTAssertEqual(download.trackID, valid.id)
        let staleState = await fixture.manager.state(trackID: stale.id)
        XCTAssertNil(staleState)
    }

    func testCatalogReconciliationNeverTraversesOutsideAudioCache() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.remove() }
        let outsideURL = fixture.paths.audioCacheDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("outside.mp3")
        try Data("outside".utf8).write(to: outsideURL)
        try await fixture.repository.upsertDownload(CachedDownload(
            trackID: "stale-traversal",
            reciterID: "r1",
            relativePath: "../outside.mp3",
            byteCount: 7,
            etag: nil,
            updatedAt: .now
        ))

        try await fixture.manager.reconcile(validTrackIDs: [])

        let staleDownload = try await fixture.repository.download(trackID: "stale-traversal")
        XCTAssertNil(staleDownload)
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("outside".utf8))
    }

    func testCatalogReconciliationRestoresFilesWhenAtomicMetadataRemovalFails() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let failingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            failBatchRemoval: true
        )
        let downloader = ControllableDownloadClient(
            temporaryDirectory: root.appendingPathComponent("Transfers")
        )
        let manager = try await CacheManager.make(
            repository: failingRepository,
            downloader: downloader,
            paths: paths
        )
        let fileName = CacheManager.finalFileName(trackID: "stale")
        let fileURL = paths.audioCacheDirectory.appendingPathComponent(fileName)
        try Data("stale".utf8).write(to: fileURL)
        try await repository.upsertDownload(CachedDownload(
            trackID: "stale",
            reciterID: "r1",
            relativePath: fileName,
            byteCount: 5,
            etag: nil,
            updatedAt: .now
        ))

        do {
            try await manager.reconcile(validTrackIDs: [])
            XCTFail("Expected atomic metadata removal failure")
        } catch CacheReconciliationTestError.batchRemovalFailed {
            // Expected.
        }

        let stored = try await repository.download(trackID: "stale")
        XCTAssertNotNil(stored)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("stale".utf8))
        XCTAssertEqual(try cacheDirectoryEntries(paths), [fileName])
    }

    func testCatalogReconciliationDoesNotSweepAValidDownloadCompletingConcurrently() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseBatchRemoval: true
        )
        let downloader = ControllableDownloadClient(
            temporaryDirectory: paths.audioCacheDirectory
        )
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths
        )
        let track = makeTrack(id: "valid-concurrent", reciterID: "r1")
        try await manager.cache(track: track)
        await downloader.waitUntilStarted(track.url)

        let reconciliation = Task {
            try await manager.reconcile(validTrackIDs: [track.id])
        }
        await pausingRepository.waitUntilBatchRemovalPaused()
        try await downloader.succeed(track.url, bytes: Data("valid".utf8), etag: nil)
        await pausingRepository.resumeBatchRemoval()
        try await reconciliation.value

        let cached = try await awaitCached(manager: manager, trackID: track.id)
        XCTAssertEqual(cached.byteCount, 5)
        let persisted = try await repository.download(trackID: track.id)
        XCTAssertEqual(persisted, cached)
        let downloadsCalls = await pausingRepository.downloadsInvocationCount()
        XCTAssertEqual(
            downloadsCalls,
            2,
            "Reconciliation must not run the directory-wide startup sweep"
        )
    }

    func testCatalogReconciliationAttemptsEveryRollbackAndPreservesMetadataFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            failBatchRemoval: true,
            pauseBatchRemoval: true
        )
        let downloader = ControllableDownloadClient(
            temporaryDirectory: root.appendingPathComponent("Transfers")
        )
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths
        )
        let firstID = "a-stale"
        let collisionID = "z-stale"
        let firstURL = paths.audioCacheDirectory.appendingPathComponent(
            CacheManager.finalFileName(trackID: firstID)
        )
        let collisionURL = paths.audioCacheDirectory.appendingPathComponent(
            CacheManager.finalFileName(trackID: collisionID)
        )
        for (trackID, fileURL) in [(firstID, firstURL), (collisionID, collisionURL)] {
            try Data(trackID.utf8).write(to: fileURL)
            try await repository.upsertDownload(CachedDownload(
                trackID: trackID,
                reciterID: "r1",
                relativePath: fileURL.lastPathComponent,
                byteCount: Int64(trackID.utf8.count),
                etag: nil,
                updatedAt: .now
            ))
        }

        let reconciliation = Task {
            try await manager.reconcile(validTrackIDs: [])
        }
        await pausingRepository.waitUntilBatchRemovalPaused()
        try Data("collision".utf8).write(to: collisionURL)
        await pausingRepository.resumeBatchRemoval()

        let caughtError: Error
        do {
            try await reconciliation.value
            return XCTFail("Expected reconciliation rollback failure")
        } catch {
            caughtError = error
        }

        XCTAssertEqual(try Data(contentsOf: firstURL), Data(firstID.utf8))
        XCTAssertEqual(try Data(contentsOf: collisionURL), Data("collision".utf8))
        let remainingTrackIDs = try await repository.cachedTrackIDs()
        XCTAssertEqual(remainingTrackIDs, [firstID, collisionID])
        XCTAssertTrue(String(describing: caughtError).contains("batchRemovalFailed"))
    }

    func testNeverRunsMoreThanTwoDownloadsConcurrently() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.remove() }
        let tracks = (1...3).map { makeTrack(id: "track-\($0)", reciterID: "r") }

        for track in tracks { try await fixture.manager.cache(track: track) }
        await fixture.downloader.waitUntilStarted(tracks[0].url)
        await fixture.downloader.waitUntilStarted(tracks[1].url)
        let thirdStartCount = await fixture.downloader.startCount(for: tracks[2].url)
        let initialMaximum = await fixture.downloader.maximumConcurrentDownloads()
        XCTAssertEqual(thirdStartCount, 0)
        XCTAssertEqual(initialMaximum, 2)

        try await fixture.downloader.succeed(tracks[0].url, bytes: Data("1".utf8), etag: nil)
        _ = try await fixture.waitUntilCached(tracks[0].id)
        await fixture.downloader.waitUntilStarted(tracks[2].url)
        let finalMaximum = await fixture.downloader.maximumConcurrentDownloads()
        XCTAssertEqual(finalMaximum, 2)
        for track in tracks.dropFirst() {
            try await fixture.downloader.succeed(track.url, bytes: Data(track.id.utf8), etag: nil)
            _ = try await fixture.waitUntilCached(track.id)
        }
        let cachedTrackIDs = try await fixture.repository.cachedTrackIDs()
        XCTAssertEqual(cachedTrackIDs, Set(tracks.map(\.id)))
    }

    func testConcurrentRequestsForSameTrackStartOnlyOneDownload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        let repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let pausingRepository = PausingUserLibraryRepository(
            repository: repository,
            pauseUpserts: false,
            pauseFirstDownloadLookup: true
        )
        let downloader = ControllableDownloadClient(
            temporaryDirectory: root.appendingPathComponent("Transfers", isDirectory: true)
        )
        let manager = try await CacheManager.make(
            repository: pausingRepository,
            downloader: downloader,
            paths: paths
        )
        let track = makeTrack(id: "same-track", reciterID: "r1")

        let firstRequest = Task { try await manager.cache(track: track) }
        await pausingRepository.waitUntilFirstDownloadLookupStarted()
        let secondRequest = Task { try await manager.cache(track: track) }
        try await secondRequest.value
        await pausingRepository.resumeFirstDownloadLookup()
        try await firstRequest.value
        await downloader.waitUntilStarted(track.url)

        let startCount = await downloader.startCount(for: track.url)
        XCTAssertEqual(startCount, 1)
        try await downloader.succeed(track.url, bytes: Data("one".utf8), etag: nil)
        _ = try await awaitCached(manager: manager, trackID: track.id)
        let stored = try await repository.download(trackID: track.id)
        XCTAssertEqual(stored?.byteCount, 3)
        XCTAssertEqual(try cacheDirectoryEntries(paths).count, 1)
    }

    private func makeTrack(id: String, reciterID: String) -> Track {
        Track(
            id: id,
            reciterID: reciterID,
            surahNumber: 1,
            url: URL(string: "https://qrecs.test/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!).mp3")!
        )
    }

    private func cacheDirectoryEntries(_ paths: AppPaths) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.audioCacheDirectory.path).sorted()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class ReservationWaitObserver: @unchecked Sendable {
    private let condition = NSCondition()
    private var observedTrackIDs: Set<String> = []

    func record(trackID: String) {
        condition.lock()
        observedTrackIDs.insert(trackID)
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilObserved(trackID: String) {
        condition.lock()
        while !observedTrackIDs.contains(trackID) { condition.wait() }
        condition.unlock()
    }
}

private enum CacheStateWaitError: Error {
    case terminalState(CacheDownloadState)
    case streamEnded
}

private enum CacheReconciliationTestError: Error {
    case batchRemovalFailed
}

private func awaitCached(
    manager: CacheManager,
    trackID: String
) async throws -> CachedDownload {
    for await state in await manager.events(for: trackID) {
        switch state {
        case let .cached(download):
            return download
        case .cancelled, .failed:
            XCTFail("Reached terminal state while waiting for cached track \(trackID): \(state)")
            throw CacheStateWaitError.terminalState(state)
        case .queued, .downloading:
            continue
        }
    }
    XCTFail("State stream ended before track was cached: \(trackID)")
    throw CacheStateWaitError.streamEnded
}

private struct CacheFixture: Sendable {
    let root: URL
    let paths: AppPaths
    let repository: GRDBUserLibraryRepository
    let downloader: ControllableDownloadClient
    let manager: CacheManager

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = try AppPaths(baseDirectory: root)
        try paths.prepareDirectories()
        repository = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        downloader = ControllableDownloadClient(temporaryDirectory: root.appendingPathComponent("Transfers", isDirectory: true))
        manager = try await CacheManager.make(repository: repository, downloader: downloader, paths: paths)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func waitUntilCached(_ trackID: String) async throws -> CachedDownload {
        try await awaitCached(manager: manager, trackID: trackID)
    }
}

private actor ControllableDownloadClient: DownloadClient {
    private let temporaryDirectory: URL
    private var continuations: [URL: AsyncThrowingStream<DownloadEvent, Error>.Continuation] = [:]
    private var starts: [URL: Int] = [:]
    private var startWaiters: [
        URL: [(expected: Int, continuation: CheckedContinuation<Void, Never>)]
    ] = [:]
    private var active: Set<URL> = []
    private var maximumActive = 0

    init(temporaryDirectory: URL) {
        self.temporaryDirectory = temporaryDirectory
    }

    func events(for url: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        starts[url, default: 0] += 1
        resumeSatisfiedStartWaiters(for: url)
        active.insert(url)
        maximumActive = max(maximumActive, active.count)
        let (stream, continuation) = AsyncThrowingStream<DownloadEvent, Error>.makeStream()
        continuations[url] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.terminated(url) }
        }
        return stream
    }

    func succeed(_ url: URL, bytes: Data, etag: String?) throws {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: fileURL)
        let continuation = continuations.removeValue(forKey: url)
        active.remove(url)
        continuation?.yield(.progress(DownloadProgress(bytesReceived: Int64(bytes.count), totalBytesExpected: Int64(bytes.count))))
        continuation?.yield(.completed(DownloadedFile(fileURL: fileURL, byteCount: Int64(bytes.count), etag: etag)))
        continuation?.finish()
    }

    func startCount(for url: URL) -> Int { starts[url, default: 0] }
    func maximumConcurrentDownloads() -> Int { maximumActive }

    func waitUntilStarted(_ url: URL) async {
        await waitUntilStartCount(1, for: url)
    }

    func waitUntilStartCount(_ expected: Int, for url: URL) async {
        guard starts[url, default: 0] < expected else { return }
        await withCheckedContinuation {
            startWaiters[url, default: []].append((expected, $0))
        }
    }

    private func resumeSatisfiedStartWaiters(for url: URL) {
        guard let waiters = startWaiters.removeValue(forKey: url) else { return }
        var remaining: [(expected: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if starts[url, default: 0] >= waiter.expected {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        if !remaining.isEmpty {
            startWaiters[url] = remaining
        }
    }

    private func terminated(_ url: URL) {
        continuations.removeValue(forKey: url)
        active.remove(url)
    }
}

private actor PausingUserLibraryRepository: UserLibraryRepository {
    private let repository: GRDBUserLibraryRepository
    private let pauseUpserts: Bool
    private let pauseFirstDownloadLookup: Bool
    private let pauseAfterUpsertCommit: Bool
    private let pauseAfterDownloadLookupNumber: Int?
    private let pauseDownloadsCallNumber: Int?
    private let pauseFirstRemoveDownload: Bool
    private let failBatchRemoval: Bool
    private let pauseBatchRemoval: Bool
    private var upsertStarted = false
    private var upsertCancellationObserved = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var downloadLookupCount = 0
    private var downloadLookupStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var downloadLookupResumeContinuation: CheckedContinuation<Void, Never>?
    private var upsertCommitted = false
    private var upsertCommitWaiters: [CheckedContinuation<Void, Never>] = []
    private var upsertCommitResumeContinuation: CheckedContinuation<Void, Never>?
    private var pausedDownloadLookupCompleted = false
    private var pausedDownloadLookupWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedDownloadLookupResumeContinuation: CheckedContinuation<Void, Never>?
    private var downloadsCallCount = 0
    private var downloadsPaused = false
    private var downloadsPausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var downloadsResumeContinuation: CheckedContinuation<Void, Never>?
    private var removeDownloadCallCount = 0
    private var removeDownloadPaused = false
    private var removeDownloadPausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var removeDownloadResumeContinuation: CheckedContinuation<Void, Never>?
    private var batchRemovalPaused = false
    private var batchRemovalPausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var batchRemovalResumeContinuation: CheckedContinuation<Void, Never>?

    init(
        repository: GRDBUserLibraryRepository,
        pauseUpserts: Bool = true,
        pauseFirstDownloadLookup: Bool = false,
        pauseAfterUpsertCommit: Bool = false,
        pauseAfterDownloadLookupNumber: Int? = nil,
        pauseDownloadsCallNumber: Int? = nil,
        pauseFirstRemoveDownload: Bool = false,
        failBatchRemoval: Bool = false,
        pauseBatchRemoval: Bool = false
    ) {
        self.repository = repository
        self.pauseUpserts = pauseUpserts
        self.pauseFirstDownloadLookup = pauseFirstDownloadLookup
        self.pauseAfterUpsertCommit = pauseAfterUpsertCommit
        self.pauseAfterDownloadLookupNumber = pauseAfterDownloadLookupNumber
        self.pauseDownloadsCallNumber = pauseDownloadsCallNumber
        self.pauseFirstRemoveDownload = pauseFirstRemoveDownload
        self.failBatchRemoval = failBatchRemoval
        self.pauseBatchRemoval = pauseBatchRemoval
    }

    func waitUntilUpsertStarted() async {
        if upsertStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resumeUpsert() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func waitUntilUpsertCancellation() async {
        if upsertCancellationObserved { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func waitUntilFirstDownloadLookupStarted() async {
        if downloadLookupCount > 0 { return }
        await withCheckedContinuation { downloadLookupStartedWaiters.append($0) }
    }

    func resumeFirstDownloadLookup() {
        downloadLookupResumeContinuation?.resume()
        downloadLookupResumeContinuation = nil
    }

    func waitUntilUpsertCommitted() async {
        if upsertCommitted { return }
        await withCheckedContinuation { upsertCommitWaiters.append($0) }
    }

    func resumeAfterUpsertCommit() {
        upsertCommitResumeContinuation?.resume()
        upsertCommitResumeContinuation = nil
    }

    func waitUntilPausedDownloadLookupCompleted() async {
        if pausedDownloadLookupCompleted { return }
        await withCheckedContinuation { pausedDownloadLookupWaiters.append($0) }
    }

    func resumePausedDownloadLookup() {
        pausedDownloadLookupResumeContinuation?.resume()
        pausedDownloadLookupResumeContinuation = nil
    }

    func waitUntilDownloadsPaused() async {
        if downloadsPaused { return }
        await withCheckedContinuation { downloadsPausedWaiters.append($0) }
    }

    func resumeDownloads() {
        downloadsResumeContinuation?.resume()
        downloadsResumeContinuation = nil
    }

    func downloadsInvocationCount() -> Int { downloadsCallCount }

    func waitUntilRemoveDownloadPaused() async {
        if removeDownloadPaused { return }
        await withCheckedContinuation { removeDownloadPausedWaiters.append($0) }
    }

    func resumeRemoveDownload() {
        removeDownloadResumeContinuation?.resume()
        removeDownloadResumeContinuation = nil
    }

    func waitUntilBatchRemovalPaused() async {
        if batchRemovalPaused { return }
        await withCheckedContinuation { batchRemovalPausedWaiters.append($0) }
    }

    func resumeBatchRemoval() {
        batchRemovalResumeContinuation?.resume()
        batchRemovalResumeContinuation = nil
    }

    func favoriteReciterIDs() async throws -> Set<String> {
        try await repository.favoriteReciterIDs()
    }

    func isFavorite(reciterID: String) async throws -> Bool {
        try await repository.isFavorite(reciterID: reciterID)
    }

    func setFavorite(_ isFavorite: Bool, reciterID: String) async throws {
        try await repository.setFavorite(isFavorite, reciterID: reciterID)
    }

    func toggleFavorite(reciterID: String) async throws -> Bool {
        try await repository.toggleFavorite(reciterID: reciterID)
    }

    func downloads() async throws -> [CachedDownload] {
        downloadsCallCount += 1
        let result = try await repository.downloads()
        if downloadsCallCount == pauseDownloadsCallNumber {
            downloadsPaused = true
            for waiter in downloadsPausedWaiters { waiter.resume() }
            downloadsPausedWaiters.removeAll()
            await withCheckedContinuation { downloadsResumeContinuation = $0 }
        }
        return result
    }

    func download(trackID: String) async throws -> CachedDownload? {
        downloadLookupCount += 1
        if pauseFirstDownloadLookup, downloadLookupCount == 1 {
            for waiter in downloadLookupStartedWaiters { waiter.resume() }
            downloadLookupStartedWaiters.removeAll()
            await withCheckedContinuation { downloadLookupResumeContinuation = $0 }
        }
        let result = try await repository.download(trackID: trackID)
        if downloadLookupCount == pauseAfterDownloadLookupNumber {
            pausedDownloadLookupCompleted = true
            for waiter in pausedDownloadLookupWaiters { waiter.resume() }
            pausedDownloadLookupWaiters.removeAll()
            await withTaskCancellationHandler {
                await withCheckedContinuation { pausedDownloadLookupResumeContinuation = $0 }
            } onCancel: {
                Task { await self.recordUpsertCancellation() }
            }
        }
        return result
    }

    func upsertDownload(_ download: CachedDownload) async throws {
        if pauseAfterUpsertCommit {
            try await repository.upsertDownload(download)
            upsertCommitted = true
            for waiter in upsertCommitWaiters { waiter.resume() }
            upsertCommitWaiters.removeAll()
            await withTaskCancellationHandler {
                await withCheckedContinuation { upsertCommitResumeContinuation = $0 }
            } onCancel: {
                Task { await self.recordUpsertCancellation() }
            }
            return
        }
        guard pauseUpserts else {
            try await repository.upsertDownload(download)
            return
        }
        upsertStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { resumeContinuation = $0 }
        } onCancel: {
            Task { await self.recordUpsertCancellation() }
        }
        try await repository.upsertDownload(download)
    }

    func removeDownload(trackID: String) async throws {
        removeDownloadCallCount += 1
        if pauseFirstRemoveDownload, removeDownloadCallCount == 1 {
            removeDownloadPaused = true
            for waiter in removeDownloadPausedWaiters { waiter.resume() }
            removeDownloadPausedWaiters.removeAll()
            await withCheckedContinuation { removeDownloadResumeContinuation = $0 }
        }
        try await repository.removeDownload(trackID: trackID)
    }

    func removeDownloads(trackIDs: Set<String>) async throws {
        if pauseBatchRemoval {
            batchRemovalPaused = true
            for waiter in batchRemovalPausedWaiters { waiter.resume() }
            batchRemovalPausedWaiters.removeAll()
            await withCheckedContinuation { batchRemovalResumeContinuation = $0 }
        }
        if failBatchRemoval {
            throw CacheReconciliationTestError.batchRemovalFailed
        }
        try await repository.removeDownloads(trackIDs: trackIDs)
    }

    func cachedTrackIDs() async throws -> Set<String> {
        try await repository.cachedTrackIDs()
    }

    func cachedReciterIDs() async throws -> Set<String> {
        try await repository.cachedReciterIDs()
    }

    func totalDownloadedBytes() async throws -> Int64 {
        try await repository.totalDownloadedBytes()
    }

    func downloadGroups() async throws -> [CachedDownloadGroup] {
        try await repository.downloadGroups()
    }

    private func recordUpsertCancellation() {
        upsertCancellationObserved = true
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
    }
}
