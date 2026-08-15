import SwiftUI

enum PlayerSurfaceLayer: Double, CaseIterable {
    case aurora = 0
    case glass = 1
    case controls = 2

    static var backToFront: [PlayerSurfaceLayer] { allCases }
    var zIndex: Double { rawValue }
}

enum AuroraParallaxAnimationPolicy {
    static let animation: Animation? = nil
}

enum MiniPlayerLayout {
    static let surfaceHeight: CGFloat = 54
    static let metadataLineLimit = 2
}

struct MiniPlayerView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var soundsPresented = false
    @State private var playerSize = CGSize(width: 1, height: 1)
    @State private var parallax = AuroraParallaxController()

    private var isPlaying: Bool {
        store.playerState.status == .playing
    }

    private var currentSurah: Surah? {
        guard let number = store.playerState.currentTrack?.surahNumber else { return nil }
        return store.surahs.first { $0.number == number }
    }

    private var currentReciter: Reciter? {
        guard let id = store.playerState.currentTrack?.reciterID else { return nil }
        return store.reciters.first { $0.id == id }
    }

    var body: some View {
        PlayerSurface(
            isPlaying: isPlaying,
            enabledSounds: AmbientSound.allCases.filter {
                store.preferences.ambientEnabled($0)
            },
            reduceMotion: reduceMotion,
            pointerOffset: parallax.pointerOffset
        ) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(
                        currentSurah?.displayName(
                            language: store.preferences.resolvedLanguage
                        ) ?? store.preferences.text("Surah")
                    )
                    .font(.headline)
                    .lineLimit(1)
                    if let failureMessage = store.playbackFailureMessage {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(MiniPlayerLayout.metadataLineLimit - 1)
                            .accessibilityIdentifier("player.failure")
                    } else {
                        Text(
                            currentReciter?.displayName(
                                language: store.preferences.resolvedLanguage
                            ) ?? ""
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(MiniPlayerLayout.metadataLineLimit - 1)
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
                    Image(
                        systemName: store.playerState.status == .playing
                            ? "pause.fill" : "play.fill"
                    )
                    .frame(width: 18)
                }
                .buttonStyle(.borderedProminent)
                .help(
                    store.preferences.text(
                        store.playerState.status == .playing ? "Pause" : "Play"
                    )
                )
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
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                playerSize = newSize
            }
            .onContinuousHover(perform: updateParallax)
            .onAppear(perform: synchronizeParallax)
            .onChange(of: isPlaying) { _, _ in synchronizeParallax() }
            .onChange(of: reduceMotion) { _, _ in synchronizeParallax() }
            .animation(AuroraParallaxAnimationPolicy.animation, value: parallax.pointerOffset)
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func updateParallax(_ hover: HoverPhase) {
        switch hover {
        case .active(let point):
            parallax.update(
                pointerOffset: CGSize(
                    width: point.x / max(playerSize.width, 1) - 0.5,
                    height: point.y / max(playerSize.height, 1) - 0.5
                )
            )
        case .ended:
            parallax.update(pointerOffset: .zero)
        }
    }

    private func synchronizeParallax() {
        parallax.transition(isPlaying: isPlaying, reduceMotion: reduceMotion)
    }
}

private struct PlayerSurface<Controls: View>: View {
    let isPlaying: Bool
    let enabledSounds: [AmbientSound]
    let reduceMotion: Bool
    let pointerOffset: CGSize
    let controls: Controls

    private let cornerRadius: CGFloat = 18

    init(
        isPlaying: Bool,
        enabledSounds: [AmbientSound],
        reduceMotion: Bool,
        pointerOffset: CGSize,
        @ViewBuilder controls: () -> Controls
    ) {
        self.isPlaying = isPlaying
        self.enabledSounds = enabledSounds
        self.reduceMotion = reduceMotion
        self.pointerOffset = pointerOffset
        self.controls = controls()
    }

    var body: some View {
        ZStack {
            AuroraPlayerBackground(
                isPlaying: isPlaying,
                enabledSounds: enabledSounds,
                reduceMotion: reduceMotion,
                pointerOffset: pointerOffset
            )
            .zIndex(PlayerSurfaceLayer.aurora.zIndex)

            PlayerGlassOverlay(cornerRadius: cornerRadius)
                .zIndex(PlayerSurfaceLayer.glass.zIndex)

            controls
                .zIndex(PlayerSurfaceLayer.controls.zIndex)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .frame(height: MiniPlayerLayout.surfaceHeight)
        .accessibilityIdentifier("player.surface")
    }
}

private struct PlayerGlassOverlay: View {
    let cornerRadius: CGFloat

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .allowsHitTesting(false)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.35), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
        }
    }
}
