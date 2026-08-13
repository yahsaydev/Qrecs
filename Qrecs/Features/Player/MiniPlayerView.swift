import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var soundsPresented = false

    private var currentSurah: Surah? {
        guard let number = store.playerState.currentTrack?.surahNumber else { return nil }
        return store.surahs.first { $0.number == number }
    }

    private var currentReciter: Reciter? {
        guard let id = store.playerState.currentTrack?.reciterID else { return nil }
        return store.reciters.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentSurah?.displayName(
                    language: store.preferences.resolvedLanguage
                ) ?? store.preferences.text("Surah"))
                    .font(.headline)
                    .lineLimit(1)
                Text(currentReciter?.displayName(
                    language: store.preferences.resolvedLanguage
                ) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let failureMessage = store.playbackFailureMessage {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .accessibilityIdentifier("player.failure")
                }
            }
            .frame(width: 180, alignment: .leading)

            Button(action: store.previous) {
                Image(systemName: "backward.fill")
            }
            .disabled(!store.playerState.canGoPrevious)
            .help(store.preferences.text("Previous"))
            .accessibilityLabel(store.preferences.text("Previous"))

            Button(action: store.playPause) {
                Image(systemName: store.playerState.status == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .help(store.preferences.text(
                store.playerState.status == .playing ? "Pause" : "Play"
            ))
            .accessibilityIdentifier("player.playPause")

            Button(action: store.next) {
                Image(systemName: "forward.fill")
            }
            .disabled(!store.playerState.canGoNext)
            .help(store.preferences.text("Next"))
            .accessibilityLabel(store.preferences.text("Next"))

            Text(time(store.playerState.elapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { store.playerState.elapsed },
                    set: { store.seek(to: $0) }
                ),
                in: 0...max(store.playerState.duration, 1)
            )
            .accessibilityLabel(store.preferences.text("Surah"))

            Text(time(store.playerState.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { store.preferences.quranVolume },
                    set: { store.setQuranVolume($0) }
                ),
                in: 0...1
            )
            .frame(width: 90)
            .accessibilityLabel(store.preferences.text("Quran volume"))

            if store.playerState.canRetry {
                Button(store.preferences.text("Retry"), action: store.retryPlayback)
                    .accessibilityIdentifier("player.retry")
            }

            Button {
                soundsPresented.toggle()
            } label: {
                Label(store.preferences.text("Sounds"), systemImage: "leaf.fill")
            }
            .accessibilityIdentifier("player.sounds")
            .popover(isPresented: $soundsPresented, arrowEdge: .top) {
                AmbientSoundsView(store: store)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            PlayerGradientBackground(
                isPlaying: store.playerState.status == .playing,
                enabledSounds: AmbientSound.allCases.filter {
                    store.preferences.ambientEnabled($0)
                },
                reduceMotion: reduceMotion
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .qrecsGlass(cornerRadius: 18)
    }

    private func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerGradientBackground: View {
    let isPlaying: Bool
    let enabledSounds: [AmbientSound]
    let reduceMotion: Bool

    private var colors: [Color] {
        [.init(red: 0.04, green: 0.40, blue: 0.29, opacity: 0.34)]
            + enabledSounds.map { Color(ambientAccent: $0.accent).opacity(0.34) }
            + [.clear]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying || reduceMotion)) { context in
            let phase = isPlaying && !reduceMotion
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8
                : 0.25
            LinearGradient(
                colors: colors,
                startPoint: UnitPoint(x: phase, y: 0),
                endPoint: UnitPoint(x: 1 - phase, y: 1)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
