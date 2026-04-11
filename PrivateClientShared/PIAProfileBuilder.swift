import Foundation
import Network
import Partout

struct BuiltConnectionProfile {
    let profile: Profile
    let wireGuardPrivateKey: String?
}

struct PIAProfileBuilder {
    let certificatePEM: String

    func buildProfile(
        selection: ConnectionSelection,
        token: String,
        handshake: PIAWireGuardHandshake?,
        wireGuardPrivateKey: String?
    ) throws -> BuiltConnectionProfile {
        var profile = Profile.Builder(
            id: profileID(for: selection),
            name: profileName(for: selection)
        )

        let connectionModuleResult = try buildConnectionModule(
            selection: selection,
            token: token,
            handshake: handshake,
            wireGuardPrivateKey: wireGuardPrivateKey
        )
        profile.modules.append(connectionModuleResult.module)

        var dnsModule = DNSModule.Builder()
        dnsModule.servers = dnsServers(for: selection, handshake: handshake)
        dnsModule.routesThroughVPN = true
        profile.modules.append(try dnsModule.build())

        var ipModule = IPModule.Builder()
        ipModule.ipv4 = IPSettings(subnet: nil)
            .including(routes: [.init(defaultWithGateway: nil)])
        profile.modules.append(ipModule.build())

        profile.activeModulesIds = Set(profile.modules.map(\.id))
        return BuiltConnectionProfile(
            profile: try profile.build(),
            wireGuardPrivateKey: connectionModuleResult.wireGuardPrivateKey
        )
    }

    func openVPNCredentials(for token: String) -> OpenVPN.Credentials {
        let pivot = min(62, token.count)
        let username = String(token.prefix(pivot))
        let password = String(token.dropFirst(pivot))
        return OpenVPN.Credentials.Builder(username: username, password: password).build()
    }
}

extension PIAProfileBuilder {
    struct ConnectionModuleResult {
        let module: Module
        let wireGuardPrivateKey: String?
    }

    func buildConnectionModule(
        selection: ConnectionSelection,
        token: String,
        handshake: PIAWireGuardHandshake?,
        wireGuardPrivateKey: String?
    ) throws -> ConnectionModuleResult {
        switch selection.transport {
        case .wireGuard:
            guard let handshake else {
                throw PIAProfileBuilderError.missingWireGuardHandshake
            }
            guard let wireGuardPrivateKey else {
                throw PIAProfileBuilderError.missingWireGuardHandshake
            }

            var local = WireGuard.LocalInterface.Builder(privateKey: wireGuardPrivateKey)
            local.addresses = [handshake.peerIP]
            local.dns.servers = dnsServers(for: selection, handshake: handshake)

            let endpoint = selection.region.servers.endpoint(for: .wireGuard)
            var remote = WireGuard.RemoteInterface.Builder(publicKey: handshake.serverKey)
            remote.endpoint = "\(endpoint?.ip ?? ""):\(handshake.serverPort)"
            remote.allowedIPs = ["0.0.0.0/0"]
            remote.keepAlive = 25

            let configuration = WireGuard.Configuration.Builder(interface: local, peers: [remote])
            let module = try WireGuardModule.Builder(configurationBuilder: configuration).build()
            return ConnectionModuleResult(module: module, wireGuardPrivateKey: wireGuardPrivateKey)

        case .openVPNUDP, .openVPNTCP:
            let server = selection.region.servers.endpoint(for: selection.transport)
            guard let server, let port = selection.transport.openVPNPort else {
                throw PIAProfileBuilderError.missingServer
            }

            let config = OpenVPNConfigurationTemplate.build(
                serverIP: server.ip,
                serverHostname: server.cn,
                port: port,
                transport: selection.transport,
                certificatePEM: certificatePEM
            )
            let parser = StandardOpenVPNParser()
            let parsed = try parser.parsed(fromContents: config)
            var module = OpenVPNModule.Builder(configurationBuilder: parsed.configuration.builder())
            module.credentials = openVPNCredentials(for: token)
            module.configurationBuilder?.usesPIAPatches = true
            return ConnectionModuleResult(module: try module.build(), wireGuardPrivateKey: nil)
        }
    }

    func dnsServers(
        for selection: ConnectionSelection,
        handshake: PIAWireGuardHandshake?
    ) -> [String] {
        if let handshake {
            let numericHandshakeServers = handshake.dnsServers.filter(\.isNumericIPAddress)
            if !numericHandshakeServers.isEmpty {
                return numericHandshakeServers
            }
        }
        if let dns = selection.region.dns, dns.isNumericIPAddress {
            return [dns]
        }
        return ["10.0.0.243"]
    }

    func profileName(for selection: ConnectionSelection) -> String {
        "\(PrivateClientConfiguration.appDisplayName): \(selection.region.name) \(selection.transport.displayName)"
    }

    func profileID(for _: ConnectionSelection) -> UUID {
        return PrivateClientConfiguration.tunnelProfileIdentifier
    }
}

private extension String {
    var isNumericIPAddress: Bool {
        !isEmpty && IPv4Address(self) != nil
    }
}

enum PIAProfileBuilderError: LocalizedError {
    case missingWireGuardHandshake
    case missingServer

    var errorDescription: String? {
        switch self {
        case .missingWireGuardHandshake:
            return "WireGuard setup data is missing."
        case .missingServer:
            return "The selected server does not support that protocol."
        }
    }
}

enum PIAPrivateKeyGenerator {
    private static let generator = StandardWireGuardKeyGenerator()

    static func privateKey() throws -> String {
        try generator.privateKey(from: generator.newPrivateKey())
    }

    static func publicKey(for privateKey: String) throws -> String {
        try generator.publicKey(for: privateKey)
    }
}

private enum OpenVPNConfigurationTemplate {
    static func build(
        serverIP: String,
        serverHostname: String,
        port: UInt16,
        transport: VPNTransport,
        certificatePEM: String
    ) -> String {
        let proto: String
        switch transport {
        case .wireGuard:
            proto = "udp"
        case .openVPNUDP:
            proto = "udp"
        case .openVPNTCP:
            proto = "tcp"
        }

        return """
client
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
cipher aes-256-cbc
auth sha256
tls-client
remote-cert-tls server
auth-user-pass
compress
verb 1
reneg-sec 0
disable-occ
remote \(serverIP) \(port) \(proto)
verify-x509-name \(serverHostname) name
<ca>
\(certificatePEM.trimmingCharacters(in: .whitespacesAndNewlines))
</ca>
"""
    }
}
