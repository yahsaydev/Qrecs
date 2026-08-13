import SwiftUI

struct LibraryRootView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            if store.effectiveOffline {
                OfflineBanner(preferences: store.preferences)
            }

            if store.effectiveOffline
                && store.reciterGroups.favorites.isEmpty
                && store.reciterGroups.all.isEmpty {
                ContentUnavailableView {
                    Label(store.preferences.text("No offline recordings"), systemImage: "wifi.slash")
                } description: {
                    Text(store.preferences.text("Offline mode only shows recordings saved on this Mac."))
                }
                .accessibilityIdentifier("offline.empty")
            } else {
                NavigationSplitView {
                    ReciterSidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
                } detail: {
                    LibraryDetailView(store: store)
                }
                .accessibilityIdentifier("library.split")
            }

            if store.playerState.currentTrack != nil {
                Divider()
                MiniPlayerView(store: store)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.playerState.currentTrack?.id)
        .overlay(alignment: .topTrailing) {
            if let error = store.nonfatalError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(10)
                    .qrecsGlass(cornerRadius: 10)
                    .padding()
                    .accessibilityIdentifier("library.warning")
            }
        }
    }
}

private struct OfflineBanner: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text(preferences.text("Effective offline mode"))
                .fontWeight(.semibold)
            Spacer()
            Text(preferences.text("Offline mode only shows recordings saved on this Mac."))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .accessibilityIdentifier("offline.banner")
    }
}

private struct LibraryDetailView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        if store.selectedReciter == nil {
            ContentUnavailableView(
                store.preferences.text("Select a reciter"),
                systemImage: "person.wave.2"
            )
        } else {
            TrackTableView(store: store)
        }
    }
}
