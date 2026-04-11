import Foundation

protocol PIAAPIClientProtocol {
    func authenticate(username: String, password: String) async throws -> PIAAuthToken
    func fetchRegions() async throws -> [PIARegion]
    func exchangeWireGuardKey(
        token: String,
        server: PIAServerEndpoint,
        certificatePEM: String
    ) async throws -> PIAWireGuardHandshake
}

struct PIAAPIClient: PIAAPIClientProtocol {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        self.decoder = decoder
    }

    func authenticate(username: String, password: String) async throws -> PIAAuthToken {
        var request = URLRequest(url: URL(string: "https://www.privateinternetaccess.com/api/client/v2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "username=\(username.formURLEncoded)&password=\(password.formURLEncoded)"
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try response.validateHTTPStatusCode()

        let payload = try decoder.decode(TokenResponse.self, from: data)
        guard !payload.token.isEmpty else {
            throw PIAAPIError.invalidCredentials
        }

        return PIAAuthToken(
            token: payload.token,
            expiresAt: Date().addingTimeInterval(24 * 60 * 60)
        )
    }

    func fetchRegions() async throws -> [PIARegion] {
        let (data, response) = try await session.data(from: URL(string: "https://serverlist.piaservers.net/vpninfo/servers/v6")!)
        try response.validateHTTPStatusCode()
        return try Self.parseServerListPayload(data, decoder: decoder)
    }

    func exchangeWireGuardKey(
        token: String,
        server: PIAServerEndpoint,
        certificatePEM: String
    ) async throws -> PIAWireGuardHandshake {
        try await exchangeWireGuardKey(
            token: token,
            server: server,
            certificatePEM: certificatePEM,
            publicKey: try PIAPrivateKeyGenerator.publicKey(for: try PIAPrivateKeyGenerator.privateKey())
        )
    }

    func exchangeWireGuardKey(
        token: String,
        server: PIAServerEndpoint,
        certificatePEM: String,
        publicKey: String
    ) async throws -> PIAWireGuardHandshake {
        let data = try await PIAWireGuardCurlClient.exchangeKey(
            token: token,
            publicKey: publicKey,
            server: server,
            certificatePEM: certificatePEM
        )
        let handshake = try decoder.decode(PIAWireGuardHandshake.self, from: data)
        guard handshake.status == "OK" else {
            throw PIAAPIError.wireGuardHandshakeFailed
        }
        return handshake
    }

    static func parseServerListPayload(
        _ data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [PIARegion] {
        guard let string = String(data: data, encoding: .utf8) else {
            throw PIAAPIError.invalidResponse("Server list payload was not UTF-8.")
        }
        guard let firstLine = string.split(whereSeparator: \.isNewline).first else {
            throw PIAAPIError.invalidResponse("Server list payload was empty.")
        }
        let envelope = try decoder.decode(PIARegionsEnvelope.self, from: Data(firstLine.utf8))
        return envelope.regions.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private extension PIAAPIClient {
    struct TokenResponse: Decodable {
        let token: String
    }
}

enum PIAAPIError: LocalizedError {
    case invalidCredentials
    case invalidResponse(String?)
    case wireGuardHandshakeFailed
    case tlsValidationFailed
    case connectionClosed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "PIA rejected the username or password."
        case .invalidResponse(let details):
            if let details, !details.isEmpty {
                return "PIA returned an unexpected response: \(details)"
            }
            return "PIA returned an unexpected response."
        case .wireGuardHandshakeFailed:
            return "PIA did not accept the WireGuard key exchange."
        case .tlsValidationFailed:
            return "PIA WireGuard TLS validation failed."
        case .connectionClosed:
            return "The PIA WireGuard server closed the connection unexpectedly."
        case .commandFailed(let details):
            return "The WireGuard setup command failed: \(details)"
        }
    }
}

private enum PIAWireGuardCurlClient {
    static func exchangeKey(
        token: String,
        publicKey: String,
        server: PIAServerEndpoint,
        certificatePEM: String
    ) async throws -> Data {
        let certificateURL = try writeCertificate(certificatePEM)
        defer {
            try? FileManager.default.removeItem(at: certificateURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sS",
            "-G",
            "--connect-to", "\(server.cn)::\(server.ip):",
            "--cacert", certificateURL.path,
            "--data-urlencode", "pt=\(token)",
            "--data-urlencode", "pubkey=\(publicKey)",
            "https://\(server.cn):1337/addKey"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw PIAAPIError.commandFailed(errorOutput ?? "curl exit \(process.terminationStatus)")
        }
        guard !output.isEmpty else {
            throw PIAAPIError.invalidResponse(errorOutput ?? "WireGuard handshake returned no body.")
        }
        return output
    }

    static func writeCertificate(_ certificatePEM: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("privateclient-pia-ca-\(UUID().uuidString).crt")
        try certificatePEM.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private extension String {
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .formURLValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let formURLValueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

private extension URLResponse {
    func validateHTTPStatusCode() throws {
        guard let httpResponse = self as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw PIAAPIError.invalidResponse("HTTP status \((self as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }
}
