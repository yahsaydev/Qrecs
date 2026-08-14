import SwiftUI

struct AuroraPlayerBackground: View {
    let isPlaying: Bool
    let enabledSounds: [AmbientSound]
    let reduceMotion: Bool
    let pointerOffset: CGSize

    @State private var phaseController = AuroraPhaseController(staticPhase: 0.25)

    private var fieldColors: [AuroraFieldColor] {
        AuroraPaletteModel.fieldColors(
            enabledAccents: enabledSounds.map(\.accent),
            fieldCount: AuroraSceneModel.fields.count
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying || reduceMotion)) { context in
            let phase = phaseController.phase(
                at: context.date.timeIntervalSinceReferenceDate,
                rate: 0.35
            )
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let positions = AuroraSceneModel.positions(
                    in: size,
                    phase: phase,
                    pointerOffset: reduceMotion ? .zero : pointerOffset
                )

                for index in AuroraSceneModel.fields.indices {
                    let field = AuroraSceneModel.fields[index]
                    let diameter = field.diameter(in: size)
                    let center = positions[index]
                    let rect = CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: diameter * 0.16))
                        layer.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [
                                    color(for: fieldColors[index]).opacity(0.42),
                                    .clear,
                                ]),
                                center: center,
                                startRadius: 0,
                                endRadius: diameter / 2
                            )
                        )
                    }
                }
            }
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.015, green: 0.15, blue: 0.11, opacity: 0.58),
                        Color(red: 0.02, green: 0.28, blue: 0.20, opacity: 0.42),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .onAppear(perform: synchronizePhase)
        .onChange(of: isPlaying) { _, _ in synchronizePhase() }
        .onChange(of: reduceMotion) { _, _ in synchronizePhase() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func synchronizePhase() {
        phaseController.transition(
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
