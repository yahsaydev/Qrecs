import Foundation

@MainActor
protocol AmbientMixing: AnyObject {
    var state: AmbientMixState { get }

    func updates() -> AsyncStream<AmbientMixState>
    func setEnabled(_ enabled: Bool, for sound: AmbientSound)
    func setVolume(_ volume: Float, for sound: AmbientSound)
    func setMasterVolume(_ volume: Float)
    func play()
    func pause()
    func stop()
}

@MainActor
protocol AmbientAudioBackend: AnyObject {
    func start() -> Bool
    func play(_ sound: AmbientSound)
    func pause(_ sound: AmbientSound)
    func stopAll()
    func setVolume(_ volume: Float, for sound: AmbientSound)
    func setMasterVolume(_ volume: Float)
}
