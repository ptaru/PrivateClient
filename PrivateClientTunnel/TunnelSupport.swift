import Foundation
import Partout

extension Registry {
    static let shared = Registry(
        withKnown: true,
        allImplementations: [
            OpenVPNModule.Implementation(
                importerBlock: {
                    StandardOpenVPNParser()
                },
                connectionBlock: {
                    let context = PartoutLoggerContext($0.profile.id)
                    return try OpenVPNConnection(
                        context,
                        parameters: $0,
                        module: $1,
                        cachesURL: PrivateClientConfiguration.moduleURL(for: "OpenVPN")
                    )
                }
            ),
            WireGuardModule.Implementation(
                keyGenerator: StandardWireGuardKeyGenerator(),
                importerBlock: {
                    StandardWireGuardParser()
                },
                validatorBlock: {
                    StandardWireGuardParser()
                },
                connectionBlock: {
                    let context = PartoutLoggerContext($0.profile.id)
                    return try WireGuardConnection(
                        context,
                        parameters: $0,
                        module: $1
                    )
                }
            )
        ]
    )
}

extension NEProtocolDecoder where Self == ProviderNEProtocolCoder {
    static var shared: Self {
        ProviderNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: PrivateClientConfiguration.tunnelBundleIdentifier,
            coder: CodingRegistry(registry: .shared, withLegacyEncoding: { false })
        )
    }
}
