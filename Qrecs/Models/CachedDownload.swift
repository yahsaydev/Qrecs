import Foundation

struct CachedDownload: Identifiable, Equatable, Sendable {
    var id: String { trackID }

    let trackID: String
    let reciterID: String
    let relativePath: String
    let byteCount: Int64
    let etag: String?
    let updatedAt: Date
}

struct CachedDownloadGroup: Equatable, Sendable {
    let reciterID: String
    let trackCount: Int
    let byteCount: Int64
}
