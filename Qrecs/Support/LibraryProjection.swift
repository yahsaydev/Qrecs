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
                compare(
                    lhs.reciter.displayName(language: language),
                    rhs.reciter.displayName(language: language),
                    direction: direction,
                    fallbackAscending: lhs.id < rhs.id
                )
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
                let ascending: Bool
                switch sort {
                case .number:
                    ascending = lhs.track.surahNumber < rhs.track.surahNumber
                case .name:
                    ascending = compare(
                        lhs.surah.displayName(language: language),
                        rhs.surah.displayName(language: language),
                        direction: .ascending,
                        fallbackAscending: lhs.track.surahNumber < rhs.track.surahNumber
                    )
                case .status:
                    let leftRank = cacheRank(lhs.cacheState)
                    let rightRank = cacheRank(rhs.cacheState)
                    ascending = leftRank == rightRank
                        ? lhs.track.surahNumber < rhs.track.surahNumber
                        : leftRank < rightRank
                }
                return direction == .ascending ? ascending : !ascending
            }
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

    private static func compare(
        _ lhs: String,
        _ rhs: String,
        direction: SortDirection,
        fallbackAscending: Bool
    ) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        let ascending: Bool
        switch comparison {
        case .orderedAscending: ascending = true
        case .orderedDescending: ascending = false
        case .orderedSame: ascending = fallbackAscending
        }
        return direction == .ascending ? ascending : !ascending
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
