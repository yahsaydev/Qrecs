protocol CatalogRepository: Sendable {
    func fetchReciters() async throws -> [Reciter]
    func fetchSurahs() async throws -> [Surah]
    func fetchTracks(reciterID: String) async throws -> [Track]
}
