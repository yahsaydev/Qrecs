import Foundation
import XCTest
@testable import Qrecs

final class DownloadClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testSuccessfulDownloadEmitsProgressAndKeepsNonemptyTemporaryFile() async throws {
        let body = Data(repeating: 0x5A, count: 32 * 1024)
        StubURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "audio-v1", "Content-Length": "\(body.count)"]
            )!
            return (response, body)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = URLSessionDownloadClient(
            configuration: stubConfiguration(),
            temporaryDirectory: directory
        )

        var progressEvents: [DownloadProgress] = []
        var completed: DownloadedFile?
        for try await event in await client.events(for: URL(string: "https://qrecs.test/audio.mp3")!) {
            switch event {
            case let .progress(progress): progressEvents.append(progress)
            case let .completed(file): completed = file
            }
        }

        let file = try XCTUnwrap(completed)
        XCTAssertEqual(file.byteCount, Int64(body.count))
        XCTAssertEqual(file.etag, "audio-v1")
        XCTAssertEqual(try Data(contentsOf: file.fileURL), body)
        XCTAssertFalse(progressEvents.isEmpty)
        XCTAssertEqual(progressEvents.last?.bytesReceived, Int64(body.count))
    }

    func testHTTPErrorRemovesTemporaryFileAndThrows() async throws {
        StubURLProtocol.setHandler { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("unavailable".utf8)
            )
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = URLSessionDownloadClient(configuration: stubConfiguration(), temporaryDirectory: directory)

        do {
            for try await _ in await client.events(for: URL(string: "https://qrecs.test/error.mp3")!) {}
            XCTFail("Expected HTTP validation error")
        } catch {
            XCTAssertEqual(error as? DownloadClientError, .invalidHTTPStatus(503))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testEmptySuccessfulResponseThrows() async throws {
        StubURLProtocol.setHandler { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = URLSessionDownloadClient(configuration: stubConfiguration(), temporaryDirectory: directory)

        do {
            for try await _ in await client.events(for: URL(string: "https://qrecs.test/empty.mp3")!) {}
            XCTFail("Expected empty-file error")
        } catch {
            XCTAssertEqual(error as? DownloadClientError, .emptyFile)
        }
    }

    func testCancellationAtCompletedFileHandoffRemovesProductionTemporaryFile() async throws {
        let body = Data(repeating: 0x41, count: 8 * 1024)
        StubURLProtocol.setHandler { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = BlockingDownloadHandoffGate()
        let client = URLSessionDownloadClient(
            configuration: stubConfiguration(),
            temporaryDirectory: directory,
            handoffGate: gate
        )
        let stream = await client.events(for: URL(string: "https://qrecs.test/handoff.mp3")!)
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        gate.waitUntilReached()
        consumer.cancel()
        gate.release()
        await consumer.value
        for _ in 0..<200 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class BlockingDownloadHandoffGate: DownloadHandoffGating, @unchecked Sendable {
    private let condition = NSCondition()
    private var reached = false
    private var released = false

    func waitBeforeHandoff(fileURL: URL) {
        condition.lock()
        reached = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilReached() {
        condition.lock()
        while !reached { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ newHandler: Handler?) {
        lock.withLock { handler = newHandler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentHandler = Self.lock.withLock { Self.handler }
        do {
            let (response, data) = try XCTUnwrap(currentHandler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
