import Foundation

/// Receives completion of the synchronous cleanup attempt for a validated
/// temporary download that was abandoned before a consumer claimed ownership.
protocol DownloadTemporaryFileCleanupObserving: Sendable {
    func didFinishTemporaryFileCleanup(at fileURL: URL)
}

struct DownloadProgress: Equatable, Sendable {
    let bytesReceived: Int64
    let totalBytesExpected: Int64?

    var fractionCompleted: Double? {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytesExpected))
    }
}

struct DownloadedFile: Equatable, Sendable {
    let fileURL: URL
    let byteCount: Int64
    let etag: String?
    private let lease: DownloadedFileLease

    init(
        fileURL: URL,
        byteCount: Int64,
        etag: String?,
        cleanupObserver: (any DownloadTemporaryFileCleanupObserving)? = nil
    ) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.etag = etag
        self.lease = DownloadedFileLease(
            fileURL: fileURL,
            cleanupObserver: cleanupObserver
        )
    }

    /// Transfers cleanup responsibility from the downloader to the cache manager.
    /// Until claimed, dropping the last copy removes the staged `.download` file.
    func claimOwnership() {
        lease.claim()
    }

    static func == (lhs: DownloadedFile, rhs: DownloadedFile) -> Bool {
        lhs.fileURL == rhs.fileURL
            && lhs.byteCount == rhs.byteCount
            && lhs.etag == rhs.etag
    }
}

/// The lock protects the single ownership transition and makes deinit cleanup safe
/// when stream termination and URLSession delegate callbacks race under Swift 6.
private final class DownloadedFileLease: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let cleanupObserver: (any DownloadTemporaryFileCleanupObserving)?
    private var isClaimed = false

    init(
        fileURL: URL,
        cleanupObserver: (any DownloadTemporaryFileCleanupObserving)?
    ) {
        self.fileURL = fileURL
        self.cleanupObserver = cleanupObserver
    }

    func claim() {
        lock.withLock { isClaimed = true }
    }

    deinit {
        let shouldRemove = lock.withLock { !isClaimed }
        if shouldRemove {
            try? FileManager.default.removeItem(at: fileURL)
            cleanupObserver?.didFinishTemporaryFileCleanup(at: fileURL)
        }
    }
}

enum DownloadEvent: Equatable, Sendable {
    case progress(DownloadProgress)
    case completed(DownloadedFile)
}

enum DownloadClientError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case invalidHTTPStatus(Int)
    case emptyFile
    case incompleteDownload
}

protocol DownloadClient: Sendable {
    func events(for url: URL) async -> AsyncThrowingStream<DownloadEvent, Error>
}

/// Internal test seam at the exact point where a validated file leaves the
/// URLSession delegate and becomes visible to the stream consumer.
protocol DownloadHandoffGating: Sendable {
    func waitBeforeHandoff(fileURL: URL)
}

struct URLSessionDownloadClient: DownloadClient, Sendable {
    private let configuration: URLSessionConfiguration
    private let temporaryDirectory: URL
    private let handoffGate: (any DownloadHandoffGating)?
    private let cleanupObserver: (any DownloadTemporaryFileCleanupObserving)?

    init(
        configuration: URLSessionConfiguration = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QrecsDownloads", isDirectory: true),
        handoffGate: (any DownloadHandoffGating)? = nil,
        cleanupObserver: (any DownloadTemporaryFileCleanupObserving)? = nil
    ) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.temporaryDirectory = temporaryDirectory
        self.handoffGate = handoffGate
        self.cleanupObserver = cleanupObserver
    }

    func events(for url: URL) async -> AsyncThrowingStream<DownloadEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DownloadEvent, Error>.makeStream()
        let delegate = DownloadDelegateBridge(
            temporaryDirectory: temporaryDirectory,
            handoffGate: handoffGate,
            cleanupObserver: cleanupObserver,
            continuation: continuation
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: url)
        delegate.connect(session: session, task: task)
        continuation.onTermination = { @Sendable _ in
            delegate.cancel()
        }
        task.resume()
        return stream
    }
}

/// URLSession invokes delegate callbacks concurrently. Every mutable field below is
/// protected by `lock`; this is the narrow synchronization boundary that justifies
/// `@unchecked Sendable` under Swift 6.
private final class DownloadDelegateBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let temporaryDirectory: URL
    private let handoffGate: (any DownloadHandoffGating)?
    private let cleanupObserver: (any DownloadTemporaryFileCleanupObserving)?
    private var continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<DownloadedFile, Error>?
    private var movedFileURL: URL?

    init(
        temporaryDirectory: URL,
        handoffGate: (any DownloadHandoffGating)?,
        cleanupObserver: (any DownloadTemporaryFileCleanupObserving)?,
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.handoffGate = handoffGate
        self.cleanupObserver = cleanupObserver
        self.continuation = continuation
    }

    func connect(session: URLSession, task: URLSessionDownloadTask) {
        lock.withLock {
            self.session = session
            self.task = task
        }
    }

    func cancel() {
        let task: URLSessionDownloadTask? = lock.withLock { self.task }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation? = lock.withLock {
            self.continuation
        }
        continuation?.yield(.progress(DownloadProgress(
            bytesReceived: totalBytesWritten,
            totalBytesExpected: expected
        )))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result: Result<DownloadedFile, Error>
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw DownloadClientError.nonHTTPResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw DownloadClientError.invalidHTTPStatus(response.statusCode)
            }
            let byteCount = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard byteCount > 0 else {
                throw DownloadClientError.emptyFile
            }
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            let destination = temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("download")
            try FileManager.default.moveItem(at: location, to: destination)
            let file = DownloadedFile(
                fileURL: destination,
                byteCount: Int64(byteCount),
                etag: response.value(forHTTPHeaderField: "ETag"),
                cleanupObserver: cleanupObserver
            )
            lock.withLock { movedFileURL = destination }
            result = .success(file)
        } catch {
            result = .failure(error)
        }
        lock.withLock { self.result = result }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let completion: (
            AsyncThrowingStream<DownloadEvent, Error>.Continuation?,
            Result<DownloadedFile, Error>,
            URL?
        ) = lock.withLock {
            let finalResult: Result<DownloadedFile, Error>
            if let error {
                finalResult = .failure(error)
            } else {
                finalResult = result ?? .failure(DownloadClientError.incompleteDownload)
            }
            let values = (continuation, finalResult, movedFileURL)
            continuation = nil
            self.session = nil
            self.task = nil
            result = nil
            movedFileURL = nil
            return values
        }

        switch completion.1 {
        case let .success(file):
            handoffGate?.waitBeforeHandoff(fileURL: file.fileURL)
            completion.0?.yield(.completed(file))
            completion.0?.finish()
        case let .failure(error):
            if let movedFileURL = completion.2 {
                try? FileManager.default.removeItem(at: movedFileURL)
            }
            completion.0?.finish(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }
}
