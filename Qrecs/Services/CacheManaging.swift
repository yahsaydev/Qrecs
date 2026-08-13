protocol CacheManaging: Sendable {
    func cache(track: Track) async throws
    func cancel(trackID: String) async
    func retry(trackID: String) async throws
    func remove(trackID: String) async throws
    func removeAll(reciterID: String) async throws
    func clearAll() async throws
    func totalBytes() async throws -> Int64
    func state(trackID: String) async -> CacheDownloadState?
    func snapshot() async -> CacheSnapshot
    func events(for trackID: String) async -> AsyncStream<CacheDownloadState>
}
