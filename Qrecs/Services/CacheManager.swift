import CryptoKit
import Foundation

enum CacheManagerError: Error, Equatable, Sendable {
    case emptyDownloadedFile
    case incompleteDownload
}

actor CacheManager: CacheManaging {
    private static let maximumActiveDownloads = 2

    private let repository: any UserLibraryRepository
    private let downloader: any DownloadClient
    private let paths: AppPaths
    private var states: [String: CacheDownloadState] = [:]
    private var knownTracks: [String: Track] = [:]
    private var reservationTokens: [String: UUID] = [:]
    private var pendingTracks: [Track] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var eventContinuations: [
        String: [UUID: AsyncStream<CacheDownloadState>.Continuation]
    ] = [:]

    private init(
        repository: any UserLibraryRepository,
        downloader: any DownloadClient,
        paths: AppPaths
    ) {
        self.repository = repository
        self.downloader = downloader
        self.paths = paths
    }

    static func make(
        repository: any UserLibraryRepository,
        downloader: any DownloadClient,
        paths: AppPaths
    ) async throws -> CacheManager {
        try paths.prepareDirectories()
        let manager = CacheManager(
            repository: repository,
            downloader: downloader,
            paths: paths
        )
        try await manager.reconcile()
        return manager
    }

    static func applicationSupport(
        repository: any UserLibraryRepository
    ) async throws -> CacheManager {
        let paths = try AppPaths.applicationSupport()
        return try await make(
            repository: repository,
            downloader: URLSessionDownloadClient(
                temporaryDirectory: paths.audioCacheDirectory
            ),
            paths: paths
        )
    }

    static func applicationSupport(
        repository: any UserLibraryRepository,
        downloader: any DownloadClient
    ) async throws -> CacheManager {
        try await make(
            repository: repository,
            downloader: downloader,
            paths: AppPaths.applicationSupport()
        )
    }

    func cache(track: Track) async throws {
        knownTracks[track.id] = track
        if reservationTokens[track.id] != nil
            || activeTasks[track.id] != nil
            || pendingTracks.contains(where: { $0.id == track.id }) {
            return
        }
        let reservationToken = UUID()
        reservationTokens[track.id] = reservationToken
        defer {
            if reservationTokens[track.id] == reservationToken {
                reservationTokens.removeValue(forKey: track.id)
            }
        }
        let existing = try await repository.download(trackID: track.id)
        guard reservationTokens[track.id] == reservationToken else { return }
        if let existing {
            if let fileURL = validatedFileURL(for: existing), isRegularFile(fileURL) {
                updateState(.cached(existing), trackID: track.id)
                return
            }
            try await repository.removeDownload(trackID: track.id)
            guard reservationTokens[track.id] == reservationToken else { return }
        }

        pendingTracks.append(track)
        updateState(.queued, trackID: track.id)
        startPendingDownloads()
    }

    func cancel(trackID: String) async {
        if reservationTokens.removeValue(forKey: trackID) != nil {
            updateState(.cancelled, trackID: trackID)
        }
        if let index = pendingTracks.firstIndex(where: { $0.id == trackID }) {
            pendingTracks.remove(at: index)
            updateState(.cancelled, trackID: trackID)
        }
        if let task = activeTasks[trackID] {
            task.cancel()
            await task.value
        }
    }

    func retry(trackID: String) async throws {
        guard let track = knownTracks[trackID] else { return }
        await cancel(trackID: trackID)
        try await cache(track: track)
    }

    func remove(trackID: String) async throws {
        await cancel(trackID: trackID)
        if let download = try await repository.download(trackID: trackID),
           let fileURL = validatedFileURL(for: download) {
            try removeIfPresent(fileURL)
        }
        try await repository.removeDownload(trackID: trackID)
        states.removeValue(forKey: trackID)
        knownTracks.removeValue(forKey: trackID)
    }

    func removeAll(reciterID: String) async throws {
        let persisted = try await repository.downloads().filter { $0.reciterID == reciterID }
        let transientIDs = knownTracks.values
            .filter { $0.reciterID == reciterID }
            .map(\.id)
        for trackID in Set(persisted.map(\.trackID) + transientIDs) {
            try await remove(trackID: trackID)
        }
    }

    func clearAll() async throws {
        let trackIDs = Set(
            activeTasks.keys
                + pendingTracks.map(\.id)
                + knownTracks.keys
                + reservationTokens.keys
                + (try await repository.downloads()).map(\.trackID)
        )
        for trackID in trackIDs {
            await cancel(trackID: trackID)
        }
        for download in try await repository.downloads() {
            if let fileURL = validatedFileURL(for: download) {
                try removeIfPresent(fileURL)
            }
            try await repository.removeDownload(trackID: download.trackID)
        }
        try removeAllDirectoryEntries()
        states.removeAll()
        knownTracks.removeAll()
        pendingTracks.removeAll()
        reservationTokens.removeAll()
    }

    func totalBytes() async throws -> Int64 {
        try await repository.totalDownloadedBytes()
    }

    func state(trackID: String) -> CacheDownloadState? {
        states[trackID]
    }

    func snapshot() -> CacheSnapshot {
        CacheSnapshot(states: states)
    }

    func events(for trackID: String) -> AsyncStream<CacheDownloadState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CacheDownloadState>.makeStream()
        eventContinuations[trackID, default: [:]][id] = continuation
        if let state = states[trackID] {
            continuation.yield(state)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id, trackID: trackID) }
        }
        return stream
    }

    /// Reconciliation treats the database as the index of user-requested offline
    /// files. Missing rows are removed, while every unindexed cache entry—including
    /// finalized orphans and staging leftovers—is deleted from the dedicated cache.
    func reconcile() async throws {
        try paths.prepareDirectories()
        var indexedFileNames: Set<String> = []
        for download in try await repository.downloads() {
            guard let fileURL = validatedFileURL(for: download), isRegularFile(fileURL) else {
                if let safeURL = safeCacheURL(relativePath: download.relativePath) {
                    try removeIfPresent(safeURL)
                }
                try await repository.removeDownload(trackID: download.trackID)
                continue
            }
            indexedFileNames.insert(download.relativePath)
            updateState(.cached(download), trackID: download.trackID)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: paths.audioCacheDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries where !indexedFileNames.contains(entry.lastPathComponent) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    static func finalFileName(trackID: String) -> String {
        let digest = SHA256.hash(data: Data(trackID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mp3"
    }

    private func startPendingDownloads() {
        while activeTasks.count < Self.maximumActiveDownloads, !pendingTracks.isEmpty {
            let track = pendingTracks.removeFirst()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performDownload(track: track)
            }
            activeTasks[track.id] = task
        }
    }

    private func performDownload(track: Track) async {
        var downloadedFile: DownloadedFile?
        do {
            updateState(.downloading(progress: nil), trackID: track.id)
            let stream = await downloader.events(for: track.url)
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .progress(progress):
                    updateState(.downloading(progress: progress), trackID: track.id)
                case let .completed(file):
                    downloadedFile = file
                }
            }
            try Task.checkCancellation()
            guard let downloadedFile else {
                throw CacheManagerError.incompleteDownload
            }
            let cached = try await finalize(downloadedFile, track: track)
            updateState(.cached(cached), trackID: track.id)
        } catch is CancellationError {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile.fileURL) }
            updateState(.cancelled, trackID: track.id)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile.fileURL) }
            updateState(.cancelled, trackID: track.id)
        } catch {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile.fileURL) }
            updateState(.failed(message: String(describing: error)), trackID: track.id)
        }
        activeTasks.removeValue(forKey: track.id)
        startPendingDownloads()
    }

    private func finalize(
        _ downloadedFile: DownloadedFile,
        track: Track
    ) async throws -> CachedDownload {
        let sourceSize = try downloadedFile.fileURL
            .resourceValues(forKeys: [.fileSizeKey])
            .fileSize ?? 0
        guard sourceSize > 0 else { throw CacheManagerError.emptyDownloadedFile }

        let fileName = Self.finalFileName(trackID: track.id)
        let finalURL = paths.audioCacheDirectory.appendingPathComponent(fileName)
        let stagingURL = paths.audioCacheDirectory
            .appendingPathComponent(".\(fileName).\(UUID().uuidString)")
            .appendingPathExtension("staging")
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: downloadedFile.fileURL)
        }

        try FileManager.default.copyItem(at: downloadedFile.fileURL, to: stagingURL)
        try removeIfPresent(finalURL)
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)

        let cached = CachedDownload(
            trackID: track.id,
            reciterID: track.reciterID,
            relativePath: fileName,
            byteCount: Int64(sourceSize),
            etag: downloadedFile.etag,
            updatedAt: Date(
                timeIntervalSince1970: (
                    Date().timeIntervalSince1970 * 1_000
                ).rounded(.down) / 1_000
            )
        )
        do {
            try await repository.upsertDownload(cached)
            guard let persisted = try await repository.download(trackID: track.id) else {
                throw CacheManagerError.incompleteDownload
            }
            try Task.checkCancellation()
            return persisted
        } catch {
            let repository = self.repository
            let trackID = track.id
            let rollback = Task.detached {
                try await repository.removeDownload(trackID: trackID)
            }
            do {
                try await rollback.value
                try? FileManager.default.removeItem(at: finalURL)
            } catch {
                // Keep the final file if metadata cleanup fails, avoiding a row
                // that points at a missing file. Reconciliation handles orphans.
            }
            throw error
        }
    }

    private func updateState(_ state: CacheDownloadState, trackID: String) {
        states[trackID] = state
        for continuation in eventContinuations[trackID]?.values ?? [:].values {
            continuation.yield(state)
        }
    }

    private func removeEventContinuation(_ id: UUID, trackID: String) {
        eventContinuations[trackID]?.removeValue(forKey: id)
        if eventContinuations[trackID]?.isEmpty == true {
            eventContinuations.removeValue(forKey: trackID)
        }
    }

    private func validatedFileURL(for download: CachedDownload) -> URL? {
        guard download.relativePath == Self.finalFileName(trackID: download.trackID) else {
            return nil
        }
        return safeCacheURL(relativePath: download.relativePath)
    }

    private func safeCacheURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              relativePath == URL(fileURLWithPath: relativePath).lastPathComponent,
              !relativePath.contains("/"),
              !relativePath.contains("\\") else {
            return nil
        }
        let candidate = paths.audioCacheDirectory
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        guard parent == paths.audioCacheDirectory.standardizedFileURL else { return nil }
        return candidate
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func removeAllDirectoryEntries() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: paths.audioCacheDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
    }
}
