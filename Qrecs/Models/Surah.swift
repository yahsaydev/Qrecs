struct Surah: Identifiable, Hashable, Sendable {
    var id: Int { number }

    let number: Int
    let nameRU: String
    let nameEN: String
}
