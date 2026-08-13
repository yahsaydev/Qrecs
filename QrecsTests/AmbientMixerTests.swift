import XCTest
@testable import Qrecs

@MainActor
final class AmbientMixerTests: XCTestCase {
    func testToggleAndVolumesAreAppliedIndependently() {
        let backend = RecordingAmbientBackend()
        let mixer = AmbientMixer(backend: backend)

        mixer.setEnabled(true, for: .rain)
        mixer.setVolume(0.72, for: .rain)
        mixer.setMasterVolume(0.55)

        XCTAssertEqual(mixer.state.channels[.rain], AmbientChannelState(isEnabled: true, volume: 0.72))
        XCTAssertEqual(mixer.state.channels[.fire], AmbientChannelState(isEnabled: false, volume: 0.5))
        XCTAssertEqual(mixer.state.masterVolume, 0.55)
        XCTAssertEqual(backend.volumes[.rain], 0.72)
        XCTAssertEqual(backend.masterVolumes, [0.5, 0.55])
        XCTAssertEqual(backend.played, [], "Enabling a sound must not autoplay the app")
    }

    func testInitialStateIsClampedAndAppliedToAudioBackend() {
        let backend = RecordingAmbientBackend()
        var initial = AmbientMixState.default
        initial.channels[.fire]?.volume = 0.82
        initial.channels[.rain]?.volume = -0.3
        initial.masterVolume = 1.4

        let mixer = AmbientMixer(backend: backend, initialState: initial)

        XCTAssertEqual(mixer.state.channels[.fire]?.volume, 0.82)
        XCTAssertEqual(mixer.state.channels[.rain]?.volume, 0)
        XCTAssertEqual(mixer.state.masterVolume, 1)
        XCTAssertEqual(backend.volumes.count, AmbientSound.allCases.count)
        XCTAssertEqual(backend.volumes[.fire], 0.82)
        XCTAssertEqual(backend.volumes[.rain], 0)
        XCTAssertEqual(backend.masterVolumes, [1])
    }

    func testPlayPauseStopCoordinateEnabledChannelsAndKeepConfiguration() {
        let backend = RecordingAmbientBackend()
        let mixer = AmbientMixer(backend: backend)
        mixer.setEnabled(true, for: .birds)
        mixer.setEnabled(true, for: .waterfall)

        mixer.play()
        XCTAssertTrue(mixer.state.isPlaying)
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.played, [.birds, .waterfall])

        mixer.pause()
        XCTAssertFalse(mixer.state.isPlaying)
        XCTAssertEqual(backend.paused, [.birds, .waterfall])

        mixer.play()
        XCTAssertEqual(backend.startCount, 1, "Paused engine must resume without a second start")
        mixer.stop()
        XCTAssertFalse(mixer.state.isPlaying)
        XCTAssertEqual(backend.stopAllCount, 1)
        XCTAssertEqual(mixer.state.channels[.birds]?.isEnabled, true)
        XCTAssertEqual(mixer.state.channels[.waterfall]?.isEnabled, true)
    }

    func testToggleWhilePlayingStartsAndPausesOnlyChangedChannel() {
        let backend = RecordingAmbientBackend()
        let mixer = AmbientMixer(backend: backend)
        mixer.play()

        mixer.setEnabled(true, for: .fire)
        mixer.setEnabled(true, for: .rain)
        mixer.setEnabled(false, for: .fire)

        XCTAssertEqual(backend.played, [.fire, .rain])
        XCTAssertEqual(backend.paused, [.fire])
        XCTAssertTrue(mixer.state.isPlaying)
    }

    func testStateStreamPublishesChangesWithoutPolling() async {
        let backend = RecordingAmbientBackend()
        let mixer = AmbientMixer(backend: backend)
        let stream = mixer.updates()

        mixer.setEnabled(true, for: .birds)

        for await state in stream where state.channels[.birds]?.isEnabled == true {
            XCTAssertEqual(state.channels[.birds]?.volume, 0.5)
            return
        }
        XCTFail("Ambient state stream ended unexpectedly")
    }
}

@MainActor
private final class RecordingAmbientBackend: AmbientAudioBackend {
    private(set) var startCount = 0
    private(set) var played: [AmbientSound] = []
    private(set) var paused: [AmbientSound] = []
    private(set) var stopAllCount = 0
    private(set) var volumes: [AmbientSound: Float] = [:]
    private(set) var masterVolumes: [Float] = []

    func start() -> Bool { startCount += 1; return true }
    func play(_ sound: AmbientSound) { played.append(sound) }
    func pause(_ sound: AmbientSound) { paused.append(sound) }
    func stopAll() { stopAllCount += 1 }
    func setVolume(_ volume: Float, for sound: AmbientSound) { volumes[sound] = volume }
    func setMasterVolume(_ volume: Float) { masterVolumes.append(volume) }
}
