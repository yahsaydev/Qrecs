import SwiftUI

struct AmbientSoundsView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(store.preferences.text("Nature sounds"), systemImage: "leaf.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text(store.preferences.text("Master effects volume"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { store.preferences.ambientMasterVolume },
                        set: { store.setAmbientMasterVolume($0) }
                    ),
                    in: 0...1
                )
                .accessibilityLabel(store.preferences.text("Master effects volume"))
            }

            Divider()

            ForEach(AmbientSound.allCases) { sound in
                AmbientChannelView(store: store, sound: sound)
            }

            if store.ambientState.failureMessage != nil {
                Label(
                    store.preferences.text("Audio effects are unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct AmbientChannelView: View {
    @ObservedObject var store: LibraryStore
    let sound: AmbientSound

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { store.preferences.ambientEnabled(sound) },
                    set: { store.setAmbientEnabled($0, sound: sound) }
                )
            ) {
                Label {
                    Text(sound.displayName(language: store.preferences.resolvedLanguage))
                } icon: {
                    Circle()
                        .fill(Color(ambientAccent: sound.accent))
                        .frame(width: 9, height: 9)
                }
            }
            .accessibilityIdentifier("sound.\(sound.rawValue).enabled")

            Slider(
                value: Binding(
                    get: { store.preferences.ambientVolume(sound) },
                    set: { store.setAmbientVolume($0, sound: sound) }
                ),
                in: 0...1
            )
            .disabled(!store.preferences.ambientEnabled(sound))
            .accessibilityLabel(sound.displayName(language: store.preferences.resolvedLanguage))
        }
    }
}
