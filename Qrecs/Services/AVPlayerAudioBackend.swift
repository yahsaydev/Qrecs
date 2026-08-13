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
    private let player: AVPlayer
    private var continuations: [UUID: AsyncStream<QuranAudioEvent>.Continuation] = [:]
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: AVTimeObserverToken?
    private var currentItemID: QuranAudioItemID?

    init(player: AVPlayer = AVPlayer()) {
        self.player = player
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
    }

    func load(url: URL, itemID: QuranAudioItemID) {
        removeItemObservers()
        let item = AVPlayerItem(url: url)
        currentItemID = itemID
        player.replaceCurrentItem(with: item)
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
                self.publish(.failed(
                    itemID: itemID,
                    message: Self.failureMessage(for: error)
                ))
            }
        }
    }

    static func failureMessage(for error: Error?) -> String {
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

    private func removeItemObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }
}
