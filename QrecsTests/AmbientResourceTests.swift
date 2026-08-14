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
        XCTAssertEqual(AmbientSound.allCases, [.fire, .birds, .rain, .waterfall, .night])
        XCTAssertEqual(AmbientSound.fire.nameEN, "Fire")
        XCTAssertEqual(AmbientSound.fire.nameRU, "Огонь")
        XCTAssertEqual(AmbientSound.birds.nameEN, "Birdsong")
        XCTAssertEqual(AmbientSound.birds.nameRU, "Пение птиц")
        XCTAssertEqual(AmbientSound.rain.nameEN, "Rain")
        XCTAssertEqual(AmbientSound.rain.nameRU, "Дождь")
        XCTAssertEqual(AmbientSound.waterfall.nameEN, "Waterfall")
        XCTAssertEqual(AmbientSound.waterfall.nameRU, "Водопад")
        XCTAssertEqual(AmbientSound.night.nameEN, "Night")
        XCTAssertEqual(AmbientSound.night.nameRU, "Ночь")
        XCTAssertEqual(AmbientSound.fire.accent.hex, 0xF28C45)
        XCTAssertEqual(AmbientSound.waterfall.accent.hex, 0x247CB3)
        XCTAssertEqual(AmbientSound.night.accent.hex, 0x5B4AA8)
        XCTAssertEqual(AmbientSound.night.author, "Solar01")
        XCTAssertEqual(
            AmbientSound.night.itemURL.absoluteString,
            "https://freesound.org/people/Solar01/sounds/662882/"
        )
        XCTAssertEqual(
            AmbientSound.night.licenseURL.absoluteString,
            "https://creativecommons.org/publicdomain/zero/1.0/"
        )
        XCTAssertEqual(AmbientSound.night.sourceURL.scheme, "https")
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

    func testNightAssetHasSmoothLoopBoundary() throws {
        let nightURL = sourceAmbientDirectory.appendingPathComponent(AmbientSound.night.resourceFileName)
        let pcm = try pcm16WAV(at: nightURL)

        XCTAssertEqual(pcm.channelCount, 2)
        XCTAssertEqual(pcm.sampleRate, 44_100)
        let comparisonFrameCount = pcm.sampleRate / 10

        for channel in 0..<pcm.channelCount {
            let samples = stride(from: channel, to: pcm.samples.count, by: pcm.channelCount)
                .map { pcm.samples[$0] }
            let boundaryJump = abs(Int(samples[0]) - Int(samples[samples.count - 1]))
            XCTAssertLessThanOrEqual(boundaryJump, 512, "channel \(channel) loop boundary")

            let leadingRMS = rms(samples.prefix(comparisonFrameCount))
            let trailingRMS = rms(samples.suffix(comparisonFrameCount))
            let relativeDifference = abs(leadingRMS - trailingRMS) / max(leadingRMS, trailingRMS)
            XCTAssertLessThanOrEqual(relativeDifference, 0.2, "channel \(channel) boundary loudness")
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

    private func pcm16WAV(at url: URL) throws -> (
        channelCount: Int,
        sampleRate: Int,
        samples: [Int16]
    ) {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var channelCount = 0
        var sampleRate = 0
        var bitsPerSample = 0
        var audioFormat = 0
        var sampleData: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = littleEndianUInt32(data, at: offset + 4)
            let payloadOffset = offset + 8
            guard payloadOffset + chunkSize <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if chunkID == "fmt ", chunkSize >= 16 {
                audioFormat = littleEndianUInt16(data, at: payloadOffset)
                channelCount = littleEndianUInt16(data, at: payloadOffset + 2)
                sampleRate = littleEndianUInt32(data, at: payloadOffset + 4)
                bitsPerSample = littleEndianUInt16(data, at: payloadOffset + 14)
            } else if chunkID == "data" {
                sampleData = Data(data[payloadOffset..<(payloadOffset + chunkSize)])
            }
            offset = payloadOffset + chunkSize + (chunkSize % 2)
        }

        guard audioFormat == 1,
              channelCount == 2,
              sampleRate == 44_100,
              bitsPerSample == 16,
              let sampleData,
              sampleData.count.isMultiple(of: 2) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let samples = stride(from: 0, to: sampleData.count, by: 2).map { index in
            Int16(bitPattern: UInt16(littleEndianUInt16(sampleData, at: index)))
        }
        return (channelCount, sampleRate, samples)
    }

    private func littleEndianUInt16(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> Int {
        littleEndianUInt16(data, at: offset) | (littleEndianUInt16(data, at: offset + 2) << 16)
    }

    private func rms<S: Sequence>(_ samples: S) -> Double where S.Element == Int16 {
        var sum = 0.0
        var count = 0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
            count += 1
        }
        return sqrt(sum / Double(count))
    }
}
