import SwiftUI

struct TrackTableView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmReciterRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.trackRows.isEmpty {
                ContentUnavailableView(
                    store.preferences.text("No surahs found"),
                    systemImage: "waveform"
                )
            } else {
                Table(store.trackRows, selection: trackSelection) {
                    TableColumn(store.preferences.text("Number")) { row in
                        Text(row.track.surahNumber, format: .number)
                            .monospacedDigit()
                    }
                    .width(min: 50, ideal: 60, max: 80)

                    TableColumn(store.preferences.text("Surah")) { row in
                        HStack(spacing: 7) {
                            if store.playerState.currentTrack?.id == row.id {
                                PlayingEqualizer(
                                    isPlaying: store.playerState.status == .playing,
                                    reduceMotion: reduceMotion
                                )
                            }
                            Text(row.surah.displayName(language: store.preferences.resolvedLanguage))
                                .lineLimit(1)
                        }
                    }

                    TableColumn(store.preferences.text("Status")) { row in
                        CacheStatusView(state: row.cacheState, preferences: store.preferences)
                    }
                    .width(min: 120, ideal: 150, max: 190)

                    TableColumn("") { row in
                        CacheActionView(store: store, row: row)
                    }
                    .width(min: 44, ideal: 54, max: 70)
                }
                .accessibilityIdentifier("tracks.table")
                .contextMenu(forSelectionType: String.self) { selection in
                    if let track = selectedTrack(in: selection) {
                        Button(store.preferences.text("Play")) {
                            store.playTrack(track)
                        }
                    }
                } primaryAction: { selection in
                    if let track = selectedTrack(in: selection) {
                        store.playTrack(track)
                    }
                }
            }
        }
        .searchable(text: $store.trackSearch, prompt: store.preferences.text("Search surahs"))
        .confirmationDialog(
            store.preferences.text("Remove all cached files for this reciter?"),
            isPresented: $confirmReciterRemoval
        ) {
            Button(store.preferences.text("Delete"), role: .destructive) {
                guard let id = store.selectedReciterID else { return }
                Task { await store.removeCachedReciter(id) }
            }
        }
    }

    private var trackSelection: Binding<String?> {
        Binding(
            get: { store.selectedTrackID },
            set: { id in
                guard let id, let track = store.tracks.first(where: { $0.id == id }) else { return }
                store.selectTrack(track)
            }
        )
    }

    private func selectedTrack(in selection: Set<String>) -> Track? {
        guard let id = selection.first else { return nil }
        return store.tracks.first { $0.id == id }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedReciter?.displayName(
                    language: store.preferences.resolvedLanguage
                ) ?? "")
                    .font(.title2.weight(.semibold))
                Text(store.preferences.text("Quran recordings"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $store.trackSort) {
                Text(store.preferences.text("Sort by number")).tag(TrackSort.number)
                Text(store.preferences.text("Sort by name")).tag(TrackSort.name)
                Text(store.preferences.text("Sort by status")).tag(TrackSort.status)
            }
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel(store.preferences.text("Status"))

            Button {
                store.trackDirection = store.trackDirection == .ascending ? .descending : .ascending
            } label: {
                Image(systemName: store.trackDirection == .ascending ? "arrow.up" : "arrow.down")
            }
            .help(store.preferences.text(
                store.trackDirection == .ascending ? "Sort descending" : "Sort ascending"
            ))

            Button {
                Task {
                    if store.activeCacheBatch == nil {
                        await store.cacheAllSelectedReciter()
                    } else {
                        await store.cancelActiveCacheBatch()
                    }
                }
            } label: {
                if let batch = store.activeCacheBatch {
                    Label(
                        "\(store.preferences.text("Cancel download")) (\(batch.remainingCount))",
                        systemImage: "xmark.circle"
                    )
                } else {
                    Label(store.preferences.text("Cache all"), systemImage: "arrow.down.circle")
                }
            }
            .disabled(store.effectiveOffline && store.activeCacheBatch == nil)

            Menu {
                Button(store.preferences.text("Delete cached reciter"), role: .destructive) {
                    confirmReciterRemoval = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(14)
    }
}

private struct CacheStatusView: View {
    let state: CacheDownloadState?
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        switch state {
        case .none:
            Label(preferences.text("Not cached"), systemImage: "icloud")
                .foregroundStyle(.secondary)
        case .queued:
            Label(preferences.text("Downloading"), systemImage: "clock")
                .foregroundStyle(.secondary)
        case let .downloading(progress):
            HStack(spacing: 6) {
                ProgressView(value: progress?.fractionCompleted ?? 0)
                    .frame(width: 54)
                Text(progress?.fractionCompleted.map { "\(Int($0 * 100))%" } ?? "—")
                    .monospacedDigit()
            }
        case .cached:
            Label(preferences.text("Cached"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label(preferences.text("Retry"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Label(preferences.text("Cancel"), systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct CacheActionView: View {
    @ObservedObject var store: LibraryStore
    let row: TrackPresentation

    var body: some View {
        Group {
            switch row.cacheState {
            case .none, .cancelled:
                Button {
                    Task { await store.cacheTrack(row.track) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(store.effectiveOffline)
                .help(store.preferences.text("Download"))
            case .queued, .downloading:
                Button {
                    Task { await store.cancelCache(trackID: row.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help(store.preferences.text("Cancel"))
            case .failed:
                Button {
                    Task { await store.retryCache(trackID: row.id) }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .disabled(store.effectiveOffline)
                .help(store.preferences.text("Retry"))
            case .cached:
                Button(role: .destructive) {
                    Task { await store.removeCachedTrack(trackID: row.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .help(store.preferences.text("Delete"))
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("track.\(row.id).cacheAction")
    }
}
