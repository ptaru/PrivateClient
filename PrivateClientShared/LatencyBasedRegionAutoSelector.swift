import Foundation

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
        latencyMeasurer: EndpointLatencyMeasuring = ICMPPingLatencyMeasurer(),
        timeoutMilliseconds: Int = 1000,
        maxConcurrentMeasurements: Int = 256
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

struct ICMPPingLatencyMeasurer: EndpointLatencyMeasuring {
    func measureLatency(to ipAddress: String, timeoutMilliseconds: Int) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let latency = measureLatencySynchronously(
                    to: ipAddress,
                    timeoutMilliseconds: timeoutMilliseconds
                )
                continuation.resume(returning: latency)
            }
        }
    }

    private func measureLatencySynchronously(to ipAddress: String, timeoutMilliseconds: Int) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = [
            "-c", "1",
            "-n",
            "-q",
            "-W", String(timeoutMilliseconds),
            ipAddress
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return Self.parseLatency(from: output + "\n" + errorOutput)
    }

    static func parseLatency(from output: String) -> Double? {
        let patterns = [
            #"time=([0-9]+(?:\.[0-9]+)?)"#,
            #"min/avg/max(?:/stddev)? = [0-9]+(?:\.[0-9]+)?/([0-9]+(?:\.[0-9]+)?)/"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            guard let match = regex.firstMatch(in: output, range: range),
                  match.numberOfRanges > 1,
                  let latencyRange = Range(match.range(at: 1), in: output) else {
                continue
            }

            return Double(output[latencyRange])
        }

        return nil
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
