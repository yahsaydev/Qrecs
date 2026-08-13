import SwiftUI

struct RootView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Group {
            switch container.state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(preferences.text("Loading library…"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("app.loading")
            case let .ready(store):
                ReadyLibraryView(store: store, preferences: preferences)
            case let .failed(message):
                ContentUnavailableView {
                    Label(
                        preferences.text("Application initialization failed"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message.isEmpty ? preferences.text("Unable to load the catalog.") : message)
                }
                .accessibilityIdentifier("app.failure")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .environment(\.locale, preferences.resolvedLanguage.locale)
        .task { await container.start() }
    }
}

private struct ReadyLibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        switch store.phase {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(preferences.text("Loading library…"))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("app.loading")
        case .ready:
            LibraryRootView(store: store)
        case let .failed(message):
            ContentUnavailableView {
                Label(
                    preferences.text("Application initialization failed"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message.isEmpty ? preferences.text("Unable to load the catalog.") : message)
            }
            .accessibilityIdentifier("app.failure")
        }
    }
}
