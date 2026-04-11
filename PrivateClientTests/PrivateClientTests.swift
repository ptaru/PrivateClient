import XCTest
@testable import PrivateClient

final class PrivateClientTests: XCTestCase {
    func testLatencyAutoSelectorPrefersLowestMeasuredLatency() async {
        let fastestRegion = PIARegion(
            id: "uk_london",
            name: "UK London",
            country: "GB",
            autoRegion: nil,
            dns: "10.0.0.243",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: .init(
                meta: [],
                ovpntcp: [],
                ovpnudp: [],
                wg: [.init(ip: "1.1.1.1", cn: "uk-wg", van: nil)]
            )
        )
        let slowerRegion = PIARegion(
            id: "us_new_york",
            name: "US New York",
            country: "US",
            autoRegion: nil,
            dns: "10.0.0.242",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: .init(
                meta: [],
                ovpntcp: [],
                ovpnudp: [],
                wg: [.init(ip: "2.2.2.2", cn: "us-wg", van: nil)]
            )
        )

        let selector = LatencyBasedRegionAutoSelector(
            latencyMeasurer: StubLatencyMeasurer(latenciesByIP: [
                "1.1.1.1": 14.2,
                "2.2.2.2": 88.7
            ])
        )

        let selection = await selector.selectRegionID(
            from: [slowerRegion, fastestRegion],
            transport: .wireGuard
        )

        XCTAssertEqual(selection, fastestRegion.selectionID)
    }

    func testLatencyAutoSelectorIgnoresRegionsWithoutUsableLatency() async {
        let reachableRegion = PIARegion(
            id: "uk_london",
            name: "UK London",
            country: "GB",
            autoRegion: nil,
            dns: "10.0.0.243",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: .init(
                meta: [],
                ovpntcp: [],
                ovpnudp: [.init(ip: "3.3.3.3", cn: "uk-udp", van: nil)],
                wg: []
            )
        )
        let unreachableRegion = PIARegion(
            id: "us_new_york",
            name: "US New York",
            country: "US",
            autoRegion: nil,
            dns: "10.0.0.242",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: .init(
                meta: [],
                ovpntcp: [],
                ovpnudp: [.init(ip: "4.4.4.4", cn: "us-udp", van: nil)],
                wg: []
            )
        )

        let selector = LatencyBasedRegionAutoSelector(
            latencyMeasurer: StubLatencyMeasurer(latenciesByIP: [
                "3.3.3.3": 22.4
            ])
        )

        let selection = await selector.selectRegionID(
            from: [unreachableRegion, reachableRegion],
            transport: .openVPNUDP
        )

        XCTAssertEqual(selection, reachableRegion.selectionID)
    }

    func testLatencyAutoSelectorPrefersMetaEndpointWhenAvailable() async {
        let tracker = EndpointSelectionTracker()
        let selector = LatencyBasedRegionAutoSelector(
            latencyMeasurer: TrackingLatencyMeasurer(
                tracker: MeasurementConcurrencyTracker(),
                endpointTracker: tracker
            )
        )

        let region = PIARegion(
            id: "uk_london",
            name: "UK London",
            country: "GB",
            autoRegion: nil,
            dns: "10.0.0.243",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: .init(
                meta: [.init(ip: "9.9.9.9", cn: "uk-meta", van: nil)],
                ovpntcp: [],
                ovpnudp: [],
                wg: [.init(ip: "1.1.1.1", cn: "uk-wg", van: nil)]
            )
        )

        _ = await selector.measureLatencies(from: [region], transport: .wireGuard)

        let lastIPAddress = await tracker.lastIPAddress()
        XCTAssertEqual(lastIPAddress, "9.9.9.9")
    }

    func testLatencyAutoSelectorLimitsConcurrentMeasurements() async {
        let tracker = MeasurementConcurrencyTracker()
        let selector = LatencyBasedRegionAutoSelector(
            latencyMeasurer: TrackingLatencyMeasurer(tracker: tracker),
            maxConcurrentMeasurements: 2
        )

        let regions = [
            makeLatencyTestRegion(id: "uk_london", name: "UK London", ip: "1.1.1.1"),
            makeLatencyTestRegion(id: "us_new_york", name: "US New York", ip: "2.2.2.2"),
            makeLatencyTestRegion(id: "de_berlin", name: "DE Berlin", ip: "3.3.3.3"),
            makeLatencyTestRegion(id: "jp_tokyo", name: "JP Tokyo", ip: "4.4.4.4")
        ]

        let measured = await selector.measureLatencies(from: regions, transport: .wireGuard)

        XCTAssertEqual(measured.count, regions.count)
        let maxActiveCount = await tracker.maxActiveCount()
        XCTAssertLessThanOrEqual(maxActiveCount, 2)
    }

    func testServerListDecodingUsesFirstLine() throws {
        let payload = """
        {"groups":{},"regions":[{"id":"uk","name":"United Kingdom","country":"GB","auto_region":true,"dns":"uk.privacy.network","port_forward":true,"geo":false,"offline":false,"servers":{"meta":[{"ip":"1.1.1.1","cn":"uk-meta"}],"ovpntcp":[{"ip":"2.2.2.2","cn":"uk-tcp","van":true}],"ovpnudp":[{"ip":"3.3.3.3","cn":"uk-udp","van":true}],"wg":[{"ip":"4.4.4.4","cn":"uk-wg"}]}}]}
        SIGNATURE
        """
        let regions = try PIAAPIClient.parseServerListPayload(Data(payload.utf8))
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.id, "uk")
    }

    func testTransportEndpointMapping() {
        let endpoint = PIAServerEndpoint(ip: "4.4.4.4", cn: "wg", van: nil)
        let servers = PIARegionServers(
            meta: [],
            ovpntcp: [.init(ip: "2.2.2.2", cn: "tcp", van: true)],
            ovpnudp: [.init(ip: "3.3.3.3", cn: "udp", van: true)],
            wg: [endpoint]
        )
        XCTAssertEqual(servers.endpoint(for: .wireGuard)?.ip, "4.4.4.4")
        XCTAssertEqual(servers.endpoint(for: .openVPNUDP)?.ip, "3.3.3.3")
        XCTAssertEqual(servers.endpoint(for: .openVPNTCP)?.ip, "2.2.2.2")
    }

    func testTokenExpiry() {
        let expired = PIAAuthToken(token: "abc", expiresAt: .distantPast)
        let valid = PIAAuthToken(token: "abc", expiresAt: .distantFuture)
        XCTAssertTrue(expired.isExpired(referenceDate: Date()))
        XCTAssertFalse(valid.isExpired(referenceDate: Date()))
    }

    func testOpenVPNCredentialSplitting() {
        let builder = PIAProfileBuilder(certificatePEM: "CERT")
        let token = String(repeating: "a", count: 62) + "rest"
        let credentials = builder.openVPNCredentials(for: token)
        XCTAssertEqual(credentials.username, String(repeating: "a", count: 62))
        XCTAssertEqual(credentials.password, "rest")
    }

    func testWireGuardHandshakeDecoding() throws {
        let json = """
        {"status":"OK","server_key":"server-key","server_port":1337,"peer_ip":"10.0.0.2/32","dns_servers":["10.0.0.243"]}
        """
        let handshake = try JSONDecoder().decode(PIAWireGuardHandshake.self, from: Data(json.utf8))
        XCTAssertEqual(handshake.serverKey, "server-key")
        XCTAssertEqual(handshake.serverPort, 1337)
        XCTAssertEqual(handshake.peerIP, "10.0.0.2/32")
    }

    func testHostnameRegionDNSFallsBackToNumericResolver() {
        let builder = PIAProfileBuilder(certificatePEM: "CERT")
        let region = PIARegion(
            id: "uk_london",
            name: "UK London",
            country: "GB",
            autoRegion: nil,
            dns: "uk-london.pvt.site",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: PIARegionServers(meta: [], ovpntcp: [], ovpnudp: [], wg: [])
        )

        let servers = builder.dnsServers(
            for: ConnectionSelection(region: region, transport: .openVPNUDP),
            handshake: nil
        )

        XCTAssertEqual(servers, ["10.0.0.243"])
    }

    func testNumericHandshakeDNSIsPreferred() {
        let builder = PIAProfileBuilder(certificatePEM: "CERT")
        let region = PIARegion(
            id: "uk_london",
            name: "UK London",
            country: "GB",
            autoRegion: nil,
            dns: "uk-london.pvt.site",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: PIARegionServers(meta: [], ovpntcp: [], ovpnudp: [], wg: [])
        )
        let handshake = PIAWireGuardHandshake(
            status: "OK",
            serverKey: "server-key",
            serverPort: 1337,
            peerIP: "10.0.0.2/32",
            dnsServers: ["10.0.0.243", "resolver.example"]
        )

        let servers = builder.dnsServers(
            for: ConnectionSelection(region: region, transport: .wireGuard),
            handshake: handshake
        )

        XCTAssertEqual(servers, ["10.0.0.243"])
    }

    func testProfileIDIsStableAcrossSelections() {
        let builder = PIAProfileBuilder(certificatePEM: "CERT")
        let servers = PIARegionServers(
            meta: [],
            ovpntcp: [.init(ip: "2.2.2.2", cn: "tcp", van: true)],
            ovpnudp: [.init(ip: "3.3.3.3", cn: "udp", van: true)],
            wg: [.init(ip: "4.4.4.4", cn: "wg", van: nil)]
        )
        let regionA = PIARegion(
            id: "uk_london",
            name: "UK London",
            country: "GB",
            autoRegion: nil,
            dns: "10.0.0.243",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: servers
        )
        let regionB = PIARegion(
            id: "us_newyork",
            name: "US New York",
            country: "US",
            autoRegion: nil,
            dns: "10.0.0.242",
            portForward: nil,
            geo: nil,
            offline: nil,
            servers: servers
        )

        let idA = builder.profileID(for: .init(region: regionA, transport: .wireGuard))
        let idB = builder.profileID(for: .init(region: regionB, transport: .openVPNTCP))

        XCTAssertEqual(idA, idB)
        XCTAssertEqual(idA, PrivateClientConfiguration.tunnelProfileIdentifier)
    }
}

private struct StubLatencyMeasurer: EndpointLatencyMeasuring {
    let latenciesByIP: [String: Double]

    func measureLatency(to ipAddress: String, timeoutMilliseconds: Int) async -> Double? {
        latenciesByIP[ipAddress]
    }
}

private struct TrackingLatencyMeasurer: EndpointLatencyMeasuring {
    let tracker: MeasurementConcurrencyTracker
    var endpointTracker: EndpointSelectionTracker?

    func measureLatency(to ipAddress: String, timeoutMilliseconds: Int) async -> Double? {
        await endpointTracker?.record(ipAddress: ipAddress)
        await tracker.measurementStarted()
        try? await Task.sleep(for: .milliseconds(50))
        await tracker.measurementFinished()
        return Double(ipAddress.split(separator: ".").first ?? "0")
    }
}

private actor MeasurementConcurrencyTracker {
    private var activeCount = 0
    private var peakActiveCount = 0

    func measurementStarted() {
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func measurementFinished() {
        activeCount -= 1
    }

    func maxActiveCount() -> Int {
        peakActiveCount
    }
}

private actor EndpointSelectionTracker {
    private var ipAddress: String?

    func record(ipAddress: String) {
        self.ipAddress = ipAddress
    }

    func lastIPAddress() -> String? {
        ipAddress
    }
}

private func makeLatencyTestRegion(id: String, name: String, ip: String) -> PIARegion {
    PIARegion(
        id: id,
        name: name,
        country: String(id.prefix(2)).uppercased(),
        autoRegion: nil,
        dns: "10.0.0.243",
        portForward: nil,
        geo: nil,
        offline: nil,
        servers: .init(
            meta: [.init(ip: ip, cn: "\(id)-meta", van: nil)],
            ovpntcp: [],
            ovpnudp: [],
            wg: [.init(ip: ip, cn: "\(id)-wg", van: nil)]
        )
    )
}
