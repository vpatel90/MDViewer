import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - Auth Errors

public enum AuthError: LocalizedError {
    case notAuthenticated
    case missingClientID
    case denied(String)
    case missingVerifier
    case tokenExchangeFailed(String)
    case refreshFailed

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not authenticated. Please sign in with Google."
        case .missingClientID:
            "Google OAuth client ID not configured. Set MDVIEWER_GOOGLE_CLIENT_ID environment variable or create ~/.config/mdviewer/google-client-id"
        case .denied(let reason):
            "Authentication denied: \(reason)"
        case .missingVerifier:
            "Internal error: PKCE code verifier missing."
        case .tokenExchangeFailed(let reason):
            "Token exchange failed: \(reason)"
        case .refreshFailed:
            "Failed to refresh access token. Please sign in again."
        }
    }
}

// MARK: - GoogleAuthManager

@MainActor
public class GoogleAuthManager: ObservableObject {
    @Published public var isAuthenticated: Bool

    // OAuth configuration
    // Set MDVIEWER_GOOGLE_CLIENT_ID env var before building, or create
    // ~/.config/mdviewer/google-client-id with just the client ID string.
    // Create at: https://console.cloud.google.com/apis/credentials
    //   → OAuth 2.0 Client ID → Desktop app → redirect URI: mdviewer://oauth/callback
    private static let clientID: String = {
        if let envID = ProcessInfo.processInfo.environment["MDVIEWER_GOOGLE_CLIENT_ID"], !envID.isEmpty {
            return envID
        }
        let configPath = NSString("~/.config/mdviewer/google-client-id").expandingTildeInPath
        if let fileID = try? String(contentsOfFile: configPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fileID.isEmpty {
            return fileID
        }
        return ""
    }()
    // Redirect URI is set dynamically to http://127.0.0.1:{port} per session
    private var redirectURI: String = ""
    private let scope = "https://www.googleapis.com/auth/drive.file"
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let revokeURL = "https://oauth2.googleapis.com/revoke"

    // Keychain
    private let keychainService = "com.mdviewer.google-auth"
    private let accessTokenKey = "access_token"
    private let refreshTokenKey = "refresh_token"

    // PKCE state
    private var codeVerifier: String?
    private var pendingContinuation: CheckedContinuation<Void, Error>?

    public init() {
        isAuthenticated = false
        // Check Keychain for existing refresh token
        if loadFromKeychain(key: refreshTokenKey) != nil {
            isAuthenticated = true
        }
    }

    // MARK: - Public Methods

    /// Starts browser-based OAuth 2.0 flow with PKCE using a loopback HTTP server.
    public func authenticate() async throws {
        guard !Self.clientID.isEmpty else {
            throw AuthError.missingClientID
        }

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        codeVerifier = verifier

        // Start a temporary local HTTP server to receive the OAuth callback
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            startLoopbackServer { [weak self] result in
                switch result {
                case .success(let authCode):
                    continuation.resume(returning: authCode)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // Build the auth URL with the loopback redirect
            var components = URLComponents(string: authURL)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: Self.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]

            if let url = components.url {
                NSWorkspace.shared.open(url)
            }
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
        codeVerifier = nil
        isAuthenticated = true
    }

    // MARK: - Loopback Server

    private var serverSocket: Int32 = -1

    private func startLoopbackServer(completion: @escaping (Result<String, Error>) -> Void) {
        // Create a TCP socket
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            completion(.failure(AuthError.tokenExchangeFailed("Failed to create socket")))
            return
        }

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        // Bind to 127.0.0.1 on a random port (port 0 = OS assigns)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // random port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            completion(.failure(AuthError.tokenExchangeFailed("Failed to bind socket")))
            return
        }

        // Get the assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &addrLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        redirectURI = "http://127.0.0.1:\(port)"

        Darwin.listen(sock, 1)
        serverSocket = sock

        // Accept connection on a background queue
        DispatchQueue.global(qos: .userInitiated).async {
            let client = accept(sock, nil, nil)
            defer {
                close(client)
                close(sock)
            }

            guard client >= 0 else {
                DispatchQueue.main.async { completion(.failure(AuthError.tokenExchangeFailed("Failed to accept connection"))) }
                return
            }

            // Read the HTTP request
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(client, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                DispatchQueue.main.async { completion(.failure(AuthError.tokenExchangeFailed("Empty request"))) }
                return
            }

            let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            // Parse the query string from "GET /?code=...&scope=... HTTP/1.1"
            guard let firstLine = request.components(separatedBy: "\r\n").first,
                  let path = firstLine.components(separatedBy: " ").dropFirst().first,
                  let urlComponents = URLComponents(string: "http://localhost\(path)") else {
                let errorResponse = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Error</h2><p>Invalid request.</p></body></html>"
                _ = send(client, errorResponse, errorResponse.utf8.count, 0)
                DispatchQueue.main.async { completion(.failure(AuthError.tokenExchangeFailed("Invalid callback request"))) }
                return
            }

            let queryItems = urlComponents.queryItems ?? []

            if let error = queryItems.first(where: { $0.name == "error" })?.value {
                let errorResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authentication Failed</h2><p>\(error)</p><p>You can close this tab.</p></body></html>"
                _ = send(client, errorResponse, errorResponse.utf8.count, 0)
                DispatchQueue.main.async { completion(.failure(AuthError.denied(error))) }
                return
            }

            guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
                let errorResponse = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Error</h2><p>No authorization code received.</p></body></html>"
                _ = send(client, errorResponse, errorResponse.utf8.count, 0)
                DispatchQueue.main.async { completion(.failure(AuthError.tokenExchangeFailed("No code in callback"))) }
                return
            }

            // Send success response
            let successResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Signed in to MDViewer</h2><p>You can close this tab and return to MDViewer.</p></body></html>"
            _ = send(client, successResponse, successResponse.utf8.count, 0)

            DispatchQueue.main.async { completion(.success(code)) }
        }
    }

    /// Returns a valid access token, refreshing if needed.
    public func accessToken() async throws -> String {
        guard isAuthenticated else { throw AuthError.notAuthenticated }

        if let token = loadFromKeychain(key: accessTokenKey) {
            return token
        }

        return try await refreshAccessToken()
    }

    /// Forces a token refresh (call on 401 responses).
    public func handleUnauthorized() async throws -> String {
        deleteFromKeychain(key: accessTokenKey)
        return try await refreshAccessToken()
    }

    /// Revokes tokens and clears all stored credentials.
    public func disconnect() async throws {
        if let token = loadFromKeychain(key: refreshTokenKey) ?? loadFromKeychain(key: accessTokenKey) {
            var components = URLComponents(string: revokeURL)!
            components.queryItems = [URLQueryItem(name: "token", value: token)]

            if let url = components.url {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        deleteFromKeychain(key: accessTokenKey)
        deleteFromKeychain(key: refreshTokenKey)
        isAuthenticated = false
    }

    // MARK: - Private: Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        let params = [
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]

        let response = try await postTokenRequest(params: params)

        guard let accessToken = response["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed("Missing access_token in response")
        }

        saveToKeychain(key: accessTokenKey, value: accessToken)

        if let refreshToken = response["refresh_token"] as? String {
            saveToKeychain(key: refreshTokenKey, value: refreshToken)
        }
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = loadFromKeychain(key: refreshTokenKey) else {
            isAuthenticated = false
            throw AuthError.notAuthenticated
        }

        let params = [
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let response: [String: Any]
        do {
            response = try await postTokenRequest(params: params)
        } catch {
            isAuthenticated = false
            deleteFromKeychain(key: accessTokenKey)
            deleteFromKeychain(key: refreshTokenKey)
            throw AuthError.refreshFailed
        }

        guard let newAccessToken = response["access_token"] as? String else {
            isAuthenticated = false
            throw AuthError.refreshFailed
        }

        saveToKeychain(key: accessTokenKey, value: newAccessToken)
        return newAccessToken
    }

    private nonisolated func postTokenRequest(params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed("Invalid JSON response")
        }

        if let error = json["error"] as? String {
            throw AuthError.tokenExchangeFailed(error)
        }

        return json
    }

    // MARK: - Private: Continuation Helper

    private func resumePending(with error: Error?) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // MARK: - PKCE

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncoded()
    }

    // MARK: - Keychain

    private nonisolated func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private nonisolated func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Base64URL Encoding

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
