import Foundation

@MainActor
final class AmbientMixer: AmbientMixing {
    private let backend: any AmbientAudioBackend
    private var engineStarted = false
    private var continuations: [UUID: AsyncStream<AmbientMixState>.Continuation] = [:]
    private(set) var state: AmbientMixState

    init(
        backend: any AmbientAudioBackend,
        initialState: AmbientMixState = .default
    ) {
        self.backend = backend
        state = initialState
    }

    func updates() -> AsyncStream<AmbientMixState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AmbientMixState>.makeStream()
        continuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func setEnabled(_ enabled: Bool, for sound: AmbientSound) {
        guard state.channels[sound]?.isEnabled != enabled else { return }
        state.channels[sound]?.isEnabled = enabled
        if state.isPlaying {
            enabled ? backend.play(sound) : backend.pause(sound)
        }
        publish()
    }

    func setVolume(_ volume: Float, for sound: AmbientSound) {
        let volume = Self.clamp(volume)
        state.channels[sound]?.volume = volume
        backend.setVolume(volume, for: sound)
        publish()
    }

    func setMasterVolume(_ volume: Float) {
        let volume = Self.clamp(volume)
        state.masterVolume = volume
        backend.setMasterVolume(volume)
        publish()
    }

    func play() {
        guard !state.isPlaying else { return }
        if !engineStarted {
            guard backend.start() else {
                state.failureMessage = "Unable to start the ambient audio engine."
                publish()
                return
            }
            engineStarted = true
        }
        for sound in AmbientSound.allCases where state.channels[sound]?.isEnabled == true {
            backend.play(sound)
        }
        state.failureMessage = nil
        state.isPlaying = true
        publish()
    }

    func pause() {
        guard state.isPlaying else { return }
        for sound in AmbientSound.allCases where state.channels[sound]?.isEnabled == true {
            backend.pause(sound)
        }
        state.isPlaying = false
        publish()
    }

    func stop() {
        guard engineStarted || state.isPlaying else { return }
        backend.stopAll()
        engineStarted = false
        state.isPlaying = false
        publish()
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private static func clamp(_ volume: Float) -> Float {
        min(max(volume, 0), 1)
    }
}
