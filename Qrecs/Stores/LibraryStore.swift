import Combine
import Foundation

enum LibraryPhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var phase: LibraryPhase = .idle
    @Published private(set) var reciters: [Reciter] = []
    @Published private(set) var surahs: [Surah] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var cachedCounts: [String: Int] = [:]
    @Published private(set) var downloadsByTrack: [String: CachedDownload] = [:]
    @Published private(set) var cacheGroups: [CachedDownloadGroup] = []
    @Published private(set) var totalCachedBytes: Int64 = 0
    @Published private(set) var cacheStates: [String: CacheDownloadState] = [:]
    @Published private(set) var networkAvailable = false
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var ambientState: AmbientMixState = .default
    @Published private(set) var nonfatalError: String?
    @Published var selectedReciterID: String?
    @Published private(set) var selectedTrackID: String?
    @Published var reciterSearch = ""
    @Published var trackSearch = ""
    @Published var reciterDirection: SortDirection = .ascending
    @Published var trackSort: TrackSort = .number
    @Published var trackDirection: SortDirection = .ascending

    let preferences: AppPreferences

    private let catalog: any CatalogRepository
    private let userLibrary: any UserLibraryRepository
    private let cache: any CacheManaging
    private let network: any NetworkMonitoring
    private let player: any QuranPlaying
    private let ambient: any AmbientMixing
    private let paths: AppPaths
    private var observationTasks: [Task<Void, Never>] = []
    private var cacheObservationTasks: [Task<Void, Never>] = []
    private var preferencesCancellable: AnyCancellable?
    private var manualOfflineCancellable: AnyCancellable?

    init(
        catalog: any CatalogRepository,
        userLibrary: any UserLibraryRepository,
        cache: any CacheManaging,
        network: any NetworkMonitoring,
        player: any QuranPlaying,
        ambient: any AmbientMixing,
        paths: AppPaths,
        preferences: AppPreferences
    ) {
        self.catalog = catalog
        self.userLibrary = userLibrary
        self.cache = cache
        self.network = network
        self.player = player
        self.ambient = ambient
        self.paths = paths
        self.preferences = preferences
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        manualOfflineCancellable = preferences.$manualOffline
            .dropFirst()
            .sink { [weak self] manualOffline in
                guard let self else { return }
                self.player.handleNetworkAvailability(self.networkAvailable && !manualOffline)
            }
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
        cacheObservationTasks.forEach { $0.cancel() }
    }

    var effectiveOffline: Bool {
        OfflinePolicy.effectiveOffline(
            manualOffline: preferences.manualOffline,
            networkAvailable: networkAvailable
        )
    }

    var reciterGroups: ReciterGroups {
        LibraryProjection.reciterGroups(
            reciters: reciters,
            favorites: favorites,
            cachedCounts: cachedCounts,
            query: reciterSearch,
            sort: .name,
            direction: reciterDirection,
            language: preferences.resolvedLanguage,
            effectiveOffline: effectiveOffline
        )
    }

    var trackRows: [TrackPresentation] {
        let surahsByNumber = Dictionary(uniqueKeysWithValues: surahs.map { ($0.number, $0) })
        let rows = tracks.compactMap { track -> TrackPresentation? in
            guard let surah = surahsByNumber[track.surahNumber] else { return nil }
            return TrackPresentation(
                track: track,
                surah: surah,
                cacheState: cacheStates[track.id]
            )
        }
        return LibraryProjection.tracks(
            rows: rows,
            query: trackSearch,
            sort: trackSort,
            direction: trackDirection,
            language: preferences.resolvedLanguage,
            effectiveOffline: effectiveOffline
        )
    }

    var selectedReciter: Reciter? {
        reciters.first { $0.id == selectedReciterID }
    }

    func start() async {
        guard phase != .loading else { return }
        phase = .loading
        nonfatalError = nil
        do {
            async let loadedReciters = catalog.fetchReciters()
            async let loadedSurahs = catalog.fetchSurahs()
            async let favoriteIDs = userLibrary.favoriteReciterIDs()

            await network.start()
            let networkStream = await network.updates()
            let playerStream = player.updates()
            let ambientStream = ambient.updates()
            networkAvailable = await network.isNetworkAvailable()
            player.handleNetworkAvailability(networkAvailable && !preferences.manualOffline)

            reciters = try await loadedReciters
            surahs = try await loadedSurahs
            favorites = try await favoriteIDs
            try await refreshCacheSummary()
            configureAudioFromPreferences()
            beginObserving(
                networkStream: networkStream,
                playerStream: playerStream,
                ambientStream: ambientStream
            )
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func selectReciter(_ id: String?) async {
        cacheObservationTasks.forEach { $0.cancel() }
        cacheObservationTasks.removeAll()
        tracks = []
        selectedTrackID = nil
        selectedReciterID = id
        guard let id else { return }
        do {
            let loadedTracks = try await catalog.fetchTracks(reciterID: id)
            guard selectedReciterID == id else { return }
            tracks = loadedTracks
            let snapshot = await cache.snapshot()
            for track in loadedTracks {
                if let state = snapshot.states[track.id] {
                    cacheStates[track.id] = state
                } else if let download = downloadsByTrack[track.id] {
                    cacheStates[track.id] = .cached(download)
                }
                let stream = await cache.events(for: track.id)
                cacheObservationTasks.append(Task { @MainActor [weak self] in
                    for await state in stream {
                        guard !Task.isCancelled else { return }
                        if case .cached = state {
                            try? await self?.refreshCacheSummary()
                        }
                        self?.receiveCacheState(state, trackID: track.id)
                    }
                })
            }
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func selectTrack(_ track: Track) {
        guard tracks.contains(where: { $0.id == track.id }) else { return }
        selectedTrackID = track.id
        player.select(
            track: track,
            queue: tracks,
            localURLs: localURLs()
        )
        playerState = player.state
    }

    func toggleFavorite(reciterID: String) async {
        do {
            let isFavorite = try await userLibrary.toggleFavorite(reciterID: reciterID)
            if isFavorite { favorites.insert(reciterID) } else { favorites.remove(reciterID) }
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func report(_ message: String) {
        nonfatalError = message
    }

    func cacheTrack(_ track: Track) async {
        do {
            try await cache.cache(track: track)
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func cacheAllSelectedReciter() async {
        for track in tracks where downloadsByTrack[track.id] == nil {
            await cacheTrack(track)
        }
    }

    func cancelCache(trackID: String) async {
        await cache.cancel(trackID: trackID)
    }

    func retryCache(trackID: String) async {
        do {
            try await cache.retry(trackID: trackID)
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func removeCachedTrack(trackID: String) async {
        do {
            try await cache.remove(trackID: trackID)
            cacheStates.removeValue(forKey: trackID)
            try await refreshCacheSummary()
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func removeCachedReciter(_ reciterID: String) async {
        do {
            try await cache.removeAll(reciterID: reciterID)
            cacheStates = cacheStates.filter { downloadsByTrack[$0.key]?.reciterID != reciterID }
            try await refreshCacheSummary()
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func clearCache() async {
        do {
            try await cache.clearAll()
            cacheStates.removeAll()
            try await refreshCacheSummary()
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func playPause() {
        if playerState.status == .playing {
            player.pause()
        } else {
            player.play()
        }
        playerState = player.state
    }

    func previous() { player.previous(); playerState = player.state }
    func next() { player.next(); playerState = player.state }
    func retryPlayback() { player.retry(); playerState = player.state }
    func seek(to seconds: TimeInterval) { player.seek(to: seconds) }

    func setQuranVolume(_ volume: Double) {
        preferences.quranVolume = volume
        player.setVolume(Float(preferences.quranVolume))
    }

    func setAmbientEnabled(_ enabled: Bool, sound: AmbientSound) {
        preferences.setAmbientEnabled(enabled, for: sound)
        ambient.setEnabled(enabled, for: sound)
        ambientState = ambient.state
    }

    func setAmbientVolume(_ volume: Double, sound: AmbientSound) {
        preferences.setAmbientVolume(volume, for: sound)
        ambient.setVolume(Float(preferences.ambientVolume(sound)), for: sound)
        ambientState = ambient.state
    }

    func setAmbientMasterVolume(_ volume: Double) {
        preferences.ambientMasterVolume = volume
        ambient.setMasterVolume(Float(preferences.ambientMasterVolume))
        ambientState = ambient.state
    }

    private func configureAudioFromPreferences() {
        player.setVolume(Float(preferences.quranVolume))
        ambient.setMasterVolume(Float(preferences.ambientMasterVolume))
        for sound in AmbientSound.allCases {
            ambient.setVolume(Float(preferences.ambientVolume(sound)), for: sound)
            ambient.setEnabled(preferences.ambientEnabled(sound), for: sound)
        }
        playerState = player.state
        ambientState = ambient.state
    }

    private func beginObserving(
        networkStream: AsyncStream<Bool>,
        playerStream: AsyncStream<PlayerState>,
        ambientStream: AsyncStream<AmbientMixState>
    ) {
        observationTasks.forEach { $0.cancel() }
        observationTasks = [
            Task { @MainActor [weak self] in
                for await available in networkStream {
                    guard !Task.isCancelled else { return }
                    self?.networkAvailable = available
                    guard let self else { return }
                    self.player.handleNetworkAvailability(available && !self.preferences.manualOffline)
                }
            },
            Task { @MainActor [weak self] in
                for await state in playerStream {
                    guard !Task.isCancelled else { return }
                    self?.playerState = state
                    self?.selectedTrackID = state.currentTrack?.id ?? self?.selectedTrackID
                }
            },
            Task { @MainActor [weak self] in
                for await state in ambientStream {
                    guard !Task.isCancelled else { return }
                    self?.ambientState = state
                }
            },
        ]
    }

    private func receiveCacheState(_ state: CacheDownloadState, trackID: String) {
        cacheStates[trackID] = state
    }

    private func refreshCacheSummary() async throws {
        async let downloads = userLibrary.downloads()
        async let groups = userLibrary.downloadGroups()
        async let bytes = userLibrary.totalDownloadedBytes()
        let loadedDownloads = try await downloads
        downloadsByTrack = Dictionary(uniqueKeysWithValues: loadedDownloads.map { ($0.trackID, $0) })
        cacheGroups = try await groups
        totalCachedBytes = try await bytes
        cachedCounts = Dictionary(
            uniqueKeysWithValues: cacheGroups.map { ($0.reciterID, $0.trackCount) }
        )
        for download in loadedDownloads {
            cacheStates[download.trackID] = .cached(download)
        }
    }

    private func localURLs() -> [String: URL] {
        Dictionary(uniqueKeysWithValues: downloadsByTrack.compactMap { trackID, download in
            guard !download.relativePath.contains("/"), !download.relativePath.contains("\\") else {
                return nil
            }
            return (
                trackID,
                paths.audioCacheDirectory.appendingPathComponent(download.relativePath)
            )
        })
    }
}
