import SwiftUI

struct PlayingEqualizer: View {
    let isPlaying: Bool
    let reduceMotion: Bool

    @State private var motion = AuroraPhaseController(staticPhase: 0.7)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isPlaying || reduceMotion)) { context in
            let phase = motion.phase(
                at: context.date.timeIntervalSinceReferenceDate,
                rate: 1
            )
            let levels = PlayingEqualizerModel.levels(at: phase)
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: 2.5, height: 4 + levels[index] * 10)
                }
            }
            .frame(width: 14, height: 16)
            .foregroundStyle(.tint)
        }
        .onAppear(perform: synchronizeMotion)
        .onChange(of: isPlaying) { _, _ in synchronizeMotion() }
        .onChange(of: reduceMotion) { _, _ in synchronizeMotion() }
        .accessibilityHidden(true)
    }

    private func synchronizeMotion() {
        motion.transition(
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            at: Date.timeIntervalSinceReferenceDate
        )
    }
}
