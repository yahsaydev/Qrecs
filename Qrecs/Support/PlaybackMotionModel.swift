import Foundation

struct AuroraPhaseController: Equatable {
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

struct AuroraParallaxController: Equatable {
    private(set) var pointerOffset = CGSize.zero

    private var isPlaying = false
    private var reduceMotion = false

    mutating func transition(isPlaying: Bool, reduceMotion: Bool) {
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        if reduceMotion { pointerOffset = .zero }
    }

    mutating func update(pointerOffset: CGSize) {
        guard isPlaying, !reduceMotion else { return }
        self.pointerOffset = pointerOffset
    }
}

struct AuroraField: Equatable, Sendable {
    let x: Double
    let y: Double
    let dx: Double
    let dy: Double
    let speed: Double
    let offset: Double
    let size: Double
    let parallax: Double

    func position(
        in canvasSize: CGSize,
        phase: Double,
        pointerOffset: CGSize
    ) -> CGPoint {
        CGPoint(
            x: canvasSize.width * (x + sin(phase * speed + offset) * dx)
                + pointerOffset.width * parallax,
            y: canvasSize.height * (y + cos(phase * speed * 0.87 + offset) * dy)
                + pointerOffset.height * parallax
        )
    }

    func diameter(in canvasSize: CGSize) -> CGFloat {
        max(canvasSize.width, canvasSize.height) * size
    }
}

enum AuroraSceneModel {
    static let fields = [
        AuroraField(x: 0.08, y: 0.18, dx: 0.16, dy: 0.12, speed: 0.83, offset: 0.0, size: 0.72, parallax: 8),
        AuroraField(x: 0.34, y: 0.82, dx: 0.20, dy: 0.16, speed: 0.61, offset: 1.1, size: 0.86, parallax: 5),
        AuroraField(x: 0.56, y: 0.24, dx: 0.18, dy: 0.13, speed: 0.73, offset: 2.4, size: 0.68, parallax: 11),
        AuroraField(x: 0.78, y: 0.70, dx: 0.17, dy: 0.19, speed: 0.52, offset: 3.3, size: 0.82, parallax: 7),
        AuroraField(x: 0.95, y: 0.14, dx: 0.13, dy: 0.12, speed: 0.67, offset: 4.7, size: 0.62, parallax: 13),
        AuroraField(x: 0.50, y: 0.52, dx: 0.25, dy: 0.10, speed: 0.41, offset: 5.5, size: 0.92, parallax: 4),
    ]

    static func positions(
        in canvasSize: CGSize,
        phase: Double,
        pointerOffset: CGSize
    ) -> [CGPoint] {
        fields.map {
            $0.position(
                in: canvasSize,
                phase: phase,
                pointerOffset: pointerOffset
            )
        }
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
