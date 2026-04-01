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
    private let redirectURI = "mdviewer://oauth/callback"
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

    /// Starts browser-based OAuth 2.0 flow with PKCE.
    public func authenticate() async throws {
        guard !Self.clientID.isEmpty else {
            throw AuthError.missingClientID
        }
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        codeVerifier = verifier

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

        guard let url = components.url else {
            throw AuthError.tokenExchangeFailed("Failed to construct auth URL")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingContinuation = continuation
            NSWorkspace.shared.open(url)
        }
    }

    /// Handles the OAuth callback URL from the system browser.
    public func handleCallback(url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            resumePending(with: AuthError.tokenExchangeFailed("Invalid callback URL"))
            return
        }

        let queryItems = components.queryItems ?? []

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let err = AuthError.denied(error)
            resumePending(with: err)
            throw err
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            let err = AuthError.tokenExchangeFailed("No authorization code in callback")
            resumePending(with: err)
            throw err
        }

        guard let verifier = codeVerifier else {
            let err = AuthError.missingVerifier
            resumePending(with: err)
            throw err
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
        codeVerifier = nil
        isAuthenticated = true
        resumePending(with: nil)
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
