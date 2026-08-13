import Foundation

enum PlaybackSource: Equatable, Sendable {
    case remote
    case local
}

enum PlayerFailure: Equatable, Sendable {
    case networkUnavailable
    case playback(String)

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable: true
        case .playback: false
        }
    }
}

enum PlayerStatus: Equatable, Sendable {
    case idle
    case paused
    case playing
    case stopped
    case failed(PlayerFailure)
}

struct PlayerState: Equatable, Sendable {
    var status: PlayerStatus
    var currentTrack: Track?
    var source: PlaybackSource?
    var elapsed: TimeInterval
    var duration: TimeInterval
    var volume: Float
    var canGoPrevious: Bool
    var canGoNext: Bool

    var canRetry: Bool {
        guard case let .failed(failure) = status else { return false }
        return failure.isRetryable
    }

    var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    static let idle = PlayerState(
        status: .idle,
        currentTrack: nil,
        source: nil,
        elapsed: 0,
        duration: 0,
        volume: 1,
        canGoPrevious: false,
        canGoNext: false
    )
}
