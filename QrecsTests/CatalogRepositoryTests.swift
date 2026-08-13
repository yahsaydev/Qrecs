import Foundation
import XCTest
@testable import Qrecs

final class CatalogRepositoryTests: XCTestCase {
    private var generatedCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Qrecs/Resources/Catalog/catalog.sqlite")
    }

    func testFetchesExpectedCountsAndCanonicalSurahBounds() async throws {
        let repository = try GRDBCatalogRepository(databaseURL: generatedCatalogURL)

        let reciters = try await repository.fetchReciters()
        let surahs = try await repository.fetchSurahs()

        XCTAssertEqual(reciters.count, 172)
        XCTAssertEqual(surahs.count, 114)
        XCTAssertEqual(surahs.first, Surah(number: 1, nameRU: "Аль-Фатиха", nameEN: "Al-Fatihah"))
        XCTAssertEqual(surahs.last, Surah(number: 114, nameRU: "Ан-Нас", nameEN: "An-Nas"))
    }

    func testEveryReciterHasAll114Tracks() async throws {
        let repository = try GRDBCatalogRepository(databaseURL: generatedCatalogURL)
        let reciters = try await repository.fetchReciters()

        for reciter in reciters {
            let tracks = try await repository.fetchTracks(reciterID: reciter.id)
            XCTAssertEqual(tracks.count, 114, "Unexpected track count for \(reciter.id)")
            XCTAssertEqual(tracks.first?.surahNumber, 1)
            XCTAssertEqual(tracks.last?.surahNumber, 114)
        }
    }

    func testReadOnlyRepositoryCanOpenNonWritableCatalogWithoutChangingIt() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let copiedCatalog = temporaryDirectory.appendingPathComponent("catalog.sqlite")
        try FileManager.default.copyItem(at: generatedCatalogURL, to: copiedCatalog)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: copiedCatalog.path
        )
        let bytesBeforeAccess = try Data(contentsOf: copiedCatalog)

        let repository = try GRDBCatalogRepository(databaseURL: copiedCatalog)
        let reciters = try await repository.fetchReciters()
        XCTAssertEqual(reciters.count, 172)

        XCTAssertEqual(try Data(contentsOf: copiedCatalog), bytesBeforeAccess)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
            ["catalog.sqlite"]
        )
    }
}
