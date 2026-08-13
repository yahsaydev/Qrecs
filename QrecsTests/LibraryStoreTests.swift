import Combine
import Foundation
import XCTest
@testable import Qrecs

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testStartLoadsCatalogUserStateAndCacheSummary() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()

        XCTAssertEqual(fixture.store.phase, .ready)
        XCTAssertEqual(fixture.store.reciters.map(\.id), ["r1", "r2"])
        XCTAssertEqual(fixture.store.surahs.map(\.number), [1, 2])
        XCTAssertEqual(fixture.store.favorites, ["r2"])
        XCTAssertEqual(fixture.store.cachedCounts, ["r1": 1])
        XCTAssertEqual(fixture.store.totalCachedBytes, 42)
        XCTAssertEqual(fixture.store.cacheGroups, [
            CachedDownloadGroup(reciterID: "r1", trackCount: 1, byteCount: 42),
        ])
        XCTAssertTrue(fixture.store.networkAvailable)
        XCTAssertFalse(fixture.store.effectiveOffline)
    }

    func testSelectingTrackPreparesPlayerWithCachedLocalURLWithoutAutoplay() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        await fixture.store.selectReciter("r1")
        guard let track = fixture.store.tracks.first else {
            return XCTFail("Expected tracks")
        }

        fixture.store.selectTrack(track)

        XCTAssertEqual(fixture.player.selectedTrack, track)
        XCTAssertEqual(fixture.player.selectedQueue.map(\.surahNumber), [1, 2])
        XCTAssertEqual(
            fixture.player.selectedLocalURLs[track.id],
            fixture.paths.audioCacheDirectory.appendingPathComponent("one.mp3")
        )
        XCTAssertEqual(fixture.player.playCount, 0)
        XCTAssertEqual(fixture.store.selectedTrackID, track.id)
    }

    func testNetworkUpdatesDriveEffectiveOfflineAndPlayerWithoutPolling() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        let offline = expectation(description: "store observes network loss")
        let cancellable = fixture.store.$networkAvailable
            .dropFirst()
            .sink { available in
                if !available { offline.fulfill() }
            }

        await fixture.network.send(false)
        await fulfillment(of: [offline], timeout: 1)

        XCTAssertTrue(fixture.store.effectiveOffline)
        XCTAssertEqual(fixture.player.networkAvailability.last, false)
        withExtendedLifetime(cancellable) {}
    }

    func testCacheEventsUpdateTrackStateAndSummaryWithoutPolling() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        await fixture.store.selectReciter("r1")
        let track = fixture.store.tracks[1]
        await fixture.store.cacheTrack(track)
        let cached = CachedDownload(
            trackID: track.id,
            reciterID: track.reciterID,
            relativePath: "two.mp3",
            byteCount: 50,
            etag: nil,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let observed = expectation(description: "cache state observed")
        let cancellable = fixture.store.$cacheStates
            .dropFirst()
            .sink { states in
                if states[track.id] == .cached(cached) { observed.fulfill() }
            }

        await fixture.cache.send(.cached(cached), trackID: track.id)
        await fulfillment(of: [observed], timeout: 1)

        XCTAssertEqual(fixture.store.cacheStates[track.id], .cached(cached))
        withExtendedLifetime(cancellable) {}
    }

    func testCacheCompletionRefreshesSummaryAfterSwitchingReciters() async throws {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        await fixture.store.selectReciter("r1")
        let track = fixture.store.tracks[1]
        await fixture.store.cacheTrack(track)

        await fixture.store.selectReciter("r2")
        let cached = CachedDownload(
            trackID: track.id,
            reciterID: track.reciterID,
            relativePath: "two.mp3",
            byteCount: 50,
            etag: nil,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        await fixture.user.upsertDownload(cached)
        let refreshed = expectation(description: "background cache completion refreshes summary")
        let cancellable = fixture.store.$totalCachedBytes
            .dropFirst()
            .sink { bytes in
                if bytes == 92 { refreshed.fulfill() }
            }

        await fixture.cache.send(.cached(cached), trackID: track.id)
        await fulfillment(of: [refreshed], timeout: 1)

        XCTAssertEqual(fixture.store.cachedCounts, ["r1": 2])
        XCTAssertEqual(fixture.store.cacheGroups, [
            CachedDownloadGroup(reciterID: "r1", trackCount: 2, byteCount: 92),
        ])
        XCTAssertEqual(fixture.store.downloadsByTrack[track.id], cached)
        withExtendedLifetime(cancellable) {}
    }

    func testSelectingReciterDoesNotCreateIdleCacheObservers() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()

        await fixture.store.selectReciter("r1")

        let requestCount = await fixture.cache.eventRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testTerminalCacheObserverFinishesBeforeRetryObserverStarts() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        await fixture.store.selectReciter("r1")
        let track = fixture.store.tracks[1]
        await fixture.store.cacheTrack(track)
        let failed = expectation(description: "first observer publishes terminal failure")
        let failureCancellable = fixture.store.$cacheStates
            .dropFirst()
            .filter { $0[track.id] == .failed(message: "temporary") }
            .prefix(1)
            .sink { _ in failed.fulfill() }
        await fixture.cache.send(.failed(message: "temporary"), trackID: track.id)
        await fulfillment(of: [failed], timeout: 1)

        await fixture.store.retryCache(trackID: track.id)
        let requestCount = await fixture.cache.eventRequestCount()
        XCTAssertEqual(requestCount, 2)
        let cached = CachedDownload(
            trackID: track.id,
            reciterID: track.reciterID,
            relativePath: "two.mp3",
            byteCount: 50,
            etag: nil,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        await fixture.user.upsertDownload(cached)
        let refreshed = expectation(description: "retry observer refreshes summary once")
        let summaryCancellable = fixture.store.$totalCachedBytes.dropFirst().prefix(1).sink { bytes in
            if bytes == 92 { refreshed.fulfill() }
        }

        await fixture.cache.send(.cached(cached), trackID: track.id)
        await fulfillment(of: [refreshed], timeout: 1)

        let groupsInvocationCount = await fixture.user.downloadGroupsInvocationCount()
        XCTAssertEqual(groupsInvocationCount, 2)
        withExtendedLifetime((failureCancellable, summaryCancellable)) {}
    }

    func testRemovingReciterPurgesTerminalFailedTrackState() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        await fixture.store.selectReciter("r1")
        let track = fixture.store.tracks[1]
        await fixture.store.cacheTrack(track)
        let failed = expectation(description: "track reaches terminal failure")
        let cancellable = fixture.store.$cacheStates
            .dropFirst()
            .filter { $0[track.id] == .failed(message: "temporary") }
            .prefix(1)
            .sink { _ in failed.fulfill() }
        await fixture.cache.send(.failed(message: "temporary"), trackID: track.id)
        await fulfillment(of: [failed], timeout: 1)

        await fixture.store.selectReciter("r2")
        await fixture.store.removeCachedReciter("r1")

        XCTAssertNil(fixture.store.cacheStates[track.id])
        withExtendedLifetime(cancellable) {}
    }

    func testPreferenceChangesInvalidateStoreProjection() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        var invalidationCount = 0
        let cancellable = fixture.store.objectWillChange.sink {
            invalidationCount += 1
        }

        fixture.store.preferences.manualOffline = true

        XCTAssertTrue(fixture.store.effectiveOffline)
        XCTAssertGreaterThan(invalidationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testManualOfflineMakesPlayerTreatNetworkAsUnavailable() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()

        fixture.store.preferences.manualOffline = true

        XCTAssertEqual(fixture.player.networkAvailability.last, false)
    }

    func testPlaybackFailureExposesMessageAndRetryThroughStore() async {
        let fixture = makeFixture(networkAvailable: true)
        defer { fixture.player.finishUpdates() }
        await fixture.store.start()
        await fixture.store.selectReciter("r1")
        fixture.store.selectTrack(fixture.store.tracks[0])
        var failedState = fixture.player.state
        failedState.status = .failed(.playback("decoder failed"))
        let observed = expectation(description: "store observes playback failure")
        let cancellable = fixture.store.$playerState.dropFirst().prefix(1).sink { state in
            if state.status == failedState.status { observed.fulfill() }
        }

        fixture.player.send(failedState)
        await fulfillment(of: [observed], timeout: 1)

        XCTAssertEqual(fixture.store.playbackFailureMessage, "decoder failed")
        XCTAssertTrue(fixture.store.playerState.canRetry)
        fixture.store.retryPlayback()
        XCTAssertEqual(fixture.player.retryCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testContainerForwardsReadyStoreChanges() async {
        let fixture = makeFixture(networkAvailable: true)
        await fixture.store.start()
        let container = AppContainer(
            preferences: fixture.store.preferences,
            readyStore: fixture.store
        )
        var invalidationCount = 0
        let cancellable = container.objectWillChange.sink {
            invalidationCount += 1
        }

        fixture.store.reciterSearch = "first"

        XCTAssertGreaterThan(invalidationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    private func makeFixture(networkAvailable: Bool) -> StoreFixture {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = try! AppPaths(baseDirectory: base)
        let reciters = [
            Reciter(id: "r1", sourceNameRU: "Первый", nameRU: "Первый", nameEN: "First"),
            Reciter(id: "r2", sourceNameRU: "Второй", nameRU: "Второй", nameEN: "Second"),
        ]
        let surahs = [
            Surah(number: 1, nameRU: "Первая", nameEN: "First"),
            Surah(number: 2, nameRU: "Вторая", nameEN: "Second"),
        ]
        let tracks = [
            Track(id: "r1:1", reciterID: "r1", surahNumber: 1, url: URL(string: "https://example.com/1.mp3")!),
            Track(id: "r1:2", reciterID: "r1", surahNumber: 2, url: URL(string: "https://example.com/2.mp3")!),
        ]
        let existing = CachedDownload(
            trackID: tracks[0].id,
            reciterID: "r1",
            relativePath: "one.mp3",
            byteCount: 42,
            etag: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let catalog = StoreCatalog(reciters: reciters, surahs: surahs, tracks: ["r1": tracks])
        let user = StoreUserLibrary(favorites: ["r2"], downloads: [existing])
        let cache = StoreCache(states: [tracks[0].id: .cached(existing)])
        let network = StoreNetwork(initial: networkAvailable)
        let player = StorePlayer()
        let ambient = StoreAmbient()
        let defaults = UserDefaults(suiteName: "QrecsTests.Store.\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults, preferredLanguages: ["en"])
        let store = LibraryStore(
            catalog: catalog,
            userLibrary: user,
            cache: cache,
            network: network,
            player: player,
            ambient: ambient,
            paths: paths,
            preferences: preferences
        )
        return StoreFixture(
            store: store, user: user, cache: cache, network: network,
            player: player, paths: paths
        )
    }
}

@MainActor
private struct StoreFixture {
    let store: LibraryStore
    let user: StoreUserLibrary
    let cache: StoreCache
    let network: StoreNetwork
    let player: StorePlayer
    let paths: AppPaths
}

private actor StoreCatalog: CatalogRepository {
    let reciters: [Reciter]
    let surahs: [Surah]
    let tracks: [String: [Track]]

    init(reciters: [Reciter], surahs: [Surah], tracks: [String: [Track]]) {
        self.reciters = reciters
        self.surahs = surahs
        self.tracks = tracks
    }

    func fetchReciters() -> [Reciter] { reciters }
    func fetchSurahs() -> [Surah] { surahs }
    func fetchTracks(reciterID: String) -> [Track] { tracks[reciterID] ?? [] }
}

private actor StoreUserLibrary: UserLibraryRepository {
    var favoriteIDs: Set<String>
    var storedDownloads: [CachedDownload]
    var downloadGroupsCalls = 0

    init(favorites: Set<String>, downloads: [CachedDownload]) {
        favoriteIDs = favorites
        storedDownloads = downloads
    }

    func favoriteReciterIDs() -> Set<String> { favoriteIDs }
    func isFavorite(reciterID: String) -> Bool { favoriteIDs.contains(reciterID) }
    func setFavorite(_ isFavorite: Bool, reciterID: String) {
        if isFavorite {
            favoriteIDs.insert(reciterID)
        } else {
            favoriteIDs.remove(reciterID)
        }
    }
    func toggleFavorite(reciterID: String) -> Bool {
        if favoriteIDs.remove(reciterID) != nil { return false }
        favoriteIDs.insert(reciterID)
        return true
    }
    func downloads() -> [CachedDownload] { storedDownloads }
    func download(trackID: String) -> CachedDownload? { storedDownloads.first { $0.trackID == trackID } }
    func upsertDownload(_ download: CachedDownload) {
        storedDownloads.removeAll { $0.trackID == download.trackID }
        storedDownloads.append(download)
    }
    func removeDownload(trackID: String) { storedDownloads.removeAll { $0.trackID == trackID } }
    func cachedTrackIDs() -> Set<String> { Set(storedDownloads.map(\.trackID)) }
    func cachedReciterIDs() -> Set<String> { Set(storedDownloads.map(\.reciterID)) }
    func totalDownloadedBytes() -> Int64 { storedDownloads.reduce(0) { $0 + $1.byteCount } }
    func downloadGroups() -> [CachedDownloadGroup] {
        downloadGroupsCalls += 1
        return Dictionary(grouping: storedDownloads, by: \.reciterID).map { id, values in
            CachedDownloadGroup(
                reciterID: id,
                trackCount: values.count,
                byteCount: values.reduce(0) { $0 + $1.byteCount }
            )
        }.sorted { $0.reciterID < $1.reciterID }
    }
    func downloadGroupsInvocationCount() -> Int { downloadGroupsCalls }
}

private actor StoreCache: CacheManaging {
    var states: [String: CacheDownloadState]
    var continuations: [String: [AsyncStream<CacheDownloadState>.Continuation]] = [:]
    var eventRequests = 0

    init(states: [String: CacheDownloadState]) { self.states = states }
    func cache(track: Track) {
        states[track.id] = .queued
        continuations[track.id, default: []].forEach { $0.yield(.queued) }
    }
    func cancel(trackID: String) {}
    func retry(trackID: String) {
        states[trackID] = .queued
        continuations[trackID, default: []].forEach { $0.yield(.queued) }
    }
    func remove(trackID: String) { states.removeValue(forKey: trackID) }
    func removeAll(reciterID: String) {}
    func clearAll() { states.removeAll() }
    func totalBytes() -> Int64 { 0 }
    func state(trackID: String) -> CacheDownloadState? { states[trackID] }
    func snapshot() -> CacheSnapshot { CacheSnapshot(states: states) }
    func events(for trackID: String) -> AsyncStream<CacheDownloadState> {
        eventRequests += 1
        let (stream, continuation) = AsyncStream.makeStream(of: CacheDownloadState.self)
        continuations[trackID, default: []].append(continuation)
        if let state = states[trackID] { continuation.yield(state) }
        return stream
    }
    func send(_ state: CacheDownloadState, trackID: String) {
        states[trackID] = state
        continuations[trackID, default: []].forEach { $0.yield(state) }
    }
    func eventRequestCount() -> Int { eventRequests }
}

private actor StoreNetwork: NetworkMonitoring {
    var available: Bool
    var continuations: [AsyncStream<Bool>.Continuation] = []
    init(initial: Bool) { available = initial }
    func start() {}
    func stop() {}
    func isNetworkAvailable() -> Bool { available }
    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        continuations.append(continuation)
        continuation.yield(available)
        return stream
    }
    func send(_ value: Bool) {
        available = value
        continuations.forEach { $0.yield(value) }
    }
}

@MainActor
private final class StorePlayer: QuranPlaying {
    var state = PlayerState.idle
    var continuation: AsyncStream<PlayerState>.Continuation?
    var selectedTrack: Track?
    var selectedQueue: [Track] = []
    var selectedLocalURLs: [String: URL] = [:]
    var playCount = 0
    var networkAvailability: [Bool] = []
    var retryCount = 0
    func updates() -> AsyncStream<PlayerState> {
        AsyncStream {
            continuation = $0
            $0.yield(state)
        }
    }
    func select(track: Track, queue: [Track], localURLs: [String: URL]) {
        selectedTrack = track
        selectedQueue = queue
        selectedLocalURLs = localURLs
        state.currentTrack = track
        state.status = .paused
    }
    func play() { playCount += 1 }
    func pause() {}
    func stop() {}
    func previous() {}
    func next() {}
    func seek(to seconds: TimeInterval) {}
    func setVolume(_ volume: Float) { state.volume = volume }
    func handleNetworkAvailability(_ available: Bool) { networkAvailability.append(available) }
    func observeNetwork(using monitor: any NetworkMonitoring) {}
    func retry() { retryCount += 1 }
    func send(_ state: PlayerState) {
        self.state = state
        continuation?.yield(state)
    }
    func finishUpdates() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class StoreAmbient: AmbientMixing {
    var state = AmbientMixState.default
    func updates() -> AsyncStream<AmbientMixState> { AsyncStream { $0.yield(state) } }
    func setEnabled(_ enabled: Bool, for sound: AmbientSound) { state.channels[sound]?.isEnabled = enabled }
    func setVolume(_ volume: Float, for sound: AmbientSound) { state.channels[sound]?.volume = volume }
    func setMasterVolume(_ volume: Float) { state.masterVolume = volume }
    func play() { state.isPlaying = true }
    func pause() { state.isPlaying = false }
    func stop() { state.isPlaying = false }
}
