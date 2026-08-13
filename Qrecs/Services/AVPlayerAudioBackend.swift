@preconcurrency import AVFoundation
import Foundation

private final class AVTimeObserverToken: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

@MainActor
final class AVPlayerAudioBackend: QuranAudioBackend {
    typealias StatusHandler = @MainActor (AVPlayerItem.Status, String) -> Void
    typealias StatusObservationFactory = (
        AVPlayerItem,
        @escaping StatusHandler
    ) -> NSKeyValueObservation?

    private let player: AVPlayer
    private let statusObservationFactory: StatusObservationFactory
    private var continuations: [UUID: AsyncStream<QuranAudioEvent>.Continuation] = [:]
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: AVTimeObserverToken?
    private var currentItemID: QuranAudioItemID?
    private var hasPublishedFailureForCurrentItem = false

    init(
        player: AVPlayer = AVPlayer(),
        statusObservationFactory: StatusObservationFactory? = nil
    ) {
        self.player = player
        self.statusObservationFactory = statusObservationFactory ?? Self.observeStatus
        timeObserver = AVTimeObserverToken(player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let itemID = self.currentItemID else { return }
                let elapsed = time.seconds.isFinite ? max(time.seconds, 0) : 0
                let rawDuration = self.player.currentItem?.duration.seconds ?? 0
                let duration = rawDuration.isFinite ? max(rawDuration, 0) : 0
                self.publish(.progress(itemID: itemID, elapsed: elapsed, duration: duration))
            }
        })
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver.value)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        statusObservation?.invalidate()
    }

    func load(url: URL, itemID: QuranAudioItemID) {
        removeItemObservers()
        let item = AVPlayerItem(url: url)
        currentItemID = itemID
        hasPublishedFailureForCurrentItem = false
        player.replaceCurrentItem(with: item)
        statusObservation = statusObservationFactory(item) { [weak self, weak item] status, message in
            guard let self,
                  let item,
                  item === self.player.currentItem,
                  itemID == self.currentItemID,
                  status == .failed else { return }
            self.publishFailureOnce(itemID: itemID, message: message)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let item,
                      item === self.player.currentItem,
                      itemID == self.currentItemID else { return }
                self.publish(.ended(itemID: itemID))
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let item,
                      item === self.player.currentItem,
                      itemID == self.currentItemID else { return }
                let error = item.error
                self.publishFailureOnce(
                    itemID: itemID,
                    message: Self.failureMessage(for: error)
                )
            }
        }
    }

    nonisolated static func failureMessage(for error: Error?) -> String {
        error?.localizedDescription ?? ""
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.seek(to: .zero)
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600))
    }

    func setVolume(_ volume: Float) {
        player.volume = min(max(volume, 0), 1)
    }

    func events() -> AsyncStream<QuranAudioEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QuranAudioEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    private func publish(_ event: QuranAudioEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func publishFailureOnce(itemID: QuranAudioItemID, message: String) {
        guard !hasPublishedFailureForCurrentItem else { return }
        hasPublishedFailureForCurrentItem = true
        publish(.failed(itemID: itemID, message: message))
    }

    private static func observeStatus(
        item: AVPlayerItem,
        handler: @escaping StatusHandler
    ) -> NSKeyValueObservation? {
        item.observe(\.status, options: [.initial, .new]) { item, _ in
            let status = item.status
            let message = failureMessage(for: item.error)
            Task { @MainActor in
                handler(status, message)
            }
        }
    }

    private func removeItemObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }
}
