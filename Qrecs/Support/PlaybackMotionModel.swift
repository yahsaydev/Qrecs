import Foundation

struct PlaybackMotionModel: Equatable {
    let staticPhase: Double

    private var accumulatedMotion: TimeInterval = 0
    private var anchorTime: TimeInterval = 0
    private var isPlaying = false
    private var reduceMotion = false

    init(staticPhase: Double = 0) {
        self.staticPhase = staticPhase
    }

    mutating func transition(
        isPlaying: Bool,
        reduceMotion: Bool,
        at timestamp: TimeInterval
    ) {
        accumulatedMotion = motionTime(at: timestamp)
        anchorTime = timestamp
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
    }

    func phase(at timestamp: TimeInterval, rate: Double) -> Double {
        guard !reduceMotion else { return staticPhase }
        return staticPhase + motionTime(at: timestamp) * rate
    }

    private func motionTime(at timestamp: TimeInterval) -> TimeInterval {
        guard isPlaying, !reduceMotion else { return accumulatedMotion }
        return accumulatedMotion + max(0, timestamp - anchorTime)
    }
}

enum PlayingEqualizerModel {
    static func levels(at phase: Double) -> [Double] {
        [0.0, 2.1, 4.2].map { offset in
            0.2 + 0.8 * abs(sin(phase * 2.4 + offset))
        }
    }
}

enum AuroraFieldColor: Equatable {
    case emerald(Int)
    case ambient(AmbientAccent)
}

enum AuroraPaletteModel {
    static func fieldColors(
        enabledAccents: [AmbientAccent],
        fieldCount: Int
    ) -> [AuroraFieldColor] {
        guard fieldCount > 0 else { return [] }
        let ambientFields = enabledAccents.prefix(fieldCount).map(AuroraFieldColor.ambient)
        let emeraldFields = (ambientFields.count..<fieldCount).map {
            AuroraFieldColor.emerald($0 - ambientFields.count)
        }
        return ambientFields + emeraldFields
    }
}
