import Foundation
import NetworkExtension
import Observation
import Partout

@MainActor
@Observable
final class AppModel: NSObject {
    var username = ""
    var password = ""
    var searchText = ""
    var regions: [PIARegion] = []
    var selectedRegionID: String?
    var selectedTransport: VPNTransport = .wireGuard
    var sidebarSortMode: SidebarSortMode = .latency
    var regionLatenciesMs: [String: Double] = [:]
    var isLatencyRefreshInProgress = false
    var connectedRegionID: String?
    var connectedTransport: VPNTransport?
    var connectedSince: Date?
    var sessionStatus: SessionStatus = .signedOut
    var errorMessage: String?
    var logLines: [String] = []
    var currentProfileID: Profile.ID?
    var isBootstrapped = false
    var isSignedIn = false
    var isMainInterfaceReady = false
    var isExpectingDisconnect = false

    private let apiClient: PIAAPIClientProtocol
    private let credentialStore: PIACredentialStore
    private let profileBuilder: PIAProfileBuilder
    private let regionAutoSelector: RegionAutoSelecting
    private var regionLatenciesByTransport: [VPNTransport: [String: Double]] = [:]
    private var latencyRefreshTask: Task<Void, Never>?
    private var latencyRefreshGeneration = 0

    init(
        apiClient: PIAAPIClientProtocol = PIAAPIClient(),
        credentialStore: PIACredentialStore = KeychainPIACredentialStore(),
        profileBuilder: PIAProfileBuilder? = nil,
        regionAutoSelector: RegionAutoSelecting = LatencyBasedRegionAutoSelector()
    ) {
        self.apiClient = apiClient
        self.credentialStore = credentialStore
        let certificate = (try? String(contentsOf: Self.certificateURL, encoding: .utf8)) ?? ""
        self.profileBuilder = profileBuilder ?? PIAProfileBuilder(certificatePEM: certificate)
        self.regionAutoSelector = regionAutoSelector

        super.init()

        Task {
            await bootstrap()
        }
    }

    var selectedRegion: PIARegion? {
        guard let selectedRegionID else {
            return nil
        }
        return regions.first(where: { $0.selectionID == selectedRegionID })
    }

    var connectedRegion: PIARegion? {
        guard sessionStatus == .connected, let connectedRegionID else {
            return nil
        }
        return regions.first(where: { $0.selectionID == connectedRegionID })
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

    var connectionDurationLabel: String {
        connectionDurationLabel(referenceDate: Date())
    }

    func bootstrap() async {
        guard !isBootstrapped else {
            return
        }
        defer { isBootstrapped = true }
        isMainInterfaceReady = false

        do {
            if let credentials = try credentialStore.loadCredentials() {
                username = credentials.username
                password = credentials.password
                isSignedIn = true
                sessionStatus = .loadingServers
                try await loadRegions()
                sessionStatus = .ready
                isMainInterfaceReady = true
                appendLog("Restored saved credentials for \(credentials.username).")
            } else {
                sessionStatus = .signedOut
                isMainInterfaceReady = false
            }
        } catch {
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            isMainInterfaceReady = false
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
            isSignedIn = true
            isMainInterfaceReady = false
            sessionStatus = .loadingServers
            try await loadRegions()
            sessionStatus = .ready
            isMainInterfaceReady = true
            appendLog("Signed in and fetched \(regions.count) regions.")
        } catch {
            isSignedIn = false
            isMainInterfaceReady = false
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Sign-in failed: \(message)")
        }
    }

    func signOut(using tunnel: TunnelObservable) async {
        latencyRefreshTask?.cancel()
        latencyRefreshTask = nil
        isLatencyRefreshInProgress = false
        if let currentProfileID {
            isExpectingDisconnect = true
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
        connectedRegionID = nil
        connectedTransport = nil
        connectedSince = nil
        regions = []
        regionLatenciesMs = [:]
        regionLatenciesByTransport = [:]
        selectedRegionID = nil
        errorMessage = nil
        logLines = []
        isSignedIn = false
        isMainInterfaceReady = false
        sessionStatus = .signedOut
        isExpectingDisconnect = false
    }

    func refreshRegions() async {
        guard isAuthenticated else {
            return
        }
        let wasConnected = sessionStatus == .connected
        sessionStatus = wasConnected ? .connected : .loadingServers
        errorMessage = nil

        do {
            try await loadRegions()
            sessionStatus = wasConnected ? .connected : .ready
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

        if sessionStatus == .connected {
            appendLog("Switching servers. Disconnecting from current session…")
            isExpectingDisconnect = true
            await disconnect(using: tunnel)
            // Wait a moment for the system to settle
            try? await Task.sleep(for: .milliseconds(500))
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

            connectedRegionID = region.selectionID
            connectedTransport = selectedTransport
            connectedSince = Date()
            sessionStatus = .connected
            isExpectingDisconnect = false
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

        isExpectingDisconnect = true
        sessionStatus = .disconnecting
        errorMessage = nil

        do {
            try await tunnel.disconnect(from: currentProfileID)
            self.currentProfileID = nil
            connectedRegionID = nil
            connectedTransport = nil
            connectedSince = nil
            sessionStatus = .ready
            isExpectingDisconnect = false
            appendLog("Disconnected from VPN.")
            await refreshLog(using: tunnel)
        } catch {
            let message = error.presentableDescription
            sessionStatus = .failed(message)
            errorMessage = message
            appendLog("Disconnect failed: \(message)")
            isExpectingDisconnect = false
        }
    }

    func synchronize(with tunnel: TunnelObservable) async {
        switch tunnel.status {
        case .inactive:
            let previousStatus = sessionStatus
            currentProfileID = nil
            connectedRegionID = nil
            connectedTransport = nil
            connectedSince = nil
            if isAuthenticated, !isBusy {
                if !isExpectingDisconnect, previousStatus == .connected || previousStatus == .connecting {
                    let message = "VPN disconnected unexpectedly. Check extension permissions and Network Extension configuration."
                    sessionStatus = .failed(message)
                    errorMessage = message
                    appendLog(message)
                } else if sessionStatus != .ready {
                    sessionStatus = .ready
                }
            }
            isExpectingDisconnect = false
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
            if connectedSince == nil {
                connectedSince = Date()
            }
            isExpectingDisconnect = false
        }

        await refreshLog(using: tunnel)
    }

    func appendLog(_ line: String) {
        let timestamp = Date().formatted(.dateTime.hour().minute().second())
        logLines.insert("[\(timestamp)] \(line)", at: 0)
        logLines = Array(logLines.prefix(200))
    }

    func refreshLatencyMeasurements() {
        guard !regions.isEmpty else {
            latencyRefreshTask?.cancel()
            latencyRefreshTask = nil
            isLatencyRefreshInProgress = false
            regionLatenciesMs = [:]
            return
        }

        let transport = selectedTransport
        if let cached = cachedLatencies(for: transport, regions: regions), !cached.isEmpty {
            regionLatenciesMs = cached
        } else {
            regionLatenciesMs = [:]
        }

        startLatencyRefresh(
            for: transport,
            regionsSnapshot: regions,
            autoSelectIfCurrentSelection: nil,
            shouldAutoSelectWhenRefreshCompletes: false
        )
    }

    func latencyText(for region: PIARegion) -> String? {
        latencyText(for: region.selectionID)
    }

    func latencyText(for selectionID: String) -> String? {
        guard shouldDisplayLatencyMeasurements else {
            return nil
        }
        guard let latency = regionLatenciesMs[selectionID] else {
            return nil
        }
        return "\(Int(latency.rounded()))ms"
    }

    func latencyValue(for selectionID: String) -> Double? {
        guard shouldDisplayLatencyMeasurements else {
            return nil
        }
        return regionLatenciesMs[selectionID]
    }

    func awaitLatencyRefreshCompletion() async {
        if let task = latencyRefreshTask {
            await task.value
        }
    }

    func connectionDurationLabel(referenceDate: Date) -> String {
        guard let connectedSince else {
            return "00:00"
        }
        let elapsed = max(0, Int(referenceDate.timeIntervalSince(connectedSince)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func quickConnect(using tunnel: TunnelObservable) async {
        guard isAuthenticated else {
            errorMessage = "Sign in to connect."
            return
        }
        guard !isBusy else {
            return
        }
        guard !regions.isEmpty else {
            errorMessage = "No server regions available yet."
            return
        }

        if regionLatenciesMs.isEmpty {
            refreshLatencyMeasurements()
            await awaitLatencyRefreshCompletion()
        }

        if let fastestSelectionID = lowestLatencySelectionID() {
            if fastestSelectionID != selectedRegionID {
                selectedRegionID = fastestSelectionID
                if let region = selectedRegion {
                    appendLog("Quick Connect selected \(region.name) based on lowest latency.")
                }
            }
        } else if selectedRegionID == nil, let fallbackRegion = regions.first {
            selectedRegionID = fallbackRegion.selectionID
            appendLog("Quick Connect selected \(fallbackRegion.name) (latency unavailable).")
        }

        await connect(using: tunnel)
    }
}

enum SidebarSortMode: String, CaseIterable, Identifiable, Sendable {
    case latency
    case alphabetical

    var id: String {
        rawValue
    }
}

private extension Error {
    var presentableDescription: String {
        if let error = self as? PartoutError {
            return error.debugDescription
        }

        let nsError = self as NSError
        if nsError.domain == NEVPNErrorDomain {
            return "VPN configuration error (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription) \(nsError.recoveryHintText)"
        }

        if nsError.domain == "NEConfigurationErrorDomain" {
            return "Network Extension communication error (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription) \(nsError.recoveryHintText)"
        }

        if nsError.domain == NSURLErrorDomain {
            return "Network request failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription) \(nsError.recoveryHintText)"
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

private extension NSError {
    var recoveryHintText: String {
        if domain == NEVPNErrorDomain {
            if code == NEVPNError.configurationInvalid.rawValue
                || code == NEVPNError.configurationStale.rawValue
                || code == NEVPNError.configurationReadWriteFailed.rawValue {
                return "Try restarting the app. If it persists, remove stale PrivateClient VPN profiles in System Settings > VPN and reconnect."
            }
            if code == NEVPNError.configurationDisabled.rawValue {
                return "Enable the VPN configuration in System Settings > VPN and try again."
            }
            if code == NEVPNError.connectionFailed.rawValue {
                return "The tunnel extension could not establish a session. Check tunnel logs for protocol-level details."
            }
        }

        if domain == "NEConfigurationErrorDomain" && code == 11 {
            return "The Network Extension service connection is unavailable. Fully quit PrivateClient and relaunch."
        }

        if domain == NSURLErrorDomain {
            if code == NSURLErrorCannotFindHost {
                return "The API hostname could not be resolved. Check DNS/network connectivity."
            }
            if code == NSURLErrorSecureConnectionFailed || code == NSURLErrorServerCertificateUntrusted {
                return "TLS validation failed for the VPN endpoint. Verify endpoint host/certificate handling."
            }
            if code == NSURLErrorTimedOut {
                return "The request timed out. The endpoint may be overloaded; retry with another region."
            }
        }

        return ""
    }
}

private extension AppModel {
    var shouldDisplayLatencyMeasurements: Bool {
        !isLatencyRefreshInProgress
    }

    func lowestLatencySelectionID() -> String? {
        let validSelectionIDs = Set(regions.map(\.selectionID))
        return regionLatenciesMs
            .filter { validSelectionIDs.contains($0.key) }
            .min(by: { $0.value < $1.value })?
            .key
    }

    static var certificateURL: URL {
        Bundle.main.url(forResource: "ca.rsa.4096", withExtension: "crt")!
    }

    func loadRegions() async throws {
        let regions = try await apiClient.fetchRegions()
        self.regions = regions.filter { $0.offline != true }
        let transport = selectedTransport
        let cached = cachedLatencies(for: transport, regions: self.regions)
        regionLatenciesMs = cached ?? [:]

        let fallbackSelectionID: String?
        let shouldAutoSelectWhenRefreshCompletes: Bool
        if selectedRegionID == nil {
            fallbackSelectionID = nil
            shouldAutoSelectWhenRefreshCompletes = true
        } else if !self.regions.contains(where: { $0.selectionID == selectedRegionID }) {
            // Keep the connected region selection if it temporarily disappears from the list.
            if sessionStatus == .connected {
                fallbackSelectionID = selectedRegionID
                shouldAutoSelectWhenRefreshCompletes = false
            } else {
                selectedRegionID = nil
                fallbackSelectionID = nil
                shouldAutoSelectWhenRefreshCompletes = true
            }
        } else {
            fallbackSelectionID = selectedRegionID
            shouldAutoSelectWhenRefreshCompletes = false
        }

        startLatencyRefresh(
            for: transport,
            regionsSnapshot: self.regions,
            autoSelectIfCurrentSelection: fallbackSelectionID,
            shouldAutoSelectWhenRefreshCompletes: shouldAutoSelectWhenRefreshCompletes
        )
    }

    func cachedLatencies(
        for transport: VPNTransport,
        regions: [PIARegion]
    ) -> [String: Double]? {
        guard let cached = regionLatenciesByTransport[transport], !cached.isEmpty else {
            return nil
        }
        let validIDs = Set(regions.map(\.selectionID))
        return cached.filter { validIDs.contains($0.key) }
    }

    func startLatencyRefresh(
        for transport: VPNTransport,
        regionsSnapshot: [PIARegion],
        autoSelectIfCurrentSelection selectionID: String?,
        shouldAutoSelectWhenRefreshCompletes shouldAutoSelect: Bool
    ) {
        latencyRefreshTask?.cancel()
        latencyRefreshGeneration += 1
        let generation = latencyRefreshGeneration
        guard !regionsSnapshot.isEmpty else {
            isLatencyRefreshInProgress = false
            return
        }
        isLatencyRefreshInProgress = true

        let selector = regionAutoSelector
        latencyRefreshTask = Task(priority: .utility) {
            let measured = await selector.measureLatencies(from: regionsSnapshot, transport: transport)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }
                guard self.latencyRefreshGeneration == generation else {
                    return
                }

                regionLatenciesByTransport[transport] = measured
                if selectedTransport == transport {
                    regionLatenciesMs = measured
                }
                isLatencyRefreshInProgress = false

                guard shouldAutoSelect else {
                    return
                }
                guard selectedRegionID == selectionID else {
                    return
                }
                guard let fastest = measured.min(by: { $0.value < $1.value })?.key else {
                    return
                }
                guard fastest != selectedRegionID else {
                    return
                }

                selectedRegionID = fastest
                if let region = regions.first(where: { $0.selectionID == fastest }) {
                    appendLog("Auto-selected lowest latency region: \(region.name).")
                }
            }
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
            appendLog("Tunnel log fetch failed: \(error.presentableDescription)")
            let nsError = error as NSError
            if nsError.domain == "NEConfigurationErrorDomain" || nsError.domain == NEVPNErrorDomain {
                errorMessage = error.presentableDescription
            }
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
            appendLog("VPN permission changed. Waiting for system configuration to settle…")
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
