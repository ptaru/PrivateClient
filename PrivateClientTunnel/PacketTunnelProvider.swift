@preconcurrency import NetworkExtension
import Partout

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var forwarder: NEPTPForwarder?

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        do {
            let profile = try Profile(withNEProvider: self, decoder: .shared)
            let controller = NETunnelController(
                provider: self,
                profile: profile,
                options: .init()
            )

            var logger = PartoutLogger.Builder()
            logger.setDestination(OSLogDestination(.core), for: [.core])
            logger.setDestination(OSLogDestination(.openvpn), for: [.openvpn])
            logger.setDestination(OSLogDestination(.wireguard), for: [.wireguard])
            logger.logsModules = true
            logger.setLocalLogger(
                url: PrivateClientConfiguration.tunnelLogURL,
                options: .init(
                    maxLevel: PrivateClientConfiguration.Log.maxLevel,
                    maxSize: PrivateClientConfiguration.Log.maxSize,
                    maxBufferedLines: PrivateClientConfiguration.Log.maxBufferedLines
                ),
                mapper: PrivateClientConfiguration.Log.formattedLine
            )
            PartoutLogger.register(logger.build())

            let context = PartoutLoggerContext(profile.id)
            forwarder = try NEPTPForwarder(
                context,
                profile: profile,
                connectionFactory: Registry.shared,
                controller: controller,
                environment: UserDefaultsEnvironment(
                    profileId: nil,
                    defaults: UserDefaults(suiteName: PrivateClientConfiguration.appGroupIdentifier)
                        ?? .standard
                )
            )
            try await forwarder?.startTunnel(options: options ?? [:])
        } catch {
            flushLog()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await forwarder?.stopTunnel(with: reason)
        forwarder = nil
        flushLog()
    }

    override func cancelTunnelWithError(_ error: Error?) {
        flushLog()
        super.cancelTunnelWithError(error)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        await forwarder?.handleAppMessage(messageData)
    }

    override func wake() {
        forwarder?.wake()
    }

    override func sleep() async {
        await forwarder?.sleep()
    }
}

private extension PacketTunnelProvider {
    func flushLog() {
        PartoutLogger.default.flushLog()
        Task {
            try? await Task.sleep(milliseconds: Int(PrivateClientConfiguration.Log.saveInterval))
            flushLog()
        }
    }
}
