import Foundation
import Network

protocol RegionAutoSelecting: Sendable {
    func selectRegionID(from regions: [PIARegion], transport: VPNTransport) async -> String?
    func measureLatencies(from regions: [PIARegion], transport: VPNTransport) async -> [String: Double]
}

protocol EndpointLatencyMeasuring: Sendable {
    func measureLatency(to ipAddress: String, timeoutMilliseconds: Int) async -> Double?
}

struct LatencyBasedRegionAutoSelector: RegionAutoSelecting {
    let latencyMeasurer: EndpointLatencyMeasuring
    let timeoutMilliseconds: Int
    let maxConcurrentMeasurements: Int

    init(
        latencyMeasurer: EndpointLatencyMeasuring = TCPConnectLatencyMeasurer(),
        timeoutMilliseconds: Int = 1000,
        maxConcurrentMeasurements: Int = 128
    ) {
        self.latencyMeasurer = latencyMeasurer
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxConcurrentMeasurements = max(1, maxConcurrentMeasurements)
    }

    func selectRegionID(from regions: [PIARegion], transport: VPNTransport) async -> String? {
        let latencies = await measureLatencies(from: regions, transport: transport)
        return latencies.min(by: { $0.value < $1.value })?.key
    }

    func measureLatencies(from regions: [PIARegion], transport: VPNTransport) async -> [String: Double] {
        let candidates = regions.compactMap { region -> (String, String)? in
            if let endpoint = region.servers.meta.first {
                return (region.selectionID, endpoint.ip)
            }

            guard let endpoint = region.servers.endpoint(for: transport) else {
                return nil
            }
            return (region.selectionID, endpoint.ip)
        }

        guard !candidates.isEmpty else {
            return [:]
        }

        var latencies: [String: Double] = [:]
        let batches = candidates.chunked(into: maxConcurrentMeasurements)

        for batch in batches {
            if Task.isCancelled {
                break
            }

            let batchLatencies = await withTaskGroup(of: (String, Double?).self, returning: [String: Double].self) { group in
                for candidate in batch {
                    group.addTask {
                        let latency = await latencyMeasurer.measureLatency(
                            to: candidate.1,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                        return (candidate.0, latency)
                    }
                }

                var batchResults: [String: Double] = [:]

                for await result in group {
                    guard let latency = result.1 else {
                        continue
                    }
                    batchResults[result.0] = latency
                }

                return batchResults
            }

            for (regionID, latency) in batchLatencies {
                latencies[regionID] = latency
            }

        }

        return latencies
    }
}

struct TCPConnectLatencyMeasurer: EndpointLatencyMeasuring {
    let port: UInt16

    init(port: UInt16 = 443) {
        self.port = port
    }

    func measureLatency(to ipAddress: String, timeoutMilliseconds: Int) async -> Double? {
        let runner = TCPConnectionProbe(
            host: NWEndpoint.Host(ipAddress),
            port: NWEndpoint.Port(rawValue: port) ?? .https,
            timeoutMilliseconds: timeoutMilliseconds
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                runner.start(continuation: continuation)
            }
        } onCancel: {
            runner.cancel()
        }
    }
    
    private final class TCPConnectionProbe: @unchecked Sendable {
        private let host: NWEndpoint.Host
        private let port: NWEndpoint.Port
        private let timeoutMilliseconds: Int
        private let lock = NSLock()
        private let queue = DispatchQueue(
            label: "uk.tarun.PrivateClient.latency-probe",
            qos: .utility
        )

        private var continuation: CheckedContinuation<Double?, Never>?
        private var connection: NWConnection?
        private var timeoutWorkItem: DispatchWorkItem?
        private var didResume = false
        private var isCancelled = false
        private var startTime: DispatchTime?

        init(host: NWEndpoint.Host, port: NWEndpoint.Port, timeoutMilliseconds: Int) {
            self.host = host
            self.port = port
            self.timeoutMilliseconds = timeoutMilliseconds
        }

        func start(continuation: CheckedContinuation<Double?, Never>) {
            let connection = NWConnection(host: host, port: port, using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }

            lock.lock()
            if isCancelled || didResume {
                didResume = true
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }

            self.continuation = continuation
            self.connection = connection
            self.startTime = .now()
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish(with: nil)
                connection.cancel()
            }
            self.timeoutWorkItem = timeoutWorkItem
            lock.unlock()

            queue.asyncAfter(
                deadline: .now() + .milliseconds(timeoutMilliseconds),
                execute: timeoutWorkItem
            )
            connection.start(queue: queue)
        }

        func cancel() {
            let connection: NWConnection?
            let timeoutWorkItem: DispatchWorkItem?
            let continuation: CheckedContinuation<Double?, Never>?

            lock.lock()
            isCancelled = true
            connection = self.connection
            timeoutWorkItem = self.timeoutWorkItem
            if didResume {
                continuation = nil
            } else {
                didResume = true
                continuation = self.continuation
                clearStateLocked()
            }
            lock.unlock()

            timeoutWorkItem?.cancel()
            connection?.cancel()
            continuation?.resume(returning: nil)
        }

        private func handle(state: NWConnection.State) {
            switch state {
            case .ready:
                let latency = latencyMilliseconds()
                finish(with: latency)
                connection?.cancel()
            case .failed, .cancelled:
                finish(with: nil)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                finish(with: nil)
            }
        }

        private func finish(with latency: Double?) {
            let timeoutWorkItem: DispatchWorkItem?
            let continuation: CheckedContinuation<Double?, Never>?

            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }

            didResume = true
            timeoutWorkItem = self.timeoutWorkItem
            continuation = self.continuation
            clearStateLocked()
            lock.unlock()

            timeoutWorkItem?.cancel()
            continuation?.resume(returning: latency)
        }

        private func latencyMilliseconds() -> Double? {
            lock.lock()
            let startTime = self.startTime
            lock.unlock()

            guard let startTime else {
                return nil
            }

            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            return Double(elapsedNanoseconds) / 1_000_000
        }

        private func clearStateLocked() {
            continuation = nil
            connection = nil
            timeoutWorkItem = nil
            startTime = nil
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }

        var chunks: [[Element]] = []
        chunks.reserveCapacity((count / size) + 1)

        var startIndex = 0
        while startIndex < count {
            let endIndex = Swift.min(startIndex + size, count)
            chunks.append(Array(self[startIndex..<endIndex]))
            startIndex = endIndex
        }
        return chunks
    }
}
