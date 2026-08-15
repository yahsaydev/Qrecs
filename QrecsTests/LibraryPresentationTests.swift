import Foundation
import XCTest
@testable import Qrecs

@MainActor
final class LibraryPresentationTests: XCTestCase {
    func testMiniPlayerUsesCompactSingleRowHeight() {
        XCTAssertEqual(MiniPlayerLayout.surfaceHeight, 54)
        XCTAssertEqual(MiniPlayerLayout.metadataLineLimit, 2)
    }

    func testPlaybackMotionRemainsContinuousAcrossFormerEightSecondBoundary() {
        var motion = AuroraPhaseController(staticPhase: 0.25)
        motion.transition(isPlaying: true, reduceMotion: false, at: 0)

        let before = motion.phase(at: 7.999, rate: 1)
        let after = motion.phase(at: 8.001, rate: 1)

        XCTAssertEqual(after - before, 0.002, accuracy: 0.000_001)
        XCTAssertGreaterThan(after, 8)
    }

    func testPlaybackMotionFreezesAndResumesWithoutJump() {
        var motion = AuroraPhaseController(staticPhase: 0.25)
        motion.transition(isPlaying: true, reduceMotion: false, at: 10)
        motion.transition(isPlaying: false, reduceMotion: false, at: 13)

        XCTAssertEqual(motion.phase(at: 80, rate: 1), 3.25, accuracy: 0.000_001)

        motion.transition(isPlaying: true, reduceMotion: false, at: 80)
        XCTAssertEqual(motion.phase(at: 80, rate: 1), 3.25, accuracy: 0.000_001)
        XCTAssertEqual(motion.phase(at: 81, rate: 1), 4.25, accuracy: 0.000_001)
    }

    func testPlaybackMotionIsFullyStaticWithReduceMotion() {
        var motion = AuroraPhaseController(staticPhase: 0.25)
        motion.transition(isPlaying: true, reduceMotion: true, at: 0)

        XCTAssertEqual(motion.phase(at: 0, rate: 12), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(motion.phase(at: 10_000, rate: 12), 0.25, accuracy: 0.000_001)
    }

    func testAuroraParallaxFreezesWhilePausedAndResumesFromSameOffset() {
        var parallax = AuroraParallaxController()
        let playingOffset = CGSize(width: 0.2, height: -0.3)
        let pausedHoverOffset = CGSize(width: -0.4, height: 0.1)

        parallax.transition(isPlaying: true, reduceMotion: false)
        parallax.update(pointerOffset: playingOffset)
        parallax.transition(isPlaying: false, reduceMotion: false)
        parallax.update(pointerOffset: pausedHoverOffset)

        XCTAssertEqual(parallax.pointerOffset, playingOffset)

        parallax.transition(isPlaying: true, reduceMotion: false)
        XCTAssertEqual(parallax.pointerOffset, playingOffset)

        parallax.update(pointerOffset: pausedHoverOffset)
        XCTAssertEqual(parallax.pointerOffset, pausedHoverOffset)
    }

    func testAuroraParallaxResetsAndIgnoresHoverWithReduceMotion() {
        var parallax = AuroraParallaxController()
        parallax.transition(isPlaying: true, reduceMotion: false)
        parallax.update(pointerOffset: CGSize(width: 0.2, height: -0.3))

        parallax.transition(isPlaying: true, reduceMotion: true)
        parallax.update(pointerOffset: CGSize(width: -0.4, height: 0.1))

        XCTAssertEqual(parallax.pointerOffset, .zero)
    }

    func testAuroraParallaxUsesNoImplicitAnimation() {
        XCTAssertNil(AuroraParallaxAnimationPolicy.animation)
    }

    func testAuroraSceneHasSixDeterministicPhaseDrivenFieldsWithParallax() {
        let size = CGSize(width: 800, height: 180)
        let pointerOffset = CGSize(width: 0.25, height: -0.4)

        let first = AuroraSceneModel.positions(
            in: size,
            phase: 0.75,
            pointerOffset: pointerOffset
        )
        let repeated = AuroraSceneModel.positions(
            in: size,
            phase: 0.75,
            pointerOffset: pointerOffset
        )
        let advanced = AuroraSceneModel.positions(
            in: size,
            phase: 1.75,
            pointerOffset: pointerOffset
        )
        let withoutParallax = AuroraSceneModel.positions(
            in: size,
            phase: 0.75,
            pointerOffset: .zero
        )

        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, advanced)
        XCTAssertNotEqual(first, withoutParallax)
        XCTAssertTrue(first.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testPlayerSurfaceLayerContractPlacesGlassBetweenAuroraAndControls() {
        XCTAssertEqual(
            PlayerSurfaceLayer.backToFront,
            [.aurora, .glass, .controls]
        )
        XCTAssertEqual(
            PlayerSurfaceLayer.backToFront.map(\.zIndex),
            [0, 1, 2]
        )
    }

    func testPlaybackRowStateOnlyMarksMatchingPlayingOrPausedTrack() {
        let track = Track(
            id: "r:1",
            reciterID: "r",
            surahNumber: 1,
            url: URL(string: "https://example.com/1.mp3")!
        )
        var state = PlayerState.idle
        state.currentTrack = track

        state.status = .playing
        XCTAssertTrue(state.isPlayingTrack(track.id))
        XCTAssertFalse(state.isPausedTrack(track.id))
        XCTAssertFalse(state.isPlayingTrack("r:2"))

        state.status = .paused
        XCTAssertFalse(state.isPlayingTrack(track.id))
        XCTAssertTrue(state.isPausedTrack(track.id))

        state.status = .stopped
        XCTAssertFalse(state.isPlayingTrack(track.id))
        XCTAssertFalse(state.isPausedTrack(track.id))

        state.status = .failed(.playback("failed"))
        XCTAssertFalse(state.isPlayingTrack(track.id))
        XCTAssertFalse(state.isPausedTrack(track.id))
    }

    func testEqualizerLevelsAreDeterministicBoundedAndPhaseDriven() {
        let first = PlayingEqualizerModel.levels(at: 0.3)
        let repeated = PlayingEqualizerModel.levels(at: 0.3)
        let advanced = PlayingEqualizerModel.levels(at: 1.3)

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, advanced)
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(first.allSatisfy { (0.2...1).contains($0) })
    }

    func testAuroraPaletteRepresentsEveryEnabledAmbientAccent() {
        let accents = AmbientSound.allCases.map(\.accent)

        let fields = AuroraPaletteModel.fieldColors(
            enabledAccents: accents,
            fieldCount: 6
        )

        let representedAccents = fields.compactMap { field -> AmbientAccent? in
            guard case let .ambient(accent) = field else { return nil }
            return accent
        }
        XCTAssertEqual(Set(representedAccents), Set(accents))
        XCTAssertEqual(fields.count, 6)
    }

    func testAuroraPaletteRepresentsNightAmbientAccent() {
        let fields = AuroraPaletteModel.fieldColors(
            enabledAccents: [AmbientSound.night.accent],
            fieldCount: 6
        )

        XCTAssertTrue(fields.contains(.ambient(AmbientSound.night.accent)))
    }

    func testSystemLanguageUsesRussianOnlyForPrimaryRussianLanguage() {
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["ru-RU", "en"]), .russian)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["en-RU", "ru"]), .english)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.russian.resolve(preferredLanguages: ["en"]), .russian)
        XCTAssertEqual(AppLanguage.english.resolve(preferredLanguages: ["ru"]), .english)
    }

    func testPreferencesRoundTripAndInvalidValuesFallBackSafely() {
        let suiteName = "QrecsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults, preferredLanguages: ["en"])
        preferences.language = .russian
        preferences.theme = .dark
        preferences.manualOffline = true
        preferences.quranVolume = 0.72
        preferences.ambientMasterVolume = 0.43
        preferences.setAmbientEnabled(true, for: .rain)
        preferences.setAmbientVolume(0.31, for: .rain)

        let restored = AppPreferences(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(restored.language, .russian)
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertTrue(restored.manualOffline)
        XCTAssertEqual(restored.quranVolume, 0.72, accuracy: 0.0001)
        XCTAssertEqual(restored.ambientMasterVolume, 0.43, accuracy: 0.0001)
        XCTAssertTrue(restored.ambientEnabled(.rain))
        XCTAssertEqual(restored.ambientVolume(.rain), 0.31, accuracy: 0.0001)

        defaults.set("not-a-language", forKey: AppPreferences.Key.language)
        defaults.set("not-a-theme", forKey: AppPreferences.Key.theme)
        defaults.set(9.0, forKey: AppPreferences.Key.quranVolume)
        let invalid = AppPreferences(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(invalid.language, .system)
        XCTAssertEqual(invalid.theme, .system)
        XCTAssertEqual(invalid.quranVolume, 1, accuracy: 0.0001)
    }

    func testReciterProjectionSearchesAllNamesAndKeepsFavoritesFirst() {
        let reciters = [
            Reciter(id: "a", sourceNameRU: "Шейх Альфа", nameRU: "Альфа", nameEN: "Zayd"),
            Reciter(id: "b", sourceNameRU: "Кари Бета", nameRU: "Бета", nameEN: "Adam"),
            Reciter(id: "c", sourceNameRU: "Другой", nameRU: "Гамма", nameEN: "Musa"),
        ]

        let searched = LibraryProjection.reciterGroups(
            reciters: reciters,
            favorites: ["a"],
            cachedCounts: ["a": 2, "b": 1],
            query: "шейх",
            sort: .name,
            direction: .ascending,
            language: .english,
            effectiveOffline: false
        )
        XCTAssertEqual(searched.favorites.map(\.reciter.id), ["a"])
        XCTAssertTrue(searched.all.isEmpty)
        XCTAssertEqual(searched.favorites.first?.cachedCount, 2)

        let all = LibraryProjection.reciterGroups(
            reciters: reciters,
            favorites: ["a"],
            cachedCounts: ["a": 2, "b": 1],
            query: "",
            sort: .name,
            direction: .descending,
            language: .english,
            effectiveOffline: false
        )
        XCTAssertEqual(all.favorites.map(\.reciter.id), ["a"])
        XCTAssertEqual(all.all.map(\.reciter.id), ["c", "b"])
    }

    func testOfflineReciterProjectionHidesUncachedReciters() {
        let reciters = [
            Reciter(id: "a", sourceNameRU: "А", nameRU: "А", nameEN: "A"),
            Reciter(id: "b", sourceNameRU: "Б", nameRU: "Б", nameEN: "B"),
        ]
        let groups = LibraryProjection.reciterGroups(
            reciters: reciters,
            favorites: ["b"],
            cachedCounts: ["a": 1],
            query: "",
            sort: .name,
            direction: .ascending,
            language: .english,
            effectiveOffline: true
        )
        XCTAssertEqual(groups.favorites.map(\.reciter.id), [])
        XCTAssertEqual(groups.all.map(\.reciter.id), ["a"])
    }

    func testTrackProjectionSearchesBothLanguagesAndNumber() {
        let rows = makeTrackRows()
        XCTAssertEqual(
            LibraryProjection.tracks(
                rows: rows, query: "фати", sort: .number,
                direction: .ascending, language: .english, effectiveOffline: false
            ).map(\.track.surahNumber),
            [1]
        )
        XCTAssertEqual(
            LibraryProjection.tracks(
                rows: rows, query: "baqa", sort: .number,
                direction: .ascending, language: .russian, effectiveOffline: false
            ).map(\.track.surahNumber),
            [2]
        )
        XCTAssertEqual(
            LibraryProjection.tracks(
                rows: rows, query: "114", sort: .number,
                direction: .ascending, language: .english, effectiveOffline: false
            ).map(\.track.surahNumber),
            [114]
        )
    }

    func testTrackProjectionSortsEveryColumnInBothDirections() {
        let rows = makeTrackRows()
        XCTAssertEqual(project(rows, .number, .ascending).map(\.track.surahNumber), [1, 2, 114])
        XCTAssertEqual(project(rows, .number, .descending).map(\.track.surahNumber), [114, 2, 1])
        XCTAssertEqual(project(rows, .name, .ascending).map(\.track.surahNumber), [2, 1, 114])
        XCTAssertEqual(project(rows, .name, .descending).map(\.track.surahNumber), [114, 1, 2])
        XCTAssertEqual(project(rows, .status, .ascending).map(\.track.surahNumber), [2, 114, 1])
        XCTAssertEqual(project(rows, .status, .descending).map(\.track.surahNumber), [1, 114, 2])
    }

    func testReciterComparatorIsIrreflexiveAndUsesStableIDTieBreak() {
        let first = ReciterPresentation(
            reciter: Reciter(id: "a", sourceNameRU: "Одинаково", nameRU: "Одинаково", nameEN: "Same"),
            cachedCount: 0
        )
        let second = ReciterPresentation(
            reciter: Reciter(id: "b", sourceNameRU: "Одинаково", nameRU: "Одинаково", nameEN: "Same"),
            cachedCount: 0
        )

        for direction in SortDirection.allCases {
            XCTAssertFalse(LibraryProjection.reciterPrecedes(
                first, first, direction: direction, language: .english
            ))
        }
        XCTAssertTrue(LibraryProjection.reciterPrecedes(
            first, second, direction: .ascending, language: .english
        ))
        XCTAssertTrue(LibraryProjection.reciterPrecedes(
            second, first, direction: .descending, language: .english
        ))
    }

    func testTrackComparatorsAreIrreflexiveAndStableForEqualKeys() {
        let first = TrackPresentation(
            track: Track(id: "r:a", reciterID: "r", surahNumber: 1, url: URL(string: "https://example.com/a.mp3")!),
            surah: Surah(number: 1, nameRU: "Одинаково", nameEN: "Same"),
            cacheState: nil
        )
        let second = TrackPresentation(
            track: Track(id: "r:b", reciterID: "r", surahNumber: 1, url: URL(string: "https://example.com/b.mp3")!),
            surah: Surah(number: 1, nameRU: "Одинаково", nameEN: "Same"),
            cacheState: nil
        )

        for sort in TrackSort.allCases {
            for direction in SortDirection.allCases {
                XCTAssertFalse(LibraryProjection.trackPrecedes(
                    first, first, sort: sort, direction: direction, language: .english
                ))
            }
            XCTAssertTrue(LibraryProjection.trackPrecedes(
                first, second, sort: sort, direction: .ascending, language: .english
            ))
            XCTAssertTrue(LibraryProjection.trackPrecedes(
                second, first, sort: sort, direction: .descending, language: .english
            ))
        }
    }

    func testOfflineTrackProjectionOnlyShowsCachedRows() {
        let projected = LibraryProjection.tracks(
            rows: makeTrackRows(), query: "", sort: .number,
            direction: .ascending, language: .english, effectiveOffline: true
        )
        XCTAssertEqual(projected.map(\.track.surahNumber), [1])
    }

    func testCatalogDisplayNamesFollowResolvedLanguage() {
        let reciter = Reciter(id: "r", sourceNameRU: "Источник", nameRU: "Русский", nameEN: "English")
        let surah = Surah(number: 1, nameRU: "Аль-Фатиха", nameEN: "Al-Fatihah")
        XCTAssertEqual(reciter.displayName(language: .russian), "Русский")
        XCTAssertEqual(reciter.displayName(language: .english), "English")
        XCTAssertEqual(surah.displayName(language: .russian), "Аль-Фатиха")
        XCTAssertEqual(surah.displayName(language: .english), "Al-Fatihah")
    }

    private func project(
        _ rows: [TrackPresentation],
        _ sort: TrackSort,
        _ direction: SortDirection
    ) -> [TrackPresentation] {
        LibraryProjection.tracks(
            rows: rows, query: "", sort: sort, direction: direction,
            language: .english, effectiveOffline: false
        )
    }

    private func makeTrackRows() -> [TrackPresentation] {
        [
            TrackPresentation(
                track: Track(id: "r:114", reciterID: "r", surahNumber: 114, url: URL(string: "https://example.com/114.mp3")!),
                surah: Surah(number: 114, nameRU: "Ан-Нас", nameEN: "An-Nas"),
                cacheState: .downloading(progress: DownloadProgress(bytesReceived: 1, totalBytesExpected: 2))
            ),
            TrackPresentation(
                track: Track(id: "r:1", reciterID: "r", surahNumber: 1, url: URL(string: "https://example.com/001.mp3")!),
                surah: Surah(number: 1, nameRU: "Аль-Фатиха", nameEN: "Al-Fatihah"),
                cacheState: .cached(CachedDownload(
                    trackID: "r:1", reciterID: "r", relativePath: "1.mp3", byteCount: 1,
                    etag: nil, updatedAt: Date(timeIntervalSince1970: 0)
                ))
            ),
            TrackPresentation(
                track: Track(id: "r:2", reciterID: "r", surahNumber: 2, url: URL(string: "https://example.com/002.mp3")!),
                surah: Surah(number: 2, nameRU: "Аль-Бакара", nameEN: "Al-Baqarah"),
                cacheState: nil
            ),
        ]
    }
}
