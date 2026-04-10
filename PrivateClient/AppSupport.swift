import Foundation
import Partout

extension Registry {
    static let shared = Registry(withKnown: true)
}

extension PrivateClientConfiguration {
    static var neProtocolCoder: ProviderNEProtocolCoder {
        ProviderNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: tunnelBundleIdentifier,
            coder: CodingRegistry(registry: .shared, withLegacyEncoding: { false })
        )
    }
}

extension TunnelObservable {
    static let sharedStrategy = NETunnelStrategy(
        .global,
        bundleIdentifier: PrivateClientConfiguration.tunnelBundleIdentifier,
        coder: PrivateClientConfiguration.neProtocolCoder
    )

    static let shared: TunnelObservable = {
        let tunnel = Tunnel(.global, strategy: sharedStrategy) {
            NETunnelEnvironment(strategy: sharedStrategy, profileId: $0)
        }
        return TunnelObservable(tunnel: tunnel)
    }()
}
