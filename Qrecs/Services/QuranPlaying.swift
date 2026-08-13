import Foundation

struct QuranAudioItemID: Equatable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum QuranAudioEvent: Equatable, Sendable {
    case progress(itemID: QuranAudioItemID, elapsed: TimeInterval, duration: TimeInterval)
    case ended(itemID: QuranAudioItemID)
    case failed(itemID: QuranAudioItemID, message: String)
}

@MainActor
protocol QuranAudioBackend: AnyObject {
    func load(url: URL, itemID: QuranAudioItemID)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    func setVolume(_ volume: Float)
    func events() -> AsyncStream<QuranAudioEvent>
}

@MainActor
protocol QuranPlaying: AnyObject {
    var state: PlayerState { get }

    func updates() -> AsyncStream<PlayerState>
    func select(track: Track, queue: [Track], localURLs: [String: URL])
    func play()
    func pause()
    func stop()
    func previous()
    func next()
    func seek(to seconds: TimeInterval)
    func setVolume(_ volume: Float)
    func handleNetworkAvailability(_ available: Bool)
    func observeNetwork(using monitor: any NetworkMonitoring)
    func retry()
}
