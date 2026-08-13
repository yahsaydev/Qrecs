import Foundation

struct ReciterPresentation: Identifiable, Equatable, Sendable {
    var id: String { reciter.id }
    let reciter: Reciter
    let cachedCount: Int
}

struct ReciterGroups: Equatable, Sendable {
    let favorites: [ReciterPresentation]
    let all: [ReciterPresentation]
}

struct TrackPresentation: Identifiable, Equatable, Sendable {
    var id: String { track.id }
    let track: Track
    let surah: Surah
    let cacheState: CacheDownloadState?

    var isCached: Bool {
        if case .cached = cacheState { return true }
        return false
    }
}

enum LibraryProjection {
    static func reciterGroups(
        reciters: [Reciter],
        favorites: Set<String>,
        cachedCounts: [String: Int],
        query: String,
        sort: ReciterSort,
        direction: SortDirection,
        language: ResolvedAppLanguage,
        effectiveOffline: Bool
    ) -> ReciterGroups {
        let query = normalized(query)
        let rows = reciters
            .filter { reciter in
                (!effectiveOffline || (cachedCounts[reciter.id] ?? 0) > 0)
                    && (query.isEmpty || [reciter.nameRU, reciter.nameEN, reciter.sourceNameRU]
                        .contains { normalized($0).contains(query) })
            }
            .map {
                ReciterPresentation(
                    reciter: $0,
                    cachedCount: cachedCounts[$0.id] ?? 0
                )
            }
            .sorted { lhs, rhs in
                switch sort {
                case .name:
                    reciterPrecedes(lhs, rhs, direction: direction, language: language)
                }
            }
        return ReciterGroups(
            favorites: rows.filter { favorites.contains($0.id) },
            all: rows.filter { !favorites.contains($0.id) }
        )
    }

    static func tracks(
        rows: [TrackPresentation],
        query: String,
        sort: TrackSort,
        direction: SortDirection,
        language: ResolvedAppLanguage,
        effectiveOffline: Bool
    ) -> [TrackPresentation] {
        let query = normalized(query)
        return rows
            .filter { row in
                (!effectiveOffline || row.isCached)
                    && (query.isEmpty
                        || normalized(row.surah.nameRU).contains(query)
                        || normalized(row.surah.nameEN).contains(query)
                        || String(row.track.surahNumber).contains(query))
            }
            .sorted { lhs, rhs in
                trackPrecedes(
                    lhs, rhs, sort: sort,
                    direction: direction, language: language
                )
            }
    }

    static func reciterPrecedes(
        _ lhs: ReciterPresentation,
        _ rhs: ReciterPresentation,
        direction: SortDirection,
        language: ResolvedAppLanguage
    ) -> Bool {
        var result = lhs.reciter.displayName(language: language)
            .localizedCaseInsensitiveCompare(rhs.reciter.displayName(language: language))
        if result == .orderedSame {
            result = ordering(lhs.id, rhs.id)
        }
        return precedes(result, direction: direction)
    }

    static func trackPrecedes(
        _ lhs: TrackPresentation,
        _ rhs: TrackPresentation,
        sort: TrackSort,
        direction: SortDirection,
        language: ResolvedAppLanguage
    ) -> Bool {
        let primary: ComparisonResult
        switch sort {
        case .number:
            primary = ordering(lhs.track.surahNumber, rhs.track.surahNumber)
        case .name:
            primary = lhs.surah.displayName(language: language)
                .localizedCaseInsensitiveCompare(rhs.surah.displayName(language: language))
        case .status:
            primary = ordering(cacheRank(lhs.cacheState), cacheRank(rhs.cacheState))
        }
        let numbered = primary == .orderedSame
            ? ordering(lhs.track.surahNumber, rhs.track.surahNumber)
            : primary
        let stable = numbered == .orderedSame
            ? ordering(lhs.id, rhs.id)
            : numbered
        return precedes(stable, direction: direction)
    }

    private static func cacheRank(_ state: CacheDownloadState?) -> Int {
        switch state {
        case .none:
            0
        case .queued, .downloading, .failed, .cancelled:
            1
        case .cached:
            2
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ordering<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func precedes(
        _ result: ComparisonResult,
        direction: SortDirection
    ) -> Bool {
        switch (result, direction) {
        case (.orderedAscending, .ascending), (.orderedDescending, .descending): true
        case (.orderedAscending, .descending), (.orderedDescending, .ascending),
             (.orderedSame, _): false
        }
    }
}

extension Reciter {
    func displayName(language: ResolvedAppLanguage) -> String {
        language == .russian ? nameRU : nameEN
    }
}

extension Surah {
    func displayName(language: ResolvedAppLanguage) -> String {
        language == .russian ? nameRU : nameEN
    }
}
