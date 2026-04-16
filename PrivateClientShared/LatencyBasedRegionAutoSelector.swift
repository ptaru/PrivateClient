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
    let refinementCandidateCount: Int

    init(
        latencyMeasurer: EndpointLatencyMeasuring = TCPConnectLatencyMeasurer(),
        timeoutMilliseconds: Int = 1000,
        maxConcurrentMeasurements: Int = 32,
        refinementCandidateCount: Int = 16
    ) {
        self.latencyMeasurer = latencyMeasurer
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxConcurrentMeasurements = max(1, maxConcurrentMeasurements)
        self.refinementCandidateCount = max(0, refinementCandidateCount)
    }

    init(
        latencyMeasurer: EndpointLatencyMeasuring = TCPConnectLatencyMeasurer(),
        timeoutMilliseconds: Int = 1000,
        maxConcurrentMeasurements: Int = 16
    ) {
        self.init(
            latencyMeasurer: latencyMeasurer,
            timeoutMilliseconds: timeoutMilliseconds,
            maxConcurrentMeasurements: maxConcurrentMeasurements,
            refinementCandidateCount: 24
        )
    }

    func selectRegionID(from regions: [PIARegion], transport: VPNTransport) async -> String? {
        let latencies = await measureLatencies(from: regions, transport: transport)
        return latencies.min(by: { $0.value < $1.value })?.key
    }

    func measureLatencies(from regions: [PIARegion], transport: VPNTransport) async -> [String: Double] {
        let candidatesByRegion = regions.compactMap { region -> RegionLatencyCandidates? in
            let endpoints = region.servers.endpointsForLatencyMeasurement(using: transport)
            guard let primaryEndpoint = endpoints.first else {
                return nil
            }

            return RegionLatencyCandidates(
                regionID: region.selectionID,
                primaryIP: primaryEndpoint.ip,
                refinementIPs: Array(endpoints.dropFirst()).map(\.ip)
            )
        }

        guard !candidatesByRegion.isEmpty else {
            return [:]
        }

        let primaryCandidates = candidatesByRegion.map { ($0.regionID, $0.primaryIP) }
        var latencies = await measureCandidateLatencies(primaryCandidates)

        guard refinementCandidateCount > 0, !latencies.isEmpty else {
            return latencies
        }

        let refinementRegionIDs = Set(
            latencies
                .sorted(by: { $0.value < $1.value })
                .prefix(refinementCandidateCount)
                .map(\.key)
        )

        let refinementCandidates = candidatesByRegion.flatMap { candidate -> [(String, String)] in
            guard refinementRegionIDs.contains(candidate.regionID) else {
                return []
            }
            return candidate.refinementIPs.map { (candidate.regionID, $0) }
        }

        guard !refinementCandidates.isEmpty else {
            return latencies
        }

        let refinedLatencies = await measureCandidateLatencies(refinementCandidates)
        for (regionID, latency) in refinedLatencies {
            latencies[regionID] = min(latencies[regionID] ?? latency, latency)
        }

        return latencies
    }

    private func measureCandidateLatencies(_ candidates: [(String, String)]) async -> [String: Double] {
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
                    batchResults[result.0] = min(batchResults[result.0] ?? latency, latency)
                }

                return batchResults
            }

            for (regionID, latency) in batchLatencies {
                latencies[regionID] = min(latencies[regionID] ?? latency, latency)
            }
        }

        return latencies
    }
}

private struct RegionLatencyCandidates {
    let regionID: String
    let primaryIP: String
    let refinementIPs: [String]
}

private extension PIARegionServers {
    func endpointsForLatencyMeasurement(using transport: VPNTransport) -> [PIAServerEndpoint] {
        let transportEndpoints: [PIAServerEndpoint]
        switch transport {
        case .wireGuard:
            transportEndpoints = wg
        case .openVPNUDP:
            transportEndpoints = ovpnudp
        case .openVPNTCP:
            transportEndpoints = ovpntcp
        }

        if !transportEndpoints.isEmpty {
            return transportEndpoints
        }

        if !meta.isEmpty {
            return meta
        }

        return []
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
