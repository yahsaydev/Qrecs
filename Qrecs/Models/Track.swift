import Foundation

struct Track: Identifiable, Hashable, Sendable {
    let id: String
    let reciterID: String
    let surahNumber: Int
    let url: URL
}
