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
    private var cacheObservationTasks: [String: Task<Void, Never>] = [:]
    private var cacheObserverReciterIDs: [String: String] = [:]
    private var cacheOperationsStarting: Set<String> = []
    private var knownTrackReciterIDs: [String: String] = [:]
    private var tracksByReciter: [String: [Track]] = [:]
    private var cacheRefreshGeneration: UInt64 = 0
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
                let playbackNetworkAvailable = self.networkAvailable && !manualOffline
                self.player.handleNetworkAvailability(playbackNetworkAvailable)
                self.updatePlayerAvailability(effectiveOffline: !playbackNetworkAvailable)
            }
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
        cacheObservationTasks.values.forEach { $0.cancel() }
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

    var playbackFailureMessage: String? {
        guard case let .failed(failure) = playerState.status else { return nil }
        switch failure {
        case .networkUnavailable:
            return preferences.text("Network unavailable")
        case let .playback(message):
            return message.isEmpty ? preferences.text("Playback failed") : message
        }
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
        tracks = []
        selectedTrackID = nil
        selectedReciterID = id
        guard let id else { return }
        do {
            let loadedTracks = try await catalog.fetchTracks(reciterID: id)
            guard selectedReciterID == id else { return }
            tracks = loadedTracks
            tracksByReciter[id] = loadedTracks
            let snapshot = await cache.snapshot()
            for track in loadedTracks {
                knownTrackReciterIDs[track.id] = track.reciterID
                if let state = snapshot.states[track.id] {
                    cacheStates[track.id] = state
                    if state.isInFlight {
                        await observeCacheIfNeeded(for: track)
                    }
                } else if let download = downloadsByTrack[track.id] {
                    cacheStates[track.id] = .cached(download)
                }
            }
            updatePlayerAvailability()
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func selectTrack(_ track: Track) {
        guard tracks.contains(where: { $0.id == track.id }) else { return }
        selectedTrackID = track.id
        player.select(
            track: track,
            queue: playbackQueue(for: track.reciterID),
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
        knownTrackReciterIDs[track.id] = track.reciterID
        cacheOperationsStarting.insert(track.id)
        await observeCacheIfNeeded(for: track)
        do {
            try await cache.cache(track: track)
            cacheOperationsStarting.remove(track.id)
            await synchronizeCacheState(trackID: track.id)
        } catch {
            cacheOperationsStarting.remove(track.id)
            cancelCacheObservation(trackID: track.id)
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
        await synchronizeCacheState(trackID: trackID)
    }

    func retryCache(trackID: String) async {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        cacheOperationsStarting.insert(trackID)
        await observeCacheIfNeeded(for: track)
        do {
            try await cache.retry(trackID: trackID)
            cacheOperationsStarting.remove(trackID)
            await synchronizeCacheState(trackID: trackID)
        } catch {
            cacheOperationsStarting.remove(trackID)
            cancelCacheObservation(trackID: trackID)
            nonfatalError = error.localizedDescription
        }
    }

    func removeCachedTrack(trackID: String) async {
        do {
            try await cache.remove(trackID: trackID)
            cancelCacheObservation(trackID: trackID)
            cacheStates.removeValue(forKey: trackID)
            try await refreshCacheSummary()
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func removeCachedReciter(_ reciterID: String) async {
        let observedTrackIDs = cacheObserverReciterIDs.compactMap { trackID, observedReciterID in
            observedReciterID == reciterID ? trackID : nil
        }
        let persistedTrackIDs = downloadsByTrack.values
            .filter { $0.reciterID == reciterID }
            .map(\.trackID)
        let knownTrackIDs = knownTrackReciterIDs.compactMap { trackID, knownReciterID in
            knownReciterID == reciterID ? trackID : nil
        }
        let removedTrackIDs = Set(observedTrackIDs + persistedTrackIDs + knownTrackIDs)
        do {
            try await cache.removeAll(reciterID: reciterID)
            observedTrackIDs.forEach(cancelCacheObservation)
            cacheStates = cacheStates.filter { !removedTrackIDs.contains($0.key) }
            knownTrackReciterIDs = knownTrackReciterIDs.filter { $0.value != reciterID }
            try await refreshCacheSummary()
        } catch {
            nonfatalError = error.localizedDescription
        }
    }

    func clearCache() async {
        do {
            try await cache.clearAll()
            Array(cacheObservationTasks.keys).forEach(cancelCacheObservation)
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
                    let playbackNetworkAvailable = available && !self.preferences.manualOffline
                    self.player.handleNetworkAvailability(playbackNetworkAvailable)
                    self.updatePlayerAvailability(effectiveOffline: !playbackNetworkAvailable)
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

    private func observeCacheIfNeeded(for track: Track) async {
        guard cacheObservationTasks[track.id] == nil else { return }
        knownTrackReciterIDs[track.id] = track.reciterID
        let stream = await cache.events(for: track.id)
        cacheObserverReciterIDs[track.id] = track.reciterID
        cacheObservationTasks[track.id] = Task { @MainActor [weak self] in
            for await state in stream {
                guard !Task.isCancelled else { return }
                if await self?.receiveCacheState(state, trackID: track.id) == true {
                    self?.finishCacheObservation(trackID: track.id, cancelTask: false)
                    return
                }
            }
        }
    }

    private func synchronizeCacheState(trackID: String) async {
        guard let state = await cache.state(trackID: trackID) else { return }
        if await receiveCacheState(state, trackID: trackID) {
            finishCacheObservation(trackID: trackID, cancelTask: true)
        }
    }

    private func receiveCacheState(_ state: CacheDownloadState, trackID: String) async -> Bool {
        if state.isTerminal, cacheOperationsStarting.contains(trackID) {
            cacheStates[trackID] = state
            return false
        }
        if state.isTerminal {
            guard let currentState = await cache.state(trackID: trackID) else {
                cacheStates.removeValue(forKey: trackID)
                return true
            }
            if currentState != state {
                return await receiveCacheState(currentState, trackID: trackID)
            }
        }
        if case .cached = state {
            do {
                try await refreshCacheSummary()
            } catch {
                nonfatalError = error.localizedDescription
            }
            guard !Task.isCancelled else { return true }
            guard let currentState = await cache.state(trackID: trackID) else {
                cacheStates.removeValue(forKey: trackID)
                return true
            }
            if currentState != state {
                return await receiveCacheState(currentState, trackID: trackID)
            }
        }
        cacheStates[trackID] = state
        return state.isTerminal
    }

    private func finishCacheObservation(trackID: String, cancelTask: Bool) {
        let task = cacheObservationTasks.removeValue(forKey: trackID)
        if cancelTask { task?.cancel() }
        cacheObserverReciterIDs.removeValue(forKey: trackID)
        cacheOperationsStarting.remove(trackID)
    }

    private func cancelCacheObservation(trackID: String) {
        cacheObservationTasks.removeValue(forKey: trackID)?.cancel()
        cacheObserverReciterIDs.removeValue(forKey: trackID)
        cacheOperationsStarting.remove(trackID)
    }

    private func refreshCacheSummary() async throws {
        cacheRefreshGeneration &+= 1
        let generation = cacheRefreshGeneration
        let loadedDownloads = try await userLibrary.downloads()
        guard generation == cacheRefreshGeneration else { return }

        let groups = Dictionary(grouping: loadedDownloads, by: \.reciterID)
            .map { reciterID, downloads in
                CachedDownloadGroup(
                    reciterID: reciterID,
                    trackCount: downloads.count,
                    byteCount: downloads.reduce(0) { $0 + $1.byteCount }
                )
            }
            .sorted { $0.reciterID < $1.reciterID }
        let summaryDownloads = Dictionary(
            uniqueKeysWithValues: loadedDownloads.map { ($0.trackID, $0) }
        )
        let counts = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.reciterID, $0.trackCount) }
        )
        let totalBytes = loadedDownloads.reduce(Int64(0)) { $0 + $1.byteCount }

        downloadsByTrack = summaryDownloads
        cacheGroups = groups
        cachedCounts = counts
        totalCachedBytes = totalBytes
        for download in loadedDownloads {
            cacheStates[download.trackID] = .cached(download)
        }
        updatePlayerAvailability()
    }

    private func playbackQueue(
        for reciterID: String,
        effectiveOffline offlineOverride: Bool? = nil
    ) -> [Track] {
        let availableTracks = tracksByReciter[reciterID] ?? []
        let offline = offlineOverride ?? effectiveOffline
        guard offline else { return availableTracks }
        return availableTracks.filter { downloadsByTrack[$0.id] != nil }
    }

    private func updatePlayerAvailability(effectiveOffline offlineOverride: Bool? = nil) {
        guard let reciterID = player.state.currentTrack?.reciterID,
              tracksByReciter[reciterID] != nil else { return }
        player.updateAvailability(
            queue: playbackQueue(for: reciterID, effectiveOffline: offlineOverride),
            localURLs: localURLs()
        )
        playerState = player.state
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

private extension CacheDownloadState {
    var isInFlight: Bool {
        switch self {
        case .queued, .downloading: true
        case .cached, .failed, .cancelled: false
        }
    }

    var isTerminal: Bool { !isInFlight }
}
