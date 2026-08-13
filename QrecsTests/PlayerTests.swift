import Foundation
import XCTest
@testable import Qrecs

@MainActor
final class PlayerTests: XCTestCase {
    func testSelectionDoesNotAutoplayAndQueueAdvancesInCanonicalSurahOrder() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(3), makeTrack(115), makeTrack(1), makeTrack(2)]

        player.select(track: tracks[2], queue: tracks, localURLs: [:])

        XCTAssertEqual(player.state.status, .paused)
        XCTAssertEqual(backend.loadedURLs, [tracks[2].url])
        XCTAssertEqual(backend.playCount, 0)
        XCTAssertFalse(ambient.state.isPlaying)

        player.play()
        XCTAssertEqual(player.state.status, .playing)
        XCTAssertEqual(backend.playCount, 1)
        XCTAssertTrue(ambient.state.isPlaying)

        let secondTrack = await stateAfterEvent(backend.endedEvent(), backend: backend, player: player) {
            $0.currentTrack?.surahNumber == 2
        }
        XCTAssertEqual(secondTrack.status, .playing)
        XCTAssertEqual(backend.loadedURLs.last, makeTrack(2).url)

        _ = await stateAfterEvent(backend.endedEvent(), backend: backend, player: player) {
            $0.currentTrack?.surahNumber == 3
        }
        let stopped = await stateAfterEvent(backend.endedEvent(), backend: backend, player: player) {
            $0.status == .stopped
        }
        XCTAssertEqual(stopped.currentTrack?.surahNumber, 3)
        XCTAssertEqual(backend.loadedURLs, [makeTrack(1).url, makeTrack(2).url, makeTrack(3).url])
        XCTAssertFalse(ambient.state.isPlaying)
    }

    func testEndedEventWhilePausedDoesNotAdvanceOrAutoplay() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(1), makeTrack(2)]
        player.select(track: tracks[0], queue: tracks, localURLs: [:])
        let stream = player.updates()

        await backend.send(backend.endedEvent())
        await backend.send(backend.progressEvent(elapsed: 7, duration: 100))

        for await state in stream where state.elapsed == 7 {
            XCTAssertEqual(state.currentTrack, tracks[0])
            XCTAssertEqual(state.status, .paused)
            XCTAssertEqual(backend.loadedURLs, [tracks[0].url])
            XCTAssertEqual(backend.playCount, 0)
            XCTAssertFalse(ambient.state.isPlaying)
            return
        }
        XCTFail("Player stream ended before the progress barrier")
    }

    func testStaleEventsFromPreviousAudioItemDoNotAffectCurrentSelection() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(1), makeTrack(2)]
        player.select(track: tracks[0], queue: tracks, localURLs: [:])
        let staleItemID = backend.latestItemID
        player.select(track: tracks[1], queue: tracks, localURLs: [:])
        let currentItemID = backend.latestItemID
        let stream = player.updates()

        await backend.send(.ended(itemID: staleItemID))
        await backend.send(.failed(itemID: staleItemID, message: "stale failure"))
        await backend.send(.progress(itemID: currentItemID, elapsed: 9, duration: 100))

        for await state in stream where state.elapsed == 9 {
            XCTAssertEqual(state.currentTrack, tracks[1])
            XCTAssertEqual(state.status, .paused)
            XCTAssertEqual(backend.loadedURLs, [tracks[0].url, tracks[1].url])
            XCTAssertFalse(ambient.state.isPlaying)
            return
        }
        XCTFail("Player stream ended before the current-item progress barrier")
    }

    func testPreviousAndNextRespectQueueBoundsAndPreservePauseState() {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(1), makeTrack(2)]

        player.select(track: tracks[0], queue: tracks, localURLs: [:])
        player.previous()
        XCTAssertEqual(player.state.currentTrack?.surahNumber, 1)
        XCTAssertEqual(backend.loadedURLs.count, 1)

        player.next()
        XCTAssertEqual(player.state.currentTrack?.surahNumber, 2)
        XCTAssertEqual(player.state.status, .paused)
        XCTAssertEqual(backend.playCount, 0)

        player.next()
        XCTAssertEqual(player.state.status, .stopped)
        XCTAssertFalse(player.state.canGoNext)

        player.previous()
        XCTAssertEqual(player.state.currentTrack?.surahNumber, 1)
        XCTAssertEqual(player.state.status, .paused)
    }

    func testSelectingAnotherTrackPausesTheWholeActiveMix() {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(1), makeTrack(2)]
        player.select(track: tracks[0], queue: tracks, localURLs: [:])
        player.play()

        player.select(track: tracks[1], queue: tracks, localURLs: [:])

        XCTAssertEqual(player.state.currentTrack, tracks[1])
        XCTAssertEqual(player.state.status, .paused)
        XCTAssertEqual(backend.pauseCount, 1)
        XCTAssertEqual(ambient.pauseCount, 1)
        XCTAssertFalse(ambient.state.isPlaying)
    }

    func testSelectingOutOfRangeTrackLeavesCurrentPlaybackUntouched() {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let current = makeTrack(1)
        player.select(track: current, queue: [current], localURLs: [:])
        player.play()

        let invalid = makeTrack(115)
        player.select(track: invalid, queue: [invalid], localURLs: [:])

        XCTAssertEqual(player.state.currentTrack, current)
        XCTAssertEqual(player.state.status, .playing)
        XCTAssertEqual(backend.loadedURLs, [current.url])
        XCTAssertEqual(backend.pauseCount, 0)
        XCTAssertEqual(ambient.pauseCount, 0)
        XCTAssertTrue(ambient.state.isPlaying)
    }

    func testPauseResumeSeekVolumeAndProgressAreObservable() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(10)
        player.select(track: track, queue: [track], localURLs: [:])

        player.setVolume(0.7)
        player.seek(to: 42)
        player.play()
        player.pause()

        XCTAssertEqual(backend.volumes, [0.7])
        XCTAssertEqual(backend.seeks, [42])
        XCTAssertEqual(backend.pauseCount, 1)
        XCTAssertEqual(ambient.pauseCount, 1)
        XCTAssertEqual(player.state.status, .paused)

        player.play()
        XCTAssertEqual(backend.playCount, 2)
        XCTAssertEqual(ambient.playCount, 2)

        let progressed = await stateAfterEvent(
            backend.progressEvent(elapsed: 12.5, duration: 120),
            backend: backend,
            player: player
        ) { $0.elapsed == 12.5 }
        XCTAssertEqual(progressed.duration, 120)
        XCTAssertEqual(progressed.progress, 12.5 / 120, accuracy: 0.000_001)
    }

    func testRemoteNetworkLossStopsWholeMixAndRetryRestoresPlayback() {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(7)
        player.select(track: track, queue: [track], localURLs: [:])
        player.play()

        player.handleNetworkAvailability(false)

        XCTAssertEqual(player.state.status, .failed(.networkUnavailable))
        XCTAssertTrue(player.state.canRetry)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(ambient.stopCount, 1)

        player.retry()
        XCTAssertEqual(backend.playCount, 1, "Retry remains blocked while offline")

        player.handleNetworkAvailability(true)
        player.retry()
        XCTAssertEqual(player.state.status, .playing)
        XCTAssertEqual(backend.loadedURLs, [track.url, track.url])
        XCTAssertEqual(backend.playCount, 2)
        XCTAssertEqual(ambient.playCount, 2)
    }

    func testPlaybackFailureThenOfflineTransitionPreservesRetryableNetworkFailure() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(7)
        player.select(track: track, queue: [track], localURLs: [:])
        player.play()

        await backend.sendAndWaitUntilConsumed(backend.failedEvent(message: "connection reset"))
        XCTAssertEqual(player.state.status, .failed(.playback("connection reset")))
        player.handleNetworkAvailability(false)

        XCTAssertEqual(player.state.status, .failed(.networkUnavailable))
        XCTAssertTrue(player.state.canRetry)
    }

    func testOfflineTransitionThenPlaybackFailureKeepsNetworkFailure() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(7)
        player.select(track: track, queue: [track], localURLs: [:])
        player.play()

        player.handleNetworkAvailability(false)
        await backend.sendAndWaitUntilConsumed(backend.failedEvent(message: "cancelled by stop"))

        XCTAssertEqual(player.state.status, .failed(.networkUnavailable))
        XCTAssertTrue(player.state.canRetry)
    }

    func testRetryRestoresPositionCapturedBeforeRemoteNetworkLoss() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(7)
        player.select(track: track, queue: [track], localURLs: [:])
        player.play()
        _ = await stateAfterEvent(
            backend.progressEvent(elapsed: 42, duration: 120),
            backend: backend,
            player: player
        ) { $0.elapsed == 42 }

        player.handleNetworkAvailability(false)
        await backend.sendAndWaitUntilConsumed(
            backend.progressEvent(elapsed: 0, duration: 120)
        )
        XCTAssertEqual(player.state.status, .failed(.networkUnavailable))
        XCTAssertEqual(player.state.elapsed, 42)
        player.handleNetworkAvailability(true)
        player.retry()

        XCTAssertEqual(player.state.status, .playing)
        XCTAssertEqual(backend.seeks, [42])
        XCTAssertEqual(player.state.elapsed, 42)
    }

    func testSelectingNextRemoteTrackWhileOfflineResetsRetryPosition() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(1), makeTrack(2)]
        player.select(track: tracks[0], queue: tracks, localURLs: [:])
        player.play()
        _ = await stateAfterEvent(
            backend.progressEvent(elapsed: 42, duration: 120),
            backend: backend,
            player: player
        ) { $0.elapsed == 42 }

        player.handleNetworkAvailability(false)
        player.next()

        XCTAssertEqual(player.state.currentTrack, tracks[1])
        XCTAssertEqual(player.state.status, .failed(.networkUnavailable))
        XCTAssertEqual(player.state.elapsed, 0)
        XCTAssertEqual(player.state.duration, 0)

        player.handleNetworkAvailability(true)
        player.retry()

        XCTAssertEqual(backend.loadedURLs.last, tracks[1].url)
        XCTAssertEqual(backend.seeks, [])
        XCTAssertEqual(player.state.elapsed, 0)
    }

    func testLocalPlaybackContinuesAcrossNetworkLoss() {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(8)
        let localURL = URL(fileURLWithPath: "/tmp/local-008.mp3")
        player.select(track: track, queue: [track], localURLs: [track.id: localURL])
        player.play()

        player.handleNetworkAvailability(false)

        XCTAssertEqual(player.state.status, .playing)
        XCTAssertEqual(player.state.source, .local)
        XCTAssertEqual(backend.loadedURLs, [localURL])
        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertTrue(ambient.state.isPlaying)
    }

    func testInjectedNetworkMonitorDrivesRemoteFailureWithoutPolling() async {
        let backend = FakeQuranAudioBackend()
        let ambient = FakeAmbientMixer()
        let monitor = ControllableNetworkMonitor(initial: true)
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let track = makeTrack(9)
        let states = player.updates()

        player.observeNetwork(using: monitor)
        await monitor.waitUntilUpdatesRequested()
        player.select(track: track, queue: [track], localURLs: [:])
        player.play()
        await monitor.send(false)

        for await state in states where state.status == .failed(.networkUnavailable) {
            XCTAssertEqual(backend.stopCount, 1)
            XCTAssertEqual(ambient.stopCount, 1)
            return
        }
        XCTFail("Player state stream ended before network loss was delivered")
    }

    func testAmbientConfigurationPersistsAcrossAutomaticSurahTransition() async {
        let backend = FakeQuranAudioBackend()
        let ambientBackend = FakeAmbientAudioBackend()
        let ambient = AmbientMixer(backend: ambientBackend)
        let player = QuranPlayer(audio: backend, ambient: ambient)
        let tracks = [makeTrack(1), makeTrack(2)]
        ambient.setEnabled(true, for: .fire)
        ambient.setVolume(0.63, for: .fire)
        ambient.setMasterVolume(0.41)
        player.select(track: tracks[0], queue: tracks, localURLs: [:])
        player.play()

        _ = await stateAfterEvent(backend.endedEvent(), backend: backend, player: player) {
            $0.currentTrack?.surahNumber == 2
        }

        XCTAssertEqual(ambient.state.channels[.fire]?.isEnabled, true)
        XCTAssertEqual(ambient.state.channels[.fire]?.volume, 0.63)
        XCTAssertEqual(ambient.state.masterVolume, 0.41)
        XCTAssertTrue(ambient.state.isPlaying)
        XCTAssertEqual(ambientBackend.playedSounds, [.fire])
        XCTAssertEqual(ambientBackend.startCount, 1, "A track transition must not restart the ambient engine")
    }

    private func stateAfterEvent(
        _ event: QuranAudioEvent,
        backend: FakeQuranAudioBackend,
        player: QuranPlayer,
        matching predicate: @escaping @Sendable (PlayerState) -> Bool
    ) async -> PlayerState {
        let stream = player.updates()
        await backend.send(event)
        for await state in stream where predicate(state) {
            return state
        }
        XCTFail("Player state stream ended before the expected state")
        return player.state
    }
}

@MainActor
private final class FakeQuranAudioBackend: QuranAudioBackend {
    private let eventQueue = TestAudioEventQueue()
    private(set) var loadedURLs: [URL] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var seeks: [TimeInterval] = []
    private(set) var volumes: [Float] = []
    private(set) var loadedItemIDs: [QuranAudioItemID] = []

    var latestItemID: QuranAudioItemID {
        loadedItemIDs.last!
    }

    func load(url: URL, itemID: QuranAudioItemID) {
        loadedURLs.append(url)
        loadedItemIDs.append(itemID)
    }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func stop() { stopCount += 1 }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func setVolume(_ volume: Float) { volumes.append(volume) }
    func events() -> AsyncStream<QuranAudioEvent> {
        let eventQueue = eventQueue
        return AsyncStream(unfolding: { await eventQueue.next() })
    }

    func send(_ event: QuranAudioEvent) async {
        await eventQueue.send(event)
    }

    func sendAndWaitUntilConsumed(_ event: QuranAudioEvent) async {
        await eventQueue.sendAndWaitUntilConsumed(event)
    }

    func endedEvent() -> QuranAudioEvent {
        .ended(itemID: latestItemID)
    }

    func progressEvent(elapsed: TimeInterval, duration: TimeInterval) -> QuranAudioEvent {
        .progress(itemID: latestItemID, elapsed: elapsed, duration: duration)
    }

    func failedEvent(message: String) -> QuranAudioEvent {
        .failed(itemID: latestItemID, message: message)
    }
}

private actor TestAudioEventQueue {
    private enum Entry {
        case event(QuranAudioEvent)
        case consumptionBarrier(CheckedContinuation<Void, Never>)
    }

    private var entries: [Entry] = []
    private var nextWaiter: CheckedContinuation<QuranAudioEvent?, Never>?

    func send(_ event: QuranAudioEvent) {
        entries.append(.event(event))
        deliverIfPossible()
    }

    func sendAndWaitUntilConsumed(_ event: QuranAudioEvent) async {
        await withCheckedContinuation { continuation in
            entries.append(.event(event))
            entries.append(.consumptionBarrier(continuation))
            deliverIfPossible()
        }
    }

    func next() async -> QuranAudioEvent? {
        while !entries.isEmpty {
            switch entries.removeFirst() {
            case let .event(event):
                return event
            case let .consumptionBarrier(continuation):
                continuation.resume()
            }
        }
        return await withCheckedContinuation { continuation in
            nextWaiter = continuation
            deliverIfPossible()
        }
    }

    private func deliverIfPossible() {
        guard let nextWaiter else { return }
        while !entries.isEmpty {
            switch entries.removeFirst() {
            case let .event(event):
                self.nextWaiter = nil
                nextWaiter.resume(returning: event)
                return
            case let .consumptionBarrier(continuation):
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class FakeAmbientMixer: AmbientMixing {
    private(set) var state = AmbientMixState.default
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0

    func updates() -> AsyncStream<AmbientMixState> {
        AsyncStream { $0.yield(state); $0.finish() }
    }

    func setEnabled(_ enabled: Bool, for sound: AmbientSound) {
        state.channels[sound]?.isEnabled = enabled
    }

    func setVolume(_ volume: Float, for sound: AmbientSound) {
        state.channels[sound]?.volume = volume
    }

    func setMasterVolume(_ volume: Float) { state.masterVolume = volume }
    func play() { playCount += 1; state.isPlaying = true }
    func pause() { pauseCount += 1; state.isPlaying = false }
    func stop() { stopCount += 1; state.isPlaying = false }
}

@MainActor
private final class FakeAmbientAudioBackend: AmbientAudioBackend {
    private(set) var startCount = 0
    private(set) var playedSounds: [AmbientSound] = []

    func start() -> Bool { startCount += 1; return true }
    func play(_ sound: AmbientSound) { playedSounds.append(sound) }
    func pause(_ sound: AmbientSound) {}
    func stopAll() {}
    func setVolume(_ volume: Float, for sound: AmbientSound) {}
    func setMasterVolume(_ volume: Float) {}
}

private func makeTrack(_ surah: Int) -> Track {
    Track(
        id: "track-\(surah)",
        reciterID: "reciter",
        surahNumber: surah,
        url: URL(string: "https://example.com/\(surah).mp3")!
    )
}

private actor ControllableNetworkMonitor: NetworkMonitoring {
    private var available: Bool
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private var updatesRequested = false
    private var updatesWaiters: [CheckedContinuation<Void, Never>] = []

    init(initial: Bool) {
        available = initial
        (stream, continuation) = AsyncStream.makeStream()
    }

    func start() {}
    func stop() {}
    func isNetworkAvailable() -> Bool { available }

    func updates() -> AsyncStream<Bool> {
        updatesRequested = true
        continuation.yield(available)
        for waiter in updatesWaiters { waiter.resume() }
        updatesWaiters.removeAll()
        return stream
    }

    func waitUntilUpdatesRequested() async {
        if updatesRequested { return }
        await withCheckedContinuation { updatesWaiters.append($0) }
    }

    func send(_ available: Bool) {
        self.available = available
        continuation.yield(available)
    }
}
