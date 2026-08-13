import CryptoKit
import Foundation

enum CacheManagerError: Error, Equatable, Sendable {
    case emptyDownloadedFile
    case incompleteDownload
}

actor CacheManager: CacheManaging {
    private static let maximumActiveDownloads = 2

    private struct OperationGeneration: Equatable, Sendable {
        let global: UInt64
        let track: UInt64
    }

    private struct PendingDownload: Sendable {
        let track: Track
        let generation: OperationGeneration
    }

    private let repository: any UserLibraryRepository
    private let downloader: any DownloadClient
    private let paths: AppPaths
    private let reservationWaitObserver: (@Sendable (String) -> Void)?
    private var states: [String: CacheDownloadState] = [:]
    private var knownTracks: [String: Track] = [:]
    private var reservationTokens: [String: UUID] = [:]
    private var reservationOperations: [String: UUID] = [:]
    private var reservationCompletionWaiters: [
        String: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var pendingDownloads: [PendingDownload] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var globalGeneration: UInt64 = 0
    private var trackGenerations: [String: UInt64] = [:]
    private var globalDeletionDepth = 0
    private var trackDeletionDepths: [String: Int] = [:]
    private var reciterDeletionDepths: [String: Int] = [:]
    private var eventContinuations: [
        String: [UUID: AsyncStream<CacheDownloadState>.Continuation]
    ] = [:]

    private init(
        repository: any UserLibraryRepository,
        downloader: any DownloadClient,
        paths: AppPaths,
        reservationWaitObserver: (@Sendable (String) -> Void)?
    ) {
        self.repository = repository
        self.downloader = downloader
        self.paths = paths
        self.reservationWaitObserver = reservationWaitObserver
    }

    static func make(
        repository: any UserLibraryRepository,
        downloader: any DownloadClient,
        paths: AppPaths,
        reservationWaitObserver: (@Sendable (String) -> Void)? = nil
    ) async throws -> CacheManager {
        try paths.prepareDirectories()
        let manager = CacheManager(
            repository: repository,
            downloader: downloader,
            paths: paths,
            reservationWaitObserver: reservationWaitObserver
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
        guard !isDeletionBlocked(track: track) else {
            updateState(.cancelled, trackID: track.id)
            return
        }
        if reservationOperations[track.id] != nil
            || activeTasks[track.id] != nil
            || pendingDownloads.contains(where: { $0.track.id == track.id }) {
            return
        }
        let generation = operationGeneration(trackID: track.id)
        let reservationToken = UUID()
        reservationTokens[track.id] = reservationToken
        reservationOperations[track.id] = reservationToken
        defer { completeReservationOperation(trackID: track.id, token: reservationToken) }
        let existing = try await repository.download(trackID: track.id)
        guard reservationTokens[track.id] == reservationToken,
              isOperationCurrent(generation, track: track) else {
            updateState(.cancelled, trackID: track.id)
            return
        }
        if let existing {
            if let fileURL = validatedFileURL(for: existing), isRegularFile(fileURL) {
                updateState(.cached(existing), trackID: track.id)
                return
            }
            try await repository.removeDownload(trackID: track.id)
            guard reservationTokens[track.id] == reservationToken,
                  isOperationCurrent(generation, track: track) else {
                updateState(.cancelled, trackID: track.id)
                return
            }
        }

        pendingDownloads.append(PendingDownload(track: track, generation: generation))
        updateState(.queued, trackID: track.id)
        startPendingDownloads()
    }

    func cancel(trackID: String) async {
        if reservationTokens.removeValue(forKey: trackID) != nil {
            updateState(.cancelled, trackID: trackID)
        }
        await waitForReservationOperation(trackID: trackID)
        if let index = pendingDownloads.firstIndex(where: { $0.track.id == trackID }) {
            pendingDownloads.remove(at: index)
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
        beginTrackDeletion(trackID: trackID)
        defer { endTrackDeletion(trackID: trackID) }
        await cancel(trackID: trackID)
        try await removePersistedTrack(trackID: trackID)
        states.removeValue(forKey: trackID)
    }

    func removeAll(reciterID: String) async throws {
        beginReciterDeletion(reciterID: reciterID)
        defer { endReciterDeletion(reciterID: reciterID) }

        let transientIDs = Set(knownTracks.values
            .filter { $0.reciterID == reciterID }
            .map(\.id))
        invalidate(trackIDs: transientIDs)
        for trackID in transientIDs {
            await cancel(trackID: trackID)
        }

        let persisted = try await repository.downloads().filter { $0.reciterID == reciterID }
        let trackIDs = Set(persisted.map(\.trackID)).union(transientIDs)
        invalidate(trackIDs: trackIDs.subtracting(transientIDs))
        for trackID in trackIDs {
            await cancel(trackID: trackID)
            try await removePersistedTrack(trackID: trackID)
            states.removeValue(forKey: trackID)
        }
    }

    func clearAll() async throws {
        beginGlobalDeletion()
        defer { endGlobalDeletion() }

        let transientIDs = Set(
            activeTasks.keys
                + pendingDownloads.map(\.track.id)
                + knownTracks.keys
                + reservationTokens.keys
                + reservationOperations.keys
        )
        for trackID in transientIDs {
            await cancel(trackID: trackID)
        }

        let persisted = try await repository.downloads()
        for download in persisted {
            await cancel(trackID: download.trackID)
            if let fileURL = validatedFileURL(for: download) {
                try removeIfPresent(fileURL)
            }
            try await repository.removeDownload(trackID: download.trackID)
        }
        try removeAllDirectoryEntries()
        states.removeAll()
        pendingDownloads.removeAll()
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
        while activeTasks.count < Self.maximumActiveDownloads, !pendingDownloads.isEmpty {
            let pending = pendingDownloads.removeFirst()
            guard isOperationCurrent(pending.generation, track: pending.track) else {
                updateState(.cancelled, trackID: pending.track.id)
                continue
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performDownload(
                    track: pending.track,
                    generation: pending.generation
                )
            }
            activeTasks[pending.track.id] = task
        }
    }

    private func performDownload(
        track: Track,
        generation: OperationGeneration
    ) async {
        var downloadedFile: DownloadedFile?
        do {
            try ensureOperationCurrent(generation, track: track)
            updateState(.downloading(progress: nil), trackID: track.id)
            let stream = await downloader.events(for: track.url)
            for try await event in stream {
                try Task.checkCancellation()
                try ensureOperationCurrent(generation, track: track)
                switch event {
                case let .progress(progress):
                    updateState(.downloading(progress: progress), trackID: track.id)
                case let .completed(file):
                    file.claimOwnership()
                    downloadedFile = file
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            try ensureOperationCurrent(generation, track: track)
            guard let downloadedFile else {
                throw CacheManagerError.incompleteDownload
            }
            let cached = try await finalize(
                downloadedFile,
                track: track,
                generation: generation
            )
            try ensureOperationCurrent(generation, track: track)
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
        track: Track,
        generation: OperationGeneration
    ) async throws -> CachedDownload {
        try ensureOperationCurrent(generation, track: track)
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
            try ensureOperationCurrent(generation, track: track)
            try await repository.upsertDownload(cached)
            try ensureOperationCurrent(generation, track: track)
            guard let persisted = try await repository.download(trackID: track.id) else {
                throw CacheManagerError.incompleteDownload
            }
            try Task.checkCancellation()
            try ensureOperationCurrent(generation, track: track)
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

    private func operationGeneration(trackID: String) -> OperationGeneration {
        OperationGeneration(
            global: globalGeneration,
            track: trackGenerations[trackID, default: 0]
        )
    }

    private func waitForReservationOperation(trackID: String) async {
        guard reservationOperations[trackID] != nil else { return }
        reservationWaitObserver?(trackID)
        await withCheckedContinuation {
            reservationCompletionWaiters[trackID, default: []].append($0)
        }
    }

    private func completeReservationOperation(trackID: String, token: UUID) {
        if reservationTokens[trackID] == token {
            reservationTokens.removeValue(forKey: trackID)
        }
        guard reservationOperations[trackID] == token else { return }
        reservationOperations.removeValue(forKey: trackID)
        let waiters = reservationCompletionWaiters.removeValue(forKey: trackID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func isOperationCurrent(
        _ generation: OperationGeneration,
        track: Track
    ) -> Bool {
        generation == operationGeneration(trackID: track.id)
            && !isDeletionBlocked(track: track)
    }

    private func ensureOperationCurrent(
        _ generation: OperationGeneration,
        track: Track
    ) throws {
        guard isOperationCurrent(generation, track: track) else {
            throw CancellationError()
        }
    }

    private func isDeletionBlocked(track: Track) -> Bool {
        globalDeletionDepth > 0
            || trackDeletionDepths[track.id, default: 0] > 0
            || reciterDeletionDepths[track.reciterID, default: 0] > 0
    }

    private func beginGlobalDeletion() {
        globalDeletionDepth += 1
        globalGeneration &+= 1
    }

    private func endGlobalDeletion() {
        globalDeletionDepth -= 1
    }

    private func beginTrackDeletion(trackID: String) {
        trackDeletionDepths[trackID, default: 0] += 1
        trackGenerations[trackID, default: 0] &+= 1
    }

    private func endTrackDeletion(trackID: String) {
        let remaining = trackDeletionDepths[trackID, default: 1] - 1
        if remaining == 0 {
            trackDeletionDepths.removeValue(forKey: trackID)
        } else {
            trackDeletionDepths[trackID] = remaining
        }
    }

    private func beginReciterDeletion(reciterID: String) {
        reciterDeletionDepths[reciterID, default: 0] += 1
    }

    private func endReciterDeletion(reciterID: String) {
        let remaining = reciterDeletionDepths[reciterID, default: 1] - 1
        if remaining == 0 {
            reciterDeletionDepths.removeValue(forKey: reciterID)
        } else {
            reciterDeletionDepths[reciterID] = remaining
        }
    }

    private func invalidate(trackIDs: Set<String>) {
        for trackID in trackIDs {
            trackGenerations[trackID, default: 0] &+= 1
        }
    }

    private func removePersistedTrack(trackID: String) async throws {
        if let download = try await repository.download(trackID: trackID),
           let fileURL = validatedFileURL(for: download) {
            try removeIfPresent(fileURL)
        }
        try await repository.removeDownload(trackID: trackID)
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
