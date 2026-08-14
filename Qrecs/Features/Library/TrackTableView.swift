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
                Table(store.trackRows, selection: $store.tableSelectionID) {
                    TableColumn(store.preferences.text("Number")) { row in
                        TrackPlaybackCell(
                            isPlaying: store.playerState.isPlayingTrack(row.id),
                            isPaused: store.playerState.isPausedTrack(row.id)
                        ) {
                            Text(row.track.surahNumber, format: .number)
                                .monospacedDigit()
                        }
                    }
                    .width(min: 50, ideal: 60, max: 80)

                    TableColumn(store.preferences.text("Surah")) { row in
                        let isPlaying = store.playerState.isPlayingTrack(row.id)
                        let isPaused = store.playerState.isPausedTrack(row.id)
                        TrackPlaybackCell(isPlaying: isPlaying, isPaused: isPaused) {
                            HStack(spacing: 7) {
                                if isPlaying {
                                    PlayingEqualizer(
                                        isPlaying: true,
                                        reduceMotion: reduceMotion
                                    )
                                    .tint(.green)
                                    .accessibilityLabel(store.preferences.text("Playing"))
                                    .accessibilityIdentifier("track.\(row.id).playing")
                                } else if isPaused {
                                    Image(systemName: "pause.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green.opacity(0.78))
                                        .accessibilityLabel(store.preferences.text("Paused"))
                                        .accessibilityIdentifier("track.\(row.id).paused")
                                }
                                Text(
                                    row.surah.displayName(
                                        language: store.preferences.resolvedLanguage)
                                )
                                .fontWeight(isPlaying ? .bold : .regular)
                                .lineLimit(1)
                            }
                        }
                    }

                    TableColumn(store.preferences.text("Status")) { row in
                        TrackPlaybackCell(
                            isPlaying: store.playerState.isPlayingTrack(row.id),
                            isPaused: store.playerState.isPausedTrack(row.id)
                        ) {
                            CacheStatusView(state: row.cacheState, preferences: store.preferences)
                        }
                    }
                    .width(min: 120, ideal: 150, max: 190)

                    TableColumn("") { row in
                        TrackPlaybackCell(
                            isPlaying: store.playerState.isPlayingTrack(row.id),
                            isPaused: store.playerState.isPausedTrack(row.id),
                            alignment: .center
                        ) {
                            CacheActionView(store: store, row: row)
                        }
                    }
                    .width(min: 44, ideal: 54, max: 70)
                }
                .accessibilityIdentifier("tracks.table")
                .onKeyPress(.return) {
                    playSelectedTrack()
                    return .handled
                }
                .contextMenu(forSelectionType: String.self) { selection in
                    if selectedTrack(in: selection) != nil {
                        Button(store.preferences.text("Play")) {
                            playSelectedTrack(in: selection)
                        }
                    }
                } primaryAction: { selection in
                    playSelectedTrack(in: selection)
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

    private func selectedTrack(in selection: Set<String>) -> Track? {
        guard let id = selection.first else { return nil }
        return store.tracks.first { $0.id == id }
    }

    private func playSelectedTrack(in selection: Set<String>? = nil) {
        if let id = selection?.first {
            store.tableSelectionID = id
        }
        store.playSelectedTrack()
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    store.selectedReciter?.displayName(
                        language: store.preferences.resolvedLanguage
                    ) ?? ""
                )
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
            .help(
                store.preferences.text(
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

private struct TrackPlaybackCell<Content: View>: View {
    let isPlaying: Bool
    let isPaused: Bool
    let alignment: Alignment
    let content: Content

    init(
        isPlaying: Bool,
        isPaused: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.isPlaying = isPlaying
        self.isPaused = isPaused
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlightColor)
            }
    }

    private var highlightColor: Color {
        if isPlaying { return .green.opacity(0.13) }
        if isPaused { return .green.opacity(0.065) }
        return .clear
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
        case .downloading(let progress):
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
