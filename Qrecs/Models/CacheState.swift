enum CacheDownloadState: Equatable, Sendable {
    case queued
    case downloading(progress: DownloadProgress?)
    case cached(CachedDownload)
    case failed(message: String)
    case cancelled
}

struct CacheSnapshot: Equatable, Sendable {
    let states: [String: CacheDownloadState]
}
