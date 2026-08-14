import SwiftUI

struct AuroraPlayerBackground: View {
    let isPlaying: Bool
    let enabledSounds: [AmbientSound]
    let reduceMotion: Bool

    @State private var motion = PlaybackMotionModel(staticPhase: 0.25)
    @State private var pointerOffset = CGSize.zero

    private let fields = [
        AuroraField(x: 0.08, y: 0.18, dx: 0.16, dy: 0.12, speed: 0.83, offset: 0.0, size: 0.72, parallax: 8),
        AuroraField(x: 0.34, y: 0.82, dx: 0.20, dy: 0.16, speed: 0.61, offset: 1.1, size: 0.86, parallax: 5),
        AuroraField(x: 0.56, y: 0.24, dx: 0.18, dy: 0.13, speed: 0.73, offset: 2.4, size: 0.68, parallax: 11),
        AuroraField(x: 0.78, y: 0.70, dx: 0.17, dy: 0.19, speed: 0.52, offset: 3.3, size: 0.82, parallax: 7),
        AuroraField(x: 0.95, y: 0.14, dx: 0.13, dy: 0.12, speed: 0.67, offset: 4.7, size: 0.62, parallax: 13),
        AuroraField(x: 0.50, y: 0.52, dx: 0.25, dy: 0.10, speed: 0.41, offset: 5.5, size: 0.92, parallax: 4),
    ]

    private var fieldColors: [AuroraFieldColor] {
        AuroraPaletteModel.fieldColors(
            enabledAccents: enabledSounds.map(\.accent),
            fieldCount: fields.count
        )
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying || reduceMotion)) { context in
                let phase = motion.phase(
                    at: context.date.timeIntervalSinceReferenceDate,
                    rate: 0.35
                )
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.015, green: 0.15, blue: 0.11, opacity: 0.58),
                            Color(red: 0.02, green: 0.28, blue: 0.20, opacity: 0.42),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        let diameter = max(proxy.size.width, proxy.size.height) * field.size
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [color(for: fieldColors[index]).opacity(0.42), .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: diameter * 0.5
                                )
                            )
                            .frame(width: diameter, height: diameter)
                            .position(
                                x: proxy.size.width * (
                                    field.x + sin(phase * field.speed + field.offset) * field.dx
                                ) + pointerOffset.width * field.parallax,
                                y: proxy.size.height * (
                                    field.y + cos(phase * field.speed * 0.87 + field.offset) * field.dy
                                ) + pointerOffset.height * field.parallax
                            )
                            .blur(radius: diameter * 0.16)
                    }
                }
            }
            .onContinuousHover { hover in
                guard !reduceMotion else {
                    pointerOffset = .zero
                    return
                }
                switch hover {
                case let .active(point):
                    pointerOffset = CGSize(
                        width: point.x / max(proxy.size.width, 1) - 0.5,
                        height: point.y / max(proxy.size.height, 1) - 0.5
                    )
                case .ended:
                    pointerOffset = .zero
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: pointerOffset)
        .onAppear(perform: synchronizeMotion)
        .onChange(of: isPlaying) { _, _ in synchronizeMotion() }
        .onChange(of: reduceMotion) { _, _ in
            if reduceMotion { pointerOffset = .zero }
            synchronizeMotion()
        }
        .accessibilityHidden(true)
    }

    private func synchronizeMotion() {
        motion.transition(
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            at: Date.timeIntervalSinceReferenceDate
        )
    }

    private func color(for fieldColor: AuroraFieldColor) -> Color {
        switch fieldColor {
        case let .emerald(index):
            let emeralds: [Color] = [
                Color(red: 0.03, green: 0.42, blue: 0.29),
                Color(red: 0.06, green: 0.55, blue: 0.38),
                Color(red: 0.08, green: 0.32, blue: 0.25),
            ]
            return emeralds[index % emeralds.count]
        case let .ambient(accent):
            return Color(ambientAccent: accent)
        }
    }
}

private struct AuroraField {
    let x: Double
    let y: Double
    let dx: Double
    let dy: Double
    let speed: Double
    let offset: Double
    let size: Double
    let parallax: Double
}
