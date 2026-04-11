import Foundation
import NetworkExtension
import Observation
import Partout

@MainActor
@Observable
final class AppModel {
    var username = ""
    var password = ""
    var searchText = ""
    var regions: [PIARegion] = []
    var selectedRegionID: String?
    var selectedTransport: VPNTransport = .wireGuard
    var sessionStatus: SessionStatus = .signedOut
    var errorMessage: String?
    var logLines: [String] = []
    var currentProfileID: Profile.ID?
    var isBootstrapped = false
    var isSignedIn = false

    private let apiClient: PIAAPIClientProtocol
    private let credentialStore: PIACredentialStore
    private let profileBuilder: PIAProfileBuilder

    init(
        apiClient: PIAAPIClientProtocol = PIAAPIClient(),
        credentialStore: PIACredentialStore = KeychainPIACredentialStore(),
        profileBuilder: PIAProfileBuilder? = nil
    ) {
        self.apiClient = apiClient
        self.credentialStore = credentialStore
        let certificate = (try? String(contentsOf: Self.certificateURL, encoding: .utf8)) ?? ""
        self.profileBuilder = profileBuilder ?? PIAProfileBuilder(certificatePEM: certificate)

        Task {
            await bootstrap()
        }
    }

    var selectedRegion: PIARegion? {
        guard let selectedRegionID else {
            return filteredRegions.first
        }
        return regions.first(where: { $0.id == selectedRegionID })
    }

    var filteredRegions: [PIARegion] {
        guard !searchText.isEmpty else {
            return regions
        }
        return regions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.country.localizedCaseInsensitiveContains(searchText)
            || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var canSignIn: Bool {
        !username.isEmpty && !password.isEmpty
    }

    var canConnect: Bool {
        selectedRegion != nil && isSignedIn && !isBusy
    }

    var isAuthenticated: Bool {
        isSignedIn
    }

    var isBusy: Bool {
        switch sessionStatus {
        case .signingIn, .loadingServers, .connecting, .disconnecting:
            return true
        case .signedOut, .ready, .connected, .failed:
            return false
        }
    }

    func bootstrap() async {
        guard !isBootstrapped else {
            return
        }
        defer { isBootstrapped = true }

        do {
            if let credentials = try credentialStore.loadCredentials() {
                username = credentials.username
                password = credentials.password
                isSignedIn = true
                sessionStatus = .loadingServers
                try await loadRegions()
                sessionStatus = .ready
                appendLog("Restored saved credentials for \(credentials.username).")
            } else {
                sessionStatus = .signedOut
            }
        } catch {
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Bootstrap failed: \(message)")
        }
    }

    func signIn() async {
        guard canSignIn else {
            return
        }

        sessionStatus = .signingIn
        errorMessage = nil
        appendLog("Signing in as \(username).")

        do {
            let token = try await apiClient.authenticate(username: username, password: password)
            try credentialStore.saveCredentials(.init(username: username, password: password))
            try credentialStore.saveToken(token)
            try await loadRegions()
            isSignedIn = true
            sessionStatus = .ready
            appendLog("Signed in and fetched \(regions.count) regions.")
        } catch {
            isSignedIn = false
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Sign-in failed: \(message)")
        }
    }

    func signOut(using tunnel: TunnelObservable) async {
        if let currentProfileID {
            do {
                try await tunnel.disconnect(from: currentProfileID)
            } catch {
                appendLog("Disconnect during sign-out failed: \(error.localizedDescription)")
            }
        }

        do {
            try credentialStore.deleteCredentials()
            try credentialStore.deleteToken()
        } catch {
            appendLog("Keychain cleanup failed: \(error.localizedDescription)")
        }

        currentProfileID = nil
        regions = []
        selectedRegionID = nil
        errorMessage = nil
        logLines = []
        isSignedIn = false
        sessionStatus = .signedOut
    }

    func refreshRegions() async {
        guard isAuthenticated else {
            return
        }
        sessionStatus = .loadingServers
        errorMessage = nil

        do {
            try await loadRegions()
            sessionStatus = .ready
            appendLog("Refreshed server list.")
        } catch {
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Region refresh failed: \(message)")
        }
    }

    func connect(using tunnel: TunnelObservable) async {
        guard let region = selectedRegion else {
            errorMessage = "Select a server region first."
            return
        }

        sessionStatus = .connecting
        errorMessage = nil
        let selection = ConnectionSelection(region: region, transport: selectedTransport)

        do {
            let targetProfileID = profileBuilder.profileID(for: selection)
            try await cleanupStaleTunnelProfiles(keeping: targetProfileID)
            let token = try await validToken()
            let handshake: PIAWireGuardHandshake?
            switch selectedTransport {
            case .wireGuard:
                let endpoint = try requiredEndpoint(for: selection)
                let privateKey = try PIAPrivateKeyGenerator.privateKey()
                handshake = try await PIAWireGuardAuthenticator(
                    apiClient: apiClient,
                    certificatePEM: profileBuilder.certificatePEM
                ).handshake(
                    token: token.token,
                    server: endpoint,
                    privateKey: privateKey
                )
                let builtProfile = try profileBuilder.buildProfile(
                    selection: selection,
                    token: token.token,
                    handshake: handshake,
                    wireGuardPrivateKey: privateKey
                )
                try await connectWithAuthorizationRetry(
                    profile: builtProfile.profile,
                    using: tunnel
                )
                currentProfileID = builtProfile.profile.id
            case .openVPNUDP, .openVPNTCP:
                handshake = nil
                let builtProfile = try profileBuilder.buildProfile(
                    selection: selection,
                    token: token.token,
                    handshake: nil,
                    wireGuardPrivateKey: nil
                )
                try await connectWithAuthorizationRetry(
                    profile: builtProfile.profile,
                    using: tunnel
                )
                currentProfileID = builtProfile.profile.id
            }

            sessionStatus = .connected
            appendLog("Connected to \(region.name) using \(selectedTransport.displayName).")
            await refreshLog(using: tunnel)
        } catch {
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Connect failed: \(message)")
        }
    }

    func disconnect(using tunnel: TunnelObservable) async {
        guard let currentProfileID else {
            return
        }

        sessionStatus = .disconnecting
        errorMessage = nil

        do {
            try await tunnel.disconnect(from: currentProfileID)
            self.currentProfileID = nil
            sessionStatus = .ready
            appendLog("Disconnected from VPN.")
            await refreshLog(using: tunnel)
        } catch {
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Disconnect failed: \(message)")
        }
    }

    func synchronize(with tunnel: TunnelObservable) async {
        switch tunnel.status {
        case .inactive:
            currentProfileID = nil
            if isAuthenticated, !isBusy, sessionStatus != .ready {
                sessionStatus = .ready
            }
        case .activating:
            if sessionStatus != .connecting {
                sessionStatus = .connecting
            }
        case .deactivating:
            if sessionStatus != .disconnecting {
                sessionStatus = .disconnecting
            }
        case .active:
            if sessionStatus != .connected {
                sessionStatus = .connected
            }
        }

        await refreshLog(using: tunnel)
    }

    func appendLog(_ line: String) {
        let timestamp = Date().formatted(.dateTime.hour().minute().second())
        logLines.insert("[\(timestamp)] \(line)", at: 0)
        logLines = Array(logLines.prefix(200))
    }
}

private extension Error {
    var presentableDescription: String {
        if let error = self as? PartoutError {
            return error.debugDescription
        }

        let nsError = self as NSError
        if nsError.domain == NEVPNErrorDomain {
            return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        }

        return localizedDescription
    }

    var isRecoverableFirstAuthorizationFailure: Bool {
        let nsError = self as NSError
        guard nsError.domain == NEVPNErrorDomain else {
            return false
        }
        return nsError.code == NEVPNError.configurationInvalid.rawValue
            || nsError.code == NEVPNError.configurationStale.rawValue
            || nsError.code == NEVPNError.configurationReadWriteFailed.rawValue
    }
}

private extension AppModel {
    static var certificateURL: URL {
        Bundle.main.url(forResource: "ca.rsa.4096", withExtension: "crt")!
    }

    func loadRegions() async throws {
        let regions = try await apiClient.fetchRegions()
        self.regions = regions.filter { $0.offline != true }
        if selectedRegionID == nil {
            selectedRegionID = self.regions.first?.id
        } else if self.regions.contains(where: { $0.id == selectedRegionID }) == false {
            selectedRegionID = self.regions.first?.id
        }
    }

    func validToken() async throws -> PIAAuthToken {
        if let existingToken = try credentialStore.loadToken(), !existingToken.isExpired {
            return existingToken
        }

        let token = try await apiClient.authenticate(username: username, password: password)
        try credentialStore.saveToken(token)
        appendLog("Refreshed the PIA access token.")
        return token
    }

    func refreshLog(using tunnel: TunnelObservable) async {
        guard let currentProfileID else {
            if let content = try? String(
                contentsOf: PrivateClientConfiguration.tunnelLogURL,
                encoding: .utf8
            ) {
                let externalLines = content
                    .split(separator: "\n")
                    .map(String.init)
                    .suffix(100)
                if !externalLines.isEmpty {
                    logLines = Array(externalLines.reversed())
                }
            }
            return
        }

        guard tunnel.status != .inactive else {
            return
        }

        do {
            guard let output = try await tunnel.sendMessage(
                .debugLog(sinceLast: 24 * 60 * 60, maxLevel: PrivateClientConfiguration.Log.maxLevel),
                to: currentProfileID
            ) else {
                return
            }
            guard case .debugLog(let log) = output else {
                return
            }
            logLines = Array(log.lines.map(PrivateClientConfiguration.Log.formattedLine).reversed())
        } catch {
            appendLog("Tunnel log fetch failed: \(error.localizedDescription)")
        }
    }

    func requiredEndpoint(for selection: ConnectionSelection) throws -> PIAServerEndpoint {
        guard let endpoint = selection.region.servers.endpoint(for: selection.transport) else {
            throw PIAProfileBuilderError.missingServer
        }
        return endpoint
    }

    func connectWithAuthorizationRetry(
        profile: Profile,
        using tunnel: TunnelObservable
    ) async throws {
        let title: @Sendable (Profile) -> String = {
            "\(PrivateClientConfiguration.appDisplayName): \($0.name)"
        }

        do {
            try await tunnel.connect(to: profile, title: title)
        } catch {
            guard error.isRecoverableFirstAuthorizationFailure else {
                throw error
            }
            appendLog("VPN permission changed. Waiting for system configuration to settle...")
            try await Task.sleep(for: .milliseconds(1200))
            try await tunnel.connect(to: profile, title: title)
        }
    }

    func cleanupStaleTunnelProfiles(keeping targetProfileID: Profile.ID? = nil) async throws {
        let strategy = TunnelObservable.sharedStrategy
        let managers = try await strategy.fetch()

        for manager in managers {
            let profile: Profile
            do {
                profile = try strategy.profile(from: manager)
            } catch {
                continue
            }

            guard profile.name.hasPrefix("\(PrivateClientConfiguration.appDisplayName): ") else {
                continue
            }
            guard profile.id != targetProfileID else {
                continue
            }

            try await strategy.uninstall(profileId: profile.id)
        }
    }
}

private struct PIAWireGuardAuthenticator {
    let apiClient: PIAAPIClientProtocol
    let certificatePEM: String

    func handshake(
        token: String,
        server: PIAServerEndpoint,
        privateKey: String
    ) async throws -> PIAWireGuardHandshake {
        guard let client = apiClient as? PIAAPIClient else {
            return try await apiClient.exchangeWireGuardKey(
                token: token,
                server: server,
                certificatePEM: certificatePEM
            )
        }
        return try await client.exchangeWireGuardKey(
            token: token,
            server: server,
            certificatePEM: certificatePEM,
            publicKey: try PIAPrivateKeyGenerator.publicKey(for: privateKey)
        )
    }
}
