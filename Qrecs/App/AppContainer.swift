import Combine
import Foundation

@MainActor
final class AppContainer: ObservableObject {
    enum State {
        case loading
        case ready(LibraryStore)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    let preferences: AppPreferences
    private var hasStarted = false
    private var storeCancellable: AnyCancellable?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    init(preferences: AppPreferences, readyStore: LibraryStore) {
        self.preferences = preferences
        hasStarted = true
        install(readyStore)
    }

    var store: LibraryStore? {
        if case let .ready(store) = state { return store }
        return nil
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                install(try await makeUITestStore())
                return
            }
            #endif
            install(try await makeProductionStore())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func install(_ store: LibraryStore) {
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        state = .ready(store)
    }

    private func makeProductionStore() async throws -> LibraryStore {
        let paths = try AppPaths.applicationSupport()
        try paths.prepareDirectories()
        let catalog = try GRDBCatalogRepository.bundled()
        let userLibrary = try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
        let cache = try await CacheManager.applicationSupport(repository: userLibrary)
        let network = NWPathNetworkMonitor()

        let ambientBackend: any AmbientAudioBackend
        var audioWarning: String?
        do {
            ambientBackend = try AVAudioEngineAmbientBackend()
        } catch {
            ambientBackend = UnavailableAmbientAudioBackend()
            audioWarning = preferences.text("Audio effects are unavailable")
        }
        let ambient = AmbientMixer(backend: ambientBackend)
        let player = QuranPlayer(audio: AVPlayerAudioBackend(), ambient: ambient)
        let store = LibraryStore(
            catalog: catalog,
            userLibrary: userLibrary,
            cache: cache,
            network: network,
            player: player,
            ambient: ambient,
            paths: paths,
            preferences: preferences
        )
        await store.start()
        if let audioWarning { store.report(audioWarning) }
        return store
    }

    #if DEBUG
    private func makeUITestStore() async throws -> LibraryStore {
        let arguments = ProcessInfo.processInfo.arguments
        let isOfflineEmpty = arguments.contains("--offline-empty")
        let hasPlaybackFailure = arguments.contains("--playback-failure")
        let paths = try AppPaths(baseDirectory: FileManager.default.temporaryDirectory)
        let reciters = [
            Reciter(
                id: "fixture-reciter",
                sourceNameRU: "Абдуллах Аль-Джухани",
                nameRU: "Абдуллах Аль-Джухани",
                nameEN: "Abdullah Al-Juhany"
            ),
            Reciter(
                id: "fixture-second",
                sourceNameRU: "Мишари Рашид",
                nameRU: "Мишари Рашид",
                nameEN: "Mishary Rashid"
            ),
        ]
        let surahs = [
            Surah(number: 1, nameRU: "Аль-Фатиха", nameEN: "Al-Fatihah"),
            Surah(number: 2, nameRU: "Аль-Бакара", nameEN: "Al-Baqarah"),
        ]
        let tracks = surahs.map {
            Track(
                id: "fixture-reciter:\($0.number)",
                reciterID: "fixture-reciter",
                surahNumber: $0.number,
                url: URL(string: "https://example.com/\($0.number).mp3")!
            )
        }
        let catalog = FixtureCatalog(
            reciters: reciters,
            surahs: surahs,
            tracksByReciter: ["fixture-reciter": tracks]
        )
        let userLibrary = FixtureUserLibrary(favorites: ["fixture-reciter"])
        let cache = FixtureCache()
        let network = FixtureNetwork(available: true)
        let ambient = AmbientMixer(backend: UnavailableAmbientAudioBackend())
        let audio = FixtureQuranAudioBackend()
        let player = QuranPlayer(audio: audio, ambient: ambient)
        if isOfflineEmpty { preferences.manualOffline = true }
        let store = LibraryStore(
            catalog: catalog,
            userLibrary: userLibrary,
            cache: cache,
            network: network,
            player: player,
            ambient: ambient,
            paths: paths,
            preferences: preferences
        )
        await store.start()
        if !isOfflineEmpty {
            await store.selectReciter("fixture-reciter")
            if hasPlaybackFailure, let track = tracks.first {
                store.selectTrack(track)
                player.play()
                audio.failCurrent(message: "Fixture playback failure")
            }
        }
        return store
    }
    #endif
}

@MainActor
private final class UnavailableAmbientAudioBackend: AmbientAudioBackend {
    func start() -> Bool { false }
    func play(_ sound: AmbientSound) {}
    func pause(_ sound: AmbientSound) {}
    func stopAll() {}
    func setVolume(_ volume: Float, for sound: AmbientSound) {}
    func setMasterVolume(_ volume: Float) {}
}

#if DEBUG
@MainActor
private final class FixtureQuranAudioBackend: QuranAudioBackend {
    private let stream: AsyncStream<QuranAudioEvent>
    private let continuation: AsyncStream<QuranAudioEvent>.Continuation
    private var currentItemID: QuranAudioItemID?

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func load(url: URL, itemID: QuranAudioItemID) { currentItemID = itemID }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: TimeInterval) {}
    func setVolume(_ volume: Float) {}
    func events() -> AsyncStream<QuranAudioEvent> { stream }

    func failCurrent(message: String) {
        guard let currentItemID else { return }
        continuation.yield(.failed(itemID: currentItemID, message: message))
    }
}

private actor FixtureCatalog: CatalogRepository {
    let reciters: [Reciter]
    let surahs: [Surah]
    let tracksByReciter: [String: [Track]]

    init(
        reciters: [Reciter],
        surahs: [Surah],
        tracksByReciter: [String: [Track]]
    ) {
        self.reciters = reciters
        self.surahs = surahs
        self.tracksByReciter = tracksByReciter
    }

    func fetchReciters() -> [Reciter] { reciters }
    func fetchSurahs() -> [Surah] { surahs }
    func fetchTracks(reciterID: String) -> [Track] { tracksByReciter[reciterID] ?? [] }
}

private actor FixtureUserLibrary: UserLibraryRepository {
    var favorites: Set<String>
    init(favorites: Set<String>) { self.favorites = favorites }
    func favoriteReciterIDs() -> Set<String> { favorites }
    func isFavorite(reciterID: String) -> Bool { favorites.contains(reciterID) }
    func setFavorite(_ isFavorite: Bool, reciterID: String) {
        if isFavorite { favorites.insert(reciterID) } else { favorites.remove(reciterID) }
    }
    func toggleFavorite(reciterID: String) -> Bool {
        if favorites.remove(reciterID) != nil { return false }
        favorites.insert(reciterID)
        return true
    }
    func downloads() -> [CachedDownload] { [] }
    func download(trackID: String) -> CachedDownload? { nil }
    func upsertDownload(_ download: CachedDownload) {}
    func removeDownload(trackID: String) {}
    func cachedTrackIDs() -> Set<String> { [] }
    func cachedReciterIDs() -> Set<String> { [] }
    func totalDownloadedBytes() -> Int64 { 0 }
    func downloadGroups() -> [CachedDownloadGroup] { [] }
}

private actor FixtureCache: CacheManaging {
    var states: [String: CacheDownloadState] = [:]
    var continuations: [String: [AsyncStream<CacheDownloadState>.Continuation]] = [:]
    func cache(track: Track) {
        states[track.id] = .failed(message: "Fixture download unavailable")
        continuations[track.id]?.forEach { $0.yield(states[track.id]!) }
    }
    func cancel(trackID: String) { states[trackID] = .cancelled }
    func retry(trackID: String) {}
    func remove(trackID: String) { states.removeValue(forKey: trackID) }
    func removeAll(reciterID: String) { states.removeAll() }
    func clearAll() { states.removeAll() }
    func totalBytes() -> Int64 { 0 }
    func state(trackID: String) -> CacheDownloadState? { states[trackID] }
    func snapshot() -> CacheSnapshot { CacheSnapshot(states: states) }
    func events(for trackID: String) -> AsyncStream<CacheDownloadState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CacheDownloadState.self)
        continuations[trackID, default: []].append(continuation)
        if let state = states[trackID] { continuation.yield(state) }
        return stream
    }
}

private actor FixtureNetwork: NetworkMonitoring {
    let available: Bool
    init(available: Bool) { self.available = available }
    func start() {}
    func stop() {}
    func isNetworkAvailable() -> Bool { available }
    func updates() -> AsyncStream<Bool> { AsyncStream { $0.yield(available) } }
}
#endif
