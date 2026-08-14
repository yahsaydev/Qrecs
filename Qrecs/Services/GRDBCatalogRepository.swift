import Foundation
import GRDB

enum CatalogRepositoryError: Error, Equatable {
    case bundledCatalogNotFound
    case invalidTrackURL(String)
}

actor GRDBCatalogRepository: CatalogRepository {
    private let database: DatabaseQueue

    init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.label = "QrecsCatalog"
        database = try DatabaseQueue(
            path: databaseURL.path,
            configuration: configuration
        )
    }

    static func bundled(in bundle: Bundle = .main) throws -> GRDBCatalogRepository {
        let databaseURL = bundle.url(
            forResource: "catalog",
            withExtension: "sqlite",
            subdirectory: "Catalog"
        ) ?? bundle.url(forResource: "catalog", withExtension: "sqlite")
        guard let databaseURL else {
            throw CatalogRepositoryError.bundledCatalogNotFound
        }
        return try GRDBCatalogRepository(databaseURL: databaseURL)
    }

    func fetchReciters() async throws -> [Reciter] {
        try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, source_name_ru, name_ru, name_en
                    FROM reciters
                    ORDER BY id
                    """
            ).map { row in
                Reciter(
                    id: row["id"],
                    sourceNameRU: row["source_name_ru"],
                    nameRU: row["name_ru"],
                    nameEN: row["name_en"]
                )
            }
        }
    }

    func fetchSurahs() async throws -> [Surah] {
        try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT number, name_ru, name_en
                    FROM surahs
                    ORDER BY number
                    """
            ).map { row in
                Surah(
                    number: row["number"],
                    nameRU: row["name_ru"],
                    nameEN: row["name_en"]
                )
            }
        }
    }

    func fetchTracks(reciterID: String) async throws -> [Track] {
        try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, reciter_id, surah_number, url
                    FROM tracks
                    WHERE reciter_id = ?
                    ORDER BY surah_number
                    """,
                arguments: [reciterID]
            ).map { row in
                let urlString: String = row["url"]
                guard let url = URL(string: urlString) else {
                    throw CatalogRepositoryError.invalidTrackURL(urlString)
                }
                return Track(
                    id: row["id"],
                    reciterID: row["reciter_id"],
                    surahNumber: row["surah_number"],
                    url: url
                )
            }
        }
    }

    func fetchTrackIDs() async throws -> Set<String> {
        try await database.read { database in
            Set(try String.fetchAll(database, sql: "SELECT id FROM tracks"))
        }
    }
}
