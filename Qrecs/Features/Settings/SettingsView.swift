import SwiftUI

struct SettingsView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        TabView {
            GeneralSettingsView(container: container, preferences: preferences)
                .tabItem { Label(preferences.text("General"), systemImage: "gearshape") }

            CacheSettingsView(container: container, preferences: preferences)
                .tabItem { Label(preferences.text("Cache"), systemImage: "internaldrive") }

            AboutSettingsView(container: container, preferences: preferences)
                .tabItem { Label(preferences.text("About"), systemImage: "info.circle") }
        }
        .frame(width: 540, height: 390)
        .scenePadding()
        .environment(\.locale, preferences.resolvedLanguage.locale)
        .accessibilityIdentifier("settings.tabs")
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Picker(preferences.text("Language"), selection: $preferences.language) {
                Text(preferences.text("System")).tag(AppLanguage.system)
                Text(preferences.text("Russian")).tag(AppLanguage.russian)
                Text(preferences.text("English")).tag(AppLanguage.english)
            }

            Picker(preferences.text("Theme"), selection: $preferences.theme) {
                Text(preferences.text("System")).tag(AppTheme.system)
                Text(preferences.text("Light")).tag(AppTheme.light)
                Text(preferences.text("Dark")).tag(AppTheme.dark)
            }
            .accessibilityIdentifier("settings.theme")

            Toggle(preferences.text("Manual offline mode"), isOn: $preferences.manualOffline)

            LabeledContent(preferences.text("Effective offline mode")) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(container.store?.effectiveOffline == true ? .orange : .green)
                        .frame(width: 8, height: 8)
                    Text(container.store?.effectiveOffline == true
                        ? preferences.text("Offline")
                        : preferences.text("Online"))
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.general")
    }
}

private struct CacheSettingsView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var preferences: AppPreferences
    @State private var confirmClear = false

    var body: some View {
        Form {
            LabeledContent(preferences.text("Total cache")) {
                Text(ByteCountFormatter.string(
                    fromByteCount: container.store?.totalCachedBytes ?? 0,
                    countStyle: .file
                ))
            }

            if let store = container.store, !store.cacheGroups.isEmpty {
                Section {
                    ForEach(store.cacheGroups, id: \.reciterID) { group in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(store.reciters.first { $0.id == group.reciterID }?
                                    .displayName(language: preferences.resolvedLanguage)
                                    ?? group.reciterID)
                                Text("\(group.trackCount) · \(ByteCountFormatter.string(fromByteCount: group.byteCount, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(preferences.text("Remove"), role: .destructive) {
                                Task { await store.removeCachedReciter(group.reciterID) }
                            }
                        }
                    }
                }
            } else {
                Text(preferences.text("Cache is empty"))
                    .foregroundStyle(.secondary)
            }

            Button(preferences.text("Clear all cache"), role: .destructive) {
                confirmClear = true
            }
            .disabled((container.store?.totalCachedBytes ?? 0) == 0)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            preferences.text("Clear cache?"),
            isPresented: $confirmClear
        ) {
            Button(preferences.text("Clear all cache"), role: .destructive) {
                Task { await container.store?.clearCache() }
            }
        } message: {
            Text(preferences.text("This cannot be undone."))
        }
        .accessibilityIdentifier("settings.cache")
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Qrecs").font(.title2.weight(.semibold))
                    Text("\(preferences.text("Version")) \(version)")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent(preferences.text("Catalog")) {
                Text("\(container.store?.reciters.count ?? 0) · \(container.store?.surahs.count ?? 0)")
            }

            Section(preferences.text("CC0 nature sounds")) {
                ForEach(AmbientSound.allCases) { sound in
                    Link(destination: sound.itemURL) {
                        HStack {
                            Text(sound.displayName(language: preferences.resolvedLanguage))
                            Spacer()
                            Text(sound.author).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
                Link("CC0 1.0", destination: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.about")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2"
    }
}
