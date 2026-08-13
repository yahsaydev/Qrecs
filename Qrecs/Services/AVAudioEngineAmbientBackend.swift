@preconcurrency import AVFoundation
import Foundation

enum AmbientAudioResourceError: Error, Equatable {
    case missingResource(String)
    case invalidAudio(String)
}

@MainActor
final class AVAudioEngineAmbientBackend: AmbientAudioBackend {
    private let engine: AVAudioEngine
    private var nodes: [AmbientSound: AVAudioPlayerNode] = [:]
    private var buffers: [AmbientSound: AVAudioPCMBuffer] = [:]
    private var scheduled: Set<AmbientSound> = []

    init(bundle: Bundle = .main, engine: AVAudioEngine = AVAudioEngine()) throws {
        self.engine = engine
        for sound in AmbientSound.allCases {
            guard let url = bundle.url(
                forResource: sound.resourceBaseName,
                withExtension: sound.resourceExtension
            ) else {
                throw AmbientAudioResourceError.missingResource(sound.resourceFileName)
            }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  file.length <= AVAudioFramePosition(UInt32.max),
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                  ) else {
                throw AmbientAudioResourceError.invalidAudio(sound.resourceFileName)
            }
            try file.read(into: buffer)
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = AmbientMixState.default.channels[sound]?.volume ?? 0.5
            nodes[sound] = node
            buffers[sound] = buffer
        }
        engine.mainMixerNode.outputVolume = AmbientMixState.default.masterVolume
        engine.prepare()
    }

    func start() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    func play(_ sound: AmbientSound) {
        guard let node = nodes[sound], let buffer = buffers[sound] else { return }
        if !scheduled.contains(sound) {
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            scheduled.insert(sound)
        }
        if !node.isPlaying {
            node.play()
        }
    }

    func pause(_ sound: AmbientSound) {
        nodes[sound]?.pause()
    }

    func stopAll() {
        for node in nodes.values {
            node.stop()
        }
        scheduled.removeAll()
        engine.pause()
    }

    func setVolume(_ volume: Float, for sound: AmbientSound) {
        nodes[sound]?.volume = min(max(volume, 0), 1)
    }

    func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
    }
}
