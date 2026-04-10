import Foundation

enum VPNTransport: String, CaseIterable, Codable, Identifiable, Sendable {
    case wireGuard
    case openVPNUDP
    case openVPNTCP

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .wireGuard:
            return "WireGuard"
        case .openVPNUDP:
            return "OpenVPN UDP"
        case .openVPNTCP:
            return "OpenVPN TCP"
        }
    }

    var openVPNPort: UInt16? {
        switch self {
        case .wireGuard:
            return nil
        case .openVPNUDP:
            return 8080
        case .openVPNTCP:
            return 8443
        }
    }
}

enum SessionStatus: Equatable, Sendable {
    case signedOut
    case signingIn
    case loadingServers
    case ready
    case connecting
    case connected
    case disconnecting
    case failed(String)

    var label: String {
        switch self {
        case .signedOut:
            return "Signed Out"
        case .signingIn:
            return "Signing In"
        case .loadingServers:
            return "Loading Servers"
        case .ready:
            return "Ready"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting"
        case .failed:
            return "Failed"
        }
    }
}

struct PIAServerEndpoint: Codable, Hashable, Sendable {
    let ip: String
    let cn: String
    let van: Bool?
}

struct PIARegionServers: Codable, Hashable, Sendable {
    let meta: [PIAServerEndpoint]
    let ovpntcp: [PIAServerEndpoint]
    let ovpnudp: [PIAServerEndpoint]
    let wg: [PIAServerEndpoint]

    func endpoint(for transport: VPNTransport) -> PIAServerEndpoint? {
        switch transport {
        case .wireGuard:
            return wg.first
        case .openVPNUDP:
            return ovpnudp.first
        case .openVPNTCP:
            return ovpntcp.first
        }
    }
}

struct PIARegion: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let country: String
    let autoRegion: Bool?
    let dns: String?
    let portForward: Bool?
    let geo: Bool?
    let offline: Bool?
    let servers: PIARegionServers

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case country
        case autoRegion = "auto_region"
        case dns
        case portForward = "port_forward"
        case geo
        case offline
        case servers
    }
}

struct PIAAuthToken: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt <= Date()
    }

    func isExpired(referenceDate: Date) -> Bool {
        expiresAt <= referenceDate
    }
}

struct PIAWireGuardHandshake: Codable, Equatable, Sendable {
    let status: String
    let serverKey: String
    let serverPort: UInt16
    let peerIP: String
    let dnsServers: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case serverKey = "server_key"
        case serverPort = "server_port"
        case peerIP = "peer_ip"
        case dnsServers = "dns_servers"
    }
}

struct ConnectionSelection: Equatable, Sendable {
    let region: PIARegion
    let transport: VPNTransport
}

struct PIARegionsEnvelope: Codable, Sendable {
    let groups: [String: [PIAGroup]]
    let regions: [PIARegion]
}

struct PIAGroup: Codable, Sendable {
    let name: String
    let ports: [UInt16]
}
