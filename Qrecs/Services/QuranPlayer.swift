import Foundation

@MainActor
final class QuranPlayer: QuranPlaying {
    private let audio: any QuranAudioBackend
    private let ambient: any AmbientMixing
    private var queue: [Track] = []
    private var currentIndex: Int?
    private var localURLs: [String: URL] = [:]
    private var isNetworkAvailable = true
    private var shouldResumeAfterRetry = false
    private var continuations: [UUID: AsyncStream<PlayerState>.Continuation] = [:]
    private var audioEventTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private(set) var state: PlayerState = .idle

    init(audio: any QuranAudioBackend, ambient: any AmbientMixing) {
        self.audio = audio
        self.ambient = ambient
        audioEventTask = Task { @MainActor [weak self, audio] in
            for await event in audio.events() {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    deinit {
        audioEventTask?.cancel()
        networkTask?.cancel()
    }

    func updates() -> AsyncStream<PlayerState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PlayerState>.makeStream()
        continuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func select(track: Track, queue: [Track], localURLs: [String: URL]) {
        var candidateQueue = Self.canonicalQueue(queue, for: track.reciterID)
        var candidateIndex = candidateQueue.firstIndex(where: { $0.id == track.id })
            ?? candidateQueue.firstIndex(where: { $0.surahNumber == track.surahNumber })
        if candidateIndex == nil, (1...114).contains(track.surahNumber) {
            candidateQueue.append(track)
            candidateQueue.sort { $0.surahNumber < $1.surahNumber }
            candidateIndex = candidateQueue.firstIndex(where: { $0.id == track.id })
        }
        guard let candidateIndex else { return }

        if state.status == .playing {
            audio.pause()
            ambient.pause()
        }
        self.queue = candidateQueue
        self.localURLs = localURLs
        currentIndex = candidateIndex
        loadCurrent(playing: false, resetProgress: true)
    }

    func play() {
        guard state.currentTrack != nil else { return }
        if case .failed = state.status { return }
        if state.source == .remote, !isNetworkAvailable {
            failForNetworkLoss(wasPlaying: true)
            return
        }
        audio.play()
        ambient.play()
        state.status = .playing
        publish()
    }

    func pause() {
        guard state.status == .playing else { return }
        audio.pause()
        ambient.pause()
        state.status = .paused
        publish()
    }

    func stop() {
        guard state.currentTrack != nil else { return }
        audio.stop()
        ambient.stop()
        state.status = .stopped
        state.elapsed = 0
        publish()
    }

    func previous() {
        guard let currentIndex, currentIndex > 0 else { return }
        let wasPlaying = state.status == .playing
        self.currentIndex = currentIndex - 1
        loadCurrent(playing: wasPlaying, resetProgress: true)
    }

    func next() {
        advance(automatic: false)
    }

    func seek(to seconds: TimeInterval) {
        guard state.currentTrack != nil else { return }
        let upperBound = state.duration > 0 ? state.duration : seconds
        let seconds = min(max(seconds, 0), upperBound)
        audio.seek(to: seconds)
        state.elapsed = seconds
        publish()
    }

    func setVolume(_ volume: Float) {
        let volume = min(max(volume, 0), 1)
        audio.setVolume(volume)
        state.volume = volume
        publish()
    }

    func handleNetworkAvailability(_ available: Bool) {
        isNetworkAvailable = available
        guard !available, state.source == .remote else { return }
        switch state.status {
        case .idle, .stopped, .failed:
            return
        case .playing:
            failForNetworkLoss(wasPlaying: true)
        case .paused:
            failForNetworkLoss(wasPlaying: false)
        }
    }

    func retry() {
        guard case .failed(.networkUnavailable) = state.status,
              isNetworkAvailable,
              state.currentTrack != nil else { return }
        let resume = shouldResumeAfterRetry
        loadCurrent(playing: false, resetProgress: false)
        if state.elapsed > 0 {
            audio.seek(to: state.elapsed)
        }
        if resume {
            play()
        }
    }

    func observeNetwork(using monitor: any NetworkMonitoring) {
        networkTask?.cancel()
        networkTask = Task { @MainActor [weak self] in
            await monitor.start()
            let updates = await monitor.updates()
            for await available in updates {
                guard !Task.isCancelled else { return }
                self?.handleNetworkAvailability(available)
            }
        }
    }

    private func advance(automatic: Bool) {
        guard let currentIndex else { return }
        let shouldPlay = automatic || state.status == .playing
        guard currentIndex + 1 < queue.count else {
            audio.stop()
            ambient.stop()
            state.status = .stopped
            state.elapsed = state.duration
            updateNavigationState()
            publish()
            return
        }
        self.currentIndex = currentIndex + 1
        loadCurrent(playing: shouldPlay, resetProgress: true)
    }

    private func loadCurrent(playing: Bool, resetProgress: Bool) {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        let localURL = localURLs[track.id]
        let source: PlaybackSource = localURL == nil ? .remote : .local
        if source == .remote, !isNetworkAvailable {
            state.currentTrack = track
            state.source = source
            updateNavigationState()
            failForNetworkLoss(wasPlaying: playing)
            return
        }
        audio.load(url: localURL ?? track.url)
        state.currentTrack = track
        state.source = source
        state.status = playing ? .playing : .paused
        if resetProgress {
            state.elapsed = 0
            state.duration = 0
        }
        updateNavigationState()
        if playing {
            audio.play()
            if !ambient.state.isPlaying {
                ambient.play()
            }
        }
        publish()
    }

    private func failForNetworkLoss(wasPlaying: Bool) {
        shouldResumeAfterRetry = wasPlaying
        audio.stop()
        ambient.stop()
        state.status = .failed(.networkUnavailable)
        publish()
    }

    private func receive(_ event: QuranAudioEvent) {
        switch event {
        case let .progress(elapsed, duration):
            state.elapsed = max(elapsed, 0)
            state.duration = max(duration, 0)
            publish()
        case .ended:
            advance(automatic: true)
        case let .failed(message):
            audio.stop()
            ambient.stop()
            state.status = .failed(.playback(message))
            publish()
        }
    }

    private func updateNavigationState() {
        guard let currentIndex else {
            state.canGoPrevious = false
            state.canGoNext = false
            return
        }
        state.canGoPrevious = currentIndex > 0
        state.canGoNext = currentIndex + 1 < queue.count
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private static func canonicalQueue(_ tracks: [Track], for reciterID: String) -> [Track] {
        var seen: Set<Int> = []
        return tracks
            .filter { $0.reciterID == reciterID && (1...114).contains($0.surahNumber) }
            .sorted { $0.surahNumber < $1.surahNumber }
            .filter { seen.insert($0.surahNumber).inserted }
    }
}
