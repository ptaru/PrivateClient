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

    var selectionID: String {
        [
            id,
            name,
            country,
            dns ?? ""
        ].joined(separator: "::")
    }

    var displayName: String {
        guard !name.localizedCaseInsensitiveContains("Streaming") else {
            return name
        }

        let components = name.components(separatedBy: " ")
        if components.count > 1,
           let first = components.first,
           first.count == 2,
           first == first.uppercased(),
           first.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil {
            return components.dropFirst().joined(separator: " ")
        }
        return name
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

struct PIAPortForwardSignatureResponse: Codable, Equatable, Sendable {
    let status: String
    let payload: String?
    let signature: String?
    let message: String?
}

struct PIAPortForwardPayload: Codable, Equatable, Sendable {
    let token: String?
    let port: UInt16
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case token
        case port
        case expiresAt = "expires_at"
    }

    static func decodeBase64Payload(_ payload: String) throws -> PIAPortForwardPayload {
        guard let payloadData = Data(base64Encoded: payload) else {
            throw PIAAPIError.portForwardingInvalidPayload
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawDate = try container.decode(String.self)
            if let parsed = Self.iso8601WithFractionalSeconds.date(from: rawDate)
                ?? Self.iso8601.date(from: rawDate) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid expires_at date: \(rawDate)"
            )
        }

        do {
            return try decoder.decode(PIAPortForwardPayload.self, from: payloadData)
        } catch {
            throw PIAAPIError.portForwardingInvalidPayload
        }
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct PIAPortBindResponse: Codable, Equatable, Sendable {
    let status: String
    let message: String?
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
