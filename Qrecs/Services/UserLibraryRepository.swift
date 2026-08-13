protocol UserLibraryRepository: Sendable {
    func favoriteReciterIDs() async throws -> Set<String>
    func isFavorite(reciterID: String) async throws -> Bool
    func setFavorite(_ isFavorite: Bool, reciterID: String) async throws
    func toggleFavorite(reciterID: String) async throws -> Bool

    func downloads() async throws -> [CachedDownload]
    func download(trackID: String) async throws -> CachedDownload?
    func upsertDownload(_ download: CachedDownload) async throws
    func removeDownload(trackID: String) async throws
    func cachedTrackIDs() async throws -> Set<String>
    func cachedReciterIDs() async throws -> Set<String>
    func totalDownloadedBytes() async throws -> Int64
    func downloadGroups() async throws -> [CachedDownloadGroup]
}
