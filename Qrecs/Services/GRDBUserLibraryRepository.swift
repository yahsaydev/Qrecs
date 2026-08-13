import Foundation
import GRDB

actor GRDBUserLibraryRepository: UserLibraryRepository {
    private let database: DatabaseQueue

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "QrecsUserLibrary"
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(database)
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> GRDBUserLibraryRepository {
        let paths = try AppPaths.applicationSupport(fileManager: fileManager)
        try paths.prepareDirectories(fileManager: fileManager)
        return try GRDBUserLibraryRepository(databaseURL: paths.userDatabaseURL)
    }

    func favoriteReciterIDs() async throws -> Set<String> {
        try await database.read { database in
            Set(try String.fetchAll(database, sql: "SELECT reciter_id FROM favorites"))
        }
    }

    func isFavorite(reciterID: String) async throws -> Bool {
        try await database.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM favorites WHERE reciter_id = ?)",
                arguments: [reciterID]
            ) ?? false
        }
    }

    func setFavorite(_ isFavorite: Bool, reciterID: String) async throws {
        try await database.write { database in
            if isFavorite {
                try database.execute(
                    sql: "INSERT OR IGNORE INTO favorites (reciter_id, created_at) VALUES (?, ?)",
                    arguments: [reciterID, Date()]
                )
            } else {
                try database.execute(
                    sql: "DELETE FROM favorites WHERE reciter_id = ?",
                    arguments: [reciterID]
                )
            }
        }
    }

    func toggleFavorite(reciterID: String) async throws -> Bool {
        try await database.write { database in
            let exists = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM favorites WHERE reciter_id = ?)",
                arguments: [reciterID]
            ) ?? false
            if exists {
                try database.execute(
                    sql: "DELETE FROM favorites WHERE reciter_id = ?",
                    arguments: [reciterID]
                )
                return false
            }
            try database.execute(
                sql: "INSERT INTO favorites (reciter_id, created_at) VALUES (?, ?)",
                arguments: [reciterID, Date()]
            )
            return true
        }
    }

    func downloads() async throws -> [CachedDownload] {
        try await database.read { database in
            try Self.fetchDownloads(
                database,
                sql: """
                    SELECT track_id, reciter_id, relative_path, byte_count, etag, updated_at
                    FROM downloads
                    ORDER BY track_id
                    """
            )
        }
    }

    func download(trackID: String) async throws -> CachedDownload? {
        try await database.read { database in
            try Self.fetchDownloads(
                database,
                sql: """
                    SELECT track_id, reciter_id, relative_path, byte_count, etag, updated_at
                    FROM downloads
                    WHERE track_id = ?
                    """,
                arguments: [trackID]
            ).first
        }
    }

    func upsertDownload(_ download: CachedDownload) async throws {
        try await database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO downloads
                        (track_id, reciter_id, relative_path, byte_count, etag, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(track_id) DO UPDATE SET
                        reciter_id = excluded.reciter_id,
                        relative_path = excluded.relative_path,
                        byte_count = excluded.byte_count,
                        etag = excluded.etag,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    download.trackID,
                    download.reciterID,
                    download.relativePath,
                    download.byteCount,
                    download.etag,
                    download.updatedAt,
                ]
            )
        }
    }

    func removeDownload(trackID: String) async throws {
        try await database.write { database in
            try database.execute(
                sql: "DELETE FROM downloads WHERE track_id = ?",
                arguments: [trackID]
            )
        }
    }

    func cachedTrackIDs() async throws -> Set<String> {
        try await database.read { database in
            Set(try String.fetchAll(database, sql: "SELECT track_id FROM downloads"))
        }
    }

    func cachedReciterIDs() async throws -> Set<String> {
        try await database.read { database in
            Set(try String.fetchAll(database, sql: "SELECT DISTINCT reciter_id FROM downloads"))
        }
    }

    func totalDownloadedBytes() async throws -> Int64 {
        try await database.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT COALESCE(SUM(byte_count), 0) FROM downloads"
            ) ?? 0
        }
    }

    func downloadGroups() async throws -> [CachedDownloadGroup] {
        try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT reciter_id, COUNT(*) AS track_count,
                           COALESCE(SUM(byte_count), 0) AS byte_count
                    FROM downloads
                    GROUP BY reciter_id
                    ORDER BY reciter_id
                    """
            ).map { row in
                CachedDownloadGroup(
                    reciterID: row["reciter_id"],
                    trackCount: row["track_count"],
                    byteCount: row["byte_count"]
                )
            }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createUserLibrary") { database in
            try database.create(table: "favorites") { table in
                table.column("reciter_id", .text).primaryKey()
                table.column("created_at", .datetime).notNull()
            }
            try database.create(table: "downloads") { table in
                table.column("track_id", .text).primaryKey()
                table.column("reciter_id", .text).notNull()
                table.column("relative_path", .text).notNull()
                table.column("byte_count", .integer).notNull()
                table.column("etag", .text)
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(
                index: "downloads_on_reciter_id",
                on: "downloads",
                columns: ["reciter_id"]
            )
        }
        return migrator
    }

    private static func fetchDownloads(
        _ database: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> [CachedDownload] {
        try Row.fetchAll(database, sql: sql, arguments: arguments).map { row in
            CachedDownload(
                trackID: row["track_id"],
                reciterID: row["reciter_id"],
                relativePath: row["relative_path"],
                byteCount: row["byte_count"],
                etag: row["etag"],
                updatedAt: row["updated_at"]
            )
        }
    }
}
