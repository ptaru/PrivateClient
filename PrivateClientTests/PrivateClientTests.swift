import XCTest
@testable import PrivateClient

final class PrivateClientTests: XCTestCase {
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
