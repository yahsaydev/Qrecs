import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import Qrecs

final class AmbientResourceTests: XCTestCase {
    private var sourceAmbientDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Qrecs/Resources/Ambient", isDirectory: true)
    }

    private var hostAppBundle: Bundle {
        let appBundleURL = Bundle(for: AmbientResourceTests.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: appBundleURL)!
    }

    func testMetadataIsCompleteAndLocalized() {
        XCTAssertEqual(AmbientSound.allCases, [.fire, .birds, .rain, .waterfall])
        XCTAssertEqual(AmbientSound.fire.nameEN, "Fire")
        XCTAssertEqual(AmbientSound.fire.nameRU, "Огонь")
        XCTAssertEqual(AmbientSound.birds.nameEN, "Birdsong")
        XCTAssertEqual(AmbientSound.birds.nameRU, "Пение птиц")
        XCTAssertEqual(AmbientSound.rain.nameEN, "Rain")
        XCTAssertEqual(AmbientSound.rain.nameRU, "Дождь")
        XCTAssertEqual(AmbientSound.waterfall.nameEN, "Waterfall")
        XCTAssertEqual(AmbientSound.waterfall.nameRU, "Водопад")
        XCTAssertEqual(AmbientSound.fire.accent.hex, 0xF28C45)
        XCTAssertEqual(AmbientSound.waterfall.accent.hex, 0x247CB3)
        XCTAssertTrue(AmbientSound.allCases.allSatisfy { $0.sourceURL.scheme == "https" })
        XCTAssertTrue(AmbientSound.allCases.allSatisfy { $0.licenseURL.absoluteString == "https://creativecommons.org/publicdomain/zero/1.0/" })
    }

    func testSourceAndBundledAssetsHavePinnedHashesAndAreDecodable() throws {
        for sound in AmbientSound.allCases {
            let sourceURL = sourceAmbientDirectory.appendingPathComponent(sound.resourceFileName)
            let bundledURL = try XCTUnwrap(
                hostAppBundle.url(
                    forResource: sound.resourceBaseName,
                    withExtension: sound.resourceExtension
                )
            )
            XCTAssertEqual(try sha256(sourceURL), sound.sha256, sound.id)
            XCTAssertEqual(try sha256(bundledURL), sound.sha256, sound.id)
            XCTAssertGreaterThan(try AVAudioFile(forReading: bundledURL).length, 0, sound.id)
        }
    }

    func testNoticesNameEveryAuthorItemAndCC0() throws {
        let noticesURL = sourceAmbientDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("THIRD_PARTY_NOTICES")
        let notices = try String(contentsOf: noticesURL, encoding: .utf8)
        for sound in AmbientSound.allCases {
            XCTAssertTrue(notices.contains(sound.author), sound.id)
            XCTAssertTrue(notices.contains(sound.itemURL.absoluteString), sound.id)
        }
        XCTAssertTrue(notices.contains("https://creativecommons.org/publicdomain/zero/1.0/"))
        XCTAssertTrue(notices.contains("copy, modify, distribute and perform"))
        XCTAssertNotNil(
            hostAppBundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: nil),
            "License notices must travel with the application bundle"
        )
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
