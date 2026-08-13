import Foundation
import Network

protocol NetworkMonitoring: Sendable {
    func start() async
    func stop() async
    func isNetworkAvailable() async -> Bool
    func updates() async -> AsyncStream<Bool>
}

enum OfflinePolicy {
    static func effectiveOffline(
        manualOffline: Bool,
        networkAvailable: Bool
    ) -> Bool {
        manualOffline || !networkAvailable
    }
}

actor NWPathNetworkMonitor: NetworkMonitoring {
    private let queue = DispatchQueue(label: "com.heezya.Qrecs.NetworkMonitor")
    private var monitor: NWPathMonitor?
    private var monitorID: UUID?
    private var networkAvailable = false
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        let monitorID = UUID()
        self.monitor = monitor
        self.monitorID = monitorID
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { await self?.receive(available, from: monitorID) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        monitorID = nil
        publish(false)
    }

    func isNetworkAvailable() -> Bool {
        networkAvailable
    }

    func updates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuations[id] = continuation
        continuation.yield(networkAvailable)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func receive(_ available: Bool, from monitorID: UUID) {
        guard self.monitorID == monitorID else { return }
        publish(available)
    }

    private func publish(_ available: Bool) {
        networkAvailable = available
        for continuation in continuations.values {
            continuation.yield(available)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
