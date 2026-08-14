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

    private var hostAppBundle: Bundle {
        let appBundleURL = Bundle(for: CatalogRepositoryTests.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: appBundleURL)!
    }

    func testBundledRepositoryLoadsCatalogFromHostAppResources() async throws {
        XCTAssertNotNil(
            hostAppBundle.url(forResource: "catalog", withExtension: "sqlite")
        )
        let repository = try GRDBCatalogRepository.bundled(in: hostAppBundle)

        let reciters = try await repository.fetchReciters()
        let surahs = try await repository.fetchSurahs()

        XCTAssertEqual(reciters.count, 173)
        XCTAssertEqual(surahs.count, 114)
        XCTAssertEqual(
            reciters.first(where: { $0.id == "reciter-118" })?.nameEN,
            "Mustafa Raad Al-Azawi"
        )
    }

    func testFetchesExpectedCountsAndCanonicalSurahBounds() async throws {
        let repository = try GRDBCatalogRepository(databaseURL: generatedCatalogURL)

        let reciters = try await repository.fetchReciters()
        let surahs = try await repository.fetchSurahs()

        XCTAssertEqual(reciters.count, 173)
        XCTAssertEqual(surahs.count, 114)
        XCTAssertEqual(surahs.first, Surah(number: 1, nameRU: "Аль-Фатиха", nameEN: "Al-Fatihah"))
        XCTAssertEqual(surahs.last, Surah(number: 114, nameRU: "Ан-Нас", nameEN: "An-Nas"))
    }

    func testEveryReciterHasAUniqueOrderedSparseSafeTrackSet() async throws {
        let repository = try GRDBCatalogRepository(databaseURL: generatedCatalogURL)
        let reciters = try await repository.fetchReciters()
        var union: Set<String> = []

        for reciter in reciters {
            let tracks = try await repository.fetchTracks(reciterID: reciter.id)
            XCTAssertFalse(tracks.isEmpty, "Empty track set for \(reciter.id)")
            XCTAssertEqual(tracks.map(\.surahNumber), tracks.map(\.surahNumber).sorted())
            XCTAssertEqual(Set(tracks.map(\.surahNumber)).count, tracks.count)
            XCTAssertTrue(tracks.allSatisfy { $0.reciterID == reciter.id })
            XCTAssertTrue(tracks.allSatisfy { (1...114).contains($0.surahNumber) })
            union.formUnion(tracks.map(\.id))
        }

        let repositoryTrackIDs = try await repository.fetchTrackIDs()
        XCTAssertEqual(repositoryTrackIDs, union)
    }

    func testMuhammadHishamHasOnlyPublishedSparseSurahsAndStableTrackIDs() async throws {
        let repository = try GRDBCatalogRepository(databaseURL: generatedCatalogURL)
        let reciterID = "surahquran-qari-10"
        let reciter = try await repository.fetchReciters().first { $0.id == reciterID }
        let tracks = try await repository.fetchTracks(reciterID: reciterID)
        let expectedNumbers = [
            2, 12, 15, 18, 19, 26, 31, 36, 49, 50, 53, 54, 55, 56,
            66, 67, 68, 69, 73, 75, 76, 78, 79,
        ]

        XCTAssertEqual(reciter?.nameRU, "Мухаммад Хишам")
        XCTAssertEqual(reciter?.nameEN, "Muhammad Hisham")
        XCTAssertEqual(tracks.map(\.surahNumber), expectedNumbers)
        XCTAssertEqual(
            tracks.map(\.id),
            expectedNumbers.map { "\(reciterID)-\(String(format: "%03d", $0))" }
        )
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
        XCTAssertEqual(reciters.count, 173)

        XCTAssertEqual(try Data(contentsOf: copiedCatalog), bytesBeforeAccess)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
            ["catalog.sqlite"]
        )
    }
}
