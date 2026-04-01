# Google Docs Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add round-trip Google Docs integration — import from Google Doc URL, push markdown to Google Docs, and link local files via frontmatter.

**Architecture:** OAuth via browser with PKCE + custom URL scheme callback. Google Drive API for HTML import/export. Turndown.js in JSContext for HTML→markdown. markdown-it in JSContext for markdown→HTML. Frontmatter YAML parsing for `gdoc:` links.

**Tech Stack:** Swift 6 / SwiftUI / Security.framework (Keychain) / URLSession / JavaScriptCore / Turndown.js

**Spec:** `docs/superpowers/specs/2026-04-01-google-docs-integration-design.md`

---

## Task 1: FrontmatterParser

Create a utility to read and write YAML frontmatter in markdown files. This has no external dependencies and can be fully TDD'd.

**Files:**
- Create: `Sources/MDViewerCore/FrontmatterParser.swift`
- Create: `Tests/MDViewerCoreTests/FrontmatterParserTests.swift`
- Modify: `Sources/MDViewerCore/DocumentTab.swift`

- [ ] **Step 1: Write failing tests for FrontmatterParser**

Create `Tests/MDViewerCoreTests/FrontmatterParserTests.swift`:

```swift
import Foundation
import Testing
@testable import MDViewerCore

struct FrontmatterParserTests {

    @Test func parse_withFrontmatter_returnsFieldsAndBody() {
        let content = """
        ---
        gdoc: https://docs.google.com/document/d/ABC123/edit
        title: My Doc
        ---

        # Hello World
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields["gdoc"] == "https://docs.google.com/document/d/ABC123/edit")
        #expect(result.fields["title"] == "My Doc")
        #expect(result.body.contains("# Hello World"))
        #expect(!result.body.contains("---"))
    }

    @Test func parse_withoutFrontmatter_returnsEmptyFieldsAndFullBody() {
        let content = "# Hello World\n\nSome text."
        let result = FrontmatterParser.parse(content)
        #expect(result.fields.isEmpty)
        #expect(result.body == content)
    }

    @Test func parse_withEmptyFrontmatter_returnsEmptyFields() {
        let content = "---\n---\n\n# Hello"
        let result = FrontmatterParser.parse(content)
        #expect(result.fields.isEmpty)
        #expect(result.body.contains("# Hello"))
    }

    @Test func setField_addsToExistingFrontmatter() {
        let content = "---\ntitle: My Doc\n---\n\n# Hello"
        let result = FrontmatterParser.setField("gdoc", value: "https://example.com", in: content)
        let parsed = FrontmatterParser.parse(result)
        #expect(parsed.fields["gdoc"] == "https://example.com")
        #expect(parsed.fields["title"] == "My Doc")
        #expect(parsed.body.contains("# Hello"))
    }

    @Test func setField_updatesExistingField() {
        let content = "---\ngdoc: https://old.com\n---\n\n# Hello"
        let result = FrontmatterParser.setField("gdoc", value: "https://new.com", in: content)
        let parsed = FrontmatterParser.parse(result)
        #expect(parsed.fields["gdoc"] == "https://new.com")
    }

    @Test func setField_createsNewFrontmatter() {
        let content = "# Hello World"
        let result = FrontmatterParser.setField("gdoc", value: "https://example.com", in: content)
        let parsed = FrontmatterParser.parse(result)
        #expect(parsed.fields["gdoc"] == "https://example.com")
        #expect(parsed.body.contains("# Hello World"))
    }

    @Test func setField_preservesOtherFields() {
        let content = "---\ntitle: My Doc\nauthor: Vivek\n---\n\n# Hello"
        let result = FrontmatterParser.setField("gdoc", value: "https://example.com", in: content)
        let parsed = FrontmatterParser.parse(result)
        #expect(parsed.fields["title"] == "My Doc")
        #expect(parsed.fields["author"] == "Vivek")
        #expect(parsed.fields["gdoc"] == "https://example.com")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/vivek/MDViewer && swift test --filter FrontmatterParserTests 2>&1 | tail -5
```

Expected: compilation error (FrontmatterParser doesn't exist yet).

- [ ] **Step 3: Implement FrontmatterParser**

Create `Sources/MDViewerCore/FrontmatterParser.swift`:

```swift
import Foundation

public struct FrontmatterParser {

    public static func parse(_ content: String) -> (fields: [String: String], body: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return (fields: [:], body: content)
        }

        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fields: [:], body: content)
        }

        // Find closing ---
        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let endIndex = closingIndex else {
            return (fields: [:], body: content)
        }

        // Parse fields
        var fields: [String: String] = [:]
        for i in 1..<endIndex {
            let line = lines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    fields[key] = value
                }
            }
        }

        // Body is everything after closing --- (skip one blank line if present)
        var bodyStartIndex = endIndex + 1
        if bodyStartIndex < lines.count && lines[bodyStartIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            bodyStartIndex += 1
        }
        let body = lines[bodyStartIndex...].joined(separator: "\n")

        return (fields: fields, body: body)
    }

    public static func setField(_ key: String, value: String, in content: String) -> String {
        let parsed = parse(content)
        let newLine = "\(key): \(value)"

        if parsed.fields.isEmpty && content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") == false {
            // No frontmatter exists — create one
            return "---\n\(newLine)\n---\n\n\(content)"
        }

        // Frontmatter exists — find it and update/add the field
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var inFrontmatter = false
        var foundField = false
        var passedFrontmatter = false

        for (i, line) in lines.enumerated() {
            if i == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                inFrontmatter = true
                result.append(line)
                continue
            }

            if inFrontmatter && line.trimmingCharacters(in: .whitespaces) == "---" {
                // Closing delimiter — add field here if not found yet
                if !foundField {
                    result.append(newLine)
                }
                result.append(line)
                inFrontmatter = false
                passedFrontmatter = true
                continue
            }

            if inFrontmatter {
                if let colonIndex = line.firstIndex(of: ":") {
                    let lineKey = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    if lineKey == key {
                        result.append(newLine)
                        foundField = true
                        continue
                    }
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    public static func extractDocID(from url: String) -> String? {
        // Match: https://docs.google.com/document/d/{ID}/...
        let pattern = #"docs\.google\.com/document/d/([a-zA-Z0-9_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url) else {
            return nil
        }
        return String(url[range])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/vivek/MDViewer && swift test --filter FrontmatterParserTests 2>&1 | tail -10
```

Expected: All 7 tests pass.

- [ ] **Step 5: Add gdocURL to DocumentTab**

In `Sources/MDViewerCore/DocumentTab.swift`, add a computed property:

```swift
public struct DocumentTab: Identifiable, Equatable {
    public let id: UUID
    public let fileURL: URL
    public var filename: String { fileURL.lastPathComponent }
    public var content: String

    public var gdocURL: String? {
        let parsed = FrontmatterParser.parse(content)
        return parsed.fields["gdoc"]
    }

    public init(fileURL: URL, content: String) {
        self.id = UUID()
        self.fileURL = fileURL
        self.content = content
    }
}
```

- [ ] **Step 6: Build and commit**

```bash
cd /Users/vivek/MDViewer && swift build 2>&1 | tail -3
swift test --filter FrontmatterParserTests 2>&1 | tail -5
git add Sources/MDViewerCore/FrontmatterParser.swift Sources/MDViewerCore/DocumentTab.swift Tests/MDViewerCoreTests/FrontmatterParserTests.swift
git commit -m "feat: add FrontmatterParser for YAML frontmatter read/write

Parse and modify YAML frontmatter in markdown files. Supports reading
fields, adding new fields, updating existing fields, and creating
frontmatter when none exists. Adds gdocURL computed property to
DocumentTab. Includes extractDocID for Google Docs URL parsing."
```

---

## Task 2: GoogleAuthManager

Implement OAuth 2.0 with PKCE for Google, with Keychain token storage.

**Files:**
- Create: `Sources/MDViewerCore/GoogleAuthManager.swift`
- Modify: `Sources/MDViewer/MDViewerApp.swift` (handle URL scheme callback)

- [ ] **Step 1: Create GoogleAuthManager**

Create `Sources/MDViewerCore/GoogleAuthManager.swift`:

```swift
import Foundation
import Security
import AppKit

@MainActor
public class GoogleAuthManager: ObservableObject {
    // IMPORTANT: Replace with your own Google Cloud OAuth client ID
    // Create at: https://console.cloud.google.com/apis/credentials
    // Type: Desktop application
    // Redirect URI: mdviewer://oauth/callback
    private static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"
    private static let redirectURI = "mdviewer://oauth/callback"
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let revokeURL = "https://oauth2.googleapis.com/revoke"

    private static let keychainService = "com.mdviewer.google-oauth"
    private static let accessTokenKey = "access_token"
    private static let refreshTokenKey = "refresh_token"

    @Published public var isAuthenticated: Bool = false

    private var codeVerifier: String?
    private var pendingContinuation: CheckedContinuation<Void, Error>?

    public init() {
        isAuthenticated = loadFromKeychain(key: Self.refreshTokenKey) != nil
    }

    // MARK: - Public API

    public func authenticate() async throws {
        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        NSWorkspace.shared.open(components.url!)

        try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
        }
    }

    public func handleCallback(url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            let error = components?.queryItems?.first(where: { $0.name == "error" })?.value ?? "unknown"
            pendingContinuation?.resume(throwing: AuthError.denied(error))
            pendingContinuation = nil
            return
        }

        guard let verifier = codeVerifier else {
            pendingContinuation?.resume(throwing: AuthError.missingVerifier)
            pendingContinuation = nil
            return
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
        codeVerifier = nil
        isAuthenticated = true
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    public func accessToken() async throws -> String {
        if let token = loadFromKeychain(key: Self.accessTokenKey) {
            return token
        }

        // Try refresh
        guard let refreshToken = loadFromKeychain(key: Self.refreshTokenKey) else {
            throw AuthError.notAuthenticated
        }

        try await refreshAccessToken(refreshToken: refreshToken)

        guard let token = loadFromKeychain(key: Self.accessTokenKey) else {
            throw AuthError.refreshFailed
        }
        return token
    }

    public func refreshIfNeeded() async throws -> String {
        // Always try the stored access token first, refresh on 401 in the caller
        return try await accessToken()
    }

    public func handleUnauthorized() async throws -> String {
        guard let refreshToken = loadFromKeychain(key: Self.refreshTokenKey) else {
            throw AuthError.notAuthenticated
        }
        try await refreshAccessToken(refreshToken: refreshToken)
        guard let token = loadFromKeychain(key: Self.accessTokenKey) else {
            throw AuthError.refreshFailed
        }
        return token
    }

    public func disconnect() async throws {
        if let token = loadFromKeychain(key: Self.accessTokenKey) {
            // Best-effort revoke
            var request = URLRequest(url: URL(string: "\(Self.revokeURL)?token=\(token)")!)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
        deleteFromKeychain(key: Self.accessTokenKey)
        deleteFromKeychain(key: Self.refreshTokenKey)
        isAuthenticated = false
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }

        saveToKeychain(key: Self.accessTokenKey, value: accessToken)
        if let refreshToken = json["refresh_token"] as? String {
            saveToKeychain(key: Self.refreshTokenKey, value: refreshToken)
        }
    }

    private func refreshAccessToken(refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            // Refresh token expired — clear everything
            deleteFromKeychain(key: Self.accessTokenKey)
            deleteFromKeychain(key: Self.refreshTokenKey)
            isAuthenticated = false
            throw AuthError.refreshFailed
        }

        saveToKeychain(key: Self.accessTokenKey, value: accessToken)
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private func saveToKeychain(key: String, value: String) {
        deleteFromKeychain(key: key)
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Errors

    public enum AuthError: LocalizedError {
        case notAuthenticated
        case denied(String)
        case missingVerifier
        case tokenExchangeFailed(String)
        case refreshFailed

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not signed in to Google. Please sign in first."
            case .denied(let reason): return "Google sign-in was denied: \(reason)"
            case .missingVerifier: return "Authentication state error. Please try again."
            case .tokenExchangeFailed(let detail): return "Failed to complete sign-in: \(detail)"
            case .refreshFailed: return "Session expired. Please sign in to Google again."
            }
        }
    }
}
```

Note: `CC_SHA256` requires `import CommonCrypto`. On macOS with Swift, this is available via the `CommonCrypto` module. If it doesn't compile, use `CryptoKit` instead:

```swift
import CryptoKit

private func generateCodeChallenge(from verifier: String) -> String {
    let hash = SHA256.hash(data: Data(verifier.utf8))
    return Data(hash).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
```

Use whichever compiles cleanly.

- [ ] **Step 2: Register URL scheme and handle callback in AppDelegate**

In `Sources/MDViewer/MDViewerApp.swift`:

1. Add `GoogleAuthManager` as a `@StateObject` in `MDViewerApp`:

```swift
@StateObject private var authManager = GoogleAuthManager()
```

2. Pass it to ContentView via environmentObject:

```swift
ContentView()
    .environmentObject(manager)
    .environmentObject(authManager)
    .onAppear {
        appDelegate.manager = manager
        appDelegate.authManager = authManager
    }
```

3. Add `authManager` property to `AppDelegate`:

```swift
var authManager: GoogleAuthManager?
```

4. Handle the OAuth callback URL in AppDelegate. Add/modify the `application(_:open:)` method to check for the OAuth callback:

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
    for url in urls {
        if url.scheme == "mdviewer" && url.host == "oauth" {
            Task {
                try? await authManager?.handleCallback(url: url)
            }
        } else {
            manager?.openFile(url: url)
        }
    }
}
```

5. The URL scheme registration in Info.plist is handled by `scripts/bundle.sh`. Add to the Info.plist section in bundle.sh, inside the top-level `<dict>`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>Google OAuth Callback</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>mdviewer</string>
        </array>
    </dict>
</array>
```

- [ ] **Step 3: Build and verify**

```bash
cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5
```

Expected: Build succeeds. (OAuth can't be fully tested without a real client ID, but the code compiles.)

- [ ] **Step 4: Commit**

```bash
git add Sources/MDViewerCore/GoogleAuthManager.swift Sources/MDViewer/MDViewerApp.swift scripts/bundle.sh
git commit -m "feat: add GoogleAuthManager with OAuth PKCE and Keychain storage

Browser-based OAuth 2.0 with PKCE for Google Drive API. Tokens stored
in macOS Keychain. Custom URL scheme (mdviewer://) handles callback.
Supports token refresh and disconnect/revoke."
```

---

## Task 3: MarkdownConverter (Turndown.js + markdown-it in JSContext)

Bundle Turndown.js and create a converter that runs in a standalone JSContext.

**Files:**
- Create: `Sources/MDViewerCore/Resources/turndown.min.js`
- Create: `Sources/MDViewerCore/MarkdownConverter.swift`
- Create: `Tests/MDViewerCoreTests/MarkdownConverterTests.swift`

- [ ] **Step 1: Download Turndown.js**

```bash
curl -L -o Sources/MDViewerCore/Resources/turndown.min.js \
  "https://unpkg.com/turndown@7.2.0/dist/turndown.js"
```

If version 7.2.0 isn't available, try:
```bash
curl -L -o Sources/MDViewerCore/Resources/turndown.min.js \
  "https://unpkg.com/turndown/dist/turndown.js"
```

Also download the GFM plugin for tables/strikethrough/task lists:
```bash
curl -L -o Sources/MDViewerCore/Resources/turndown-plugin-gfm.min.js \
  "https://unpkg.com/@joplin/turndown-plugin-gfm@1.0.56/dist/turndown-plugin-gfm.js"
```

Verify files are valid JS (not HTML error pages):
```bash
head -c 50 Sources/MDViewerCore/Resources/turndown.min.js
head -c 50 Sources/MDViewerCore/Resources/turndown-plugin-gfm.min.js
```

- [ ] **Step 2: Write failing tests for MarkdownConverter**

Create `Tests/MDViewerCoreTests/MarkdownConverterTests.swift`:

```swift
import Foundation
import Testing
@testable import MDViewerCore

struct MarkdownConverterTests {

    @Test func htmlToMarkdown_basicFormatting() {
        let converter = MarkdownConverter()
        let html = "<h1>Title</h1><p>Hello <strong>bold</strong> and <em>italic</em>.</p>"
        let md = converter.htmlToMarkdown(html)
        #expect(md.contains("# Title"))
        #expect(md.contains("**bold**"))
        #expect(md.contains("*italic*"))
    }

    @Test func htmlToMarkdown_list() {
        let converter = MarkdownConverter()
        let html = "<ul><li>One</li><li>Two</li></ul>"
        let md = converter.htmlToMarkdown(html)
        #expect(md.contains("- One") || md.contains("* One"))
        #expect(md.contains("- Two") || md.contains("* Two"))
    }

    @Test func htmlToMarkdown_link() {
        let converter = MarkdownConverter()
        let html = "<p><a href=\"https://example.com\">Click</a></p>"
        let md = converter.htmlToMarkdown(html)
        #expect(md.contains("[Click](https://example.com)"))
    }

    @Test func markdownToHTML_basicFormatting() {
        let converter = MarkdownConverter()
        let md = "# Title\n\nHello **bold**."
        let html = converter.markdownToHTML(md)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
    }
}
```

- [ ] **Step 3: Implement MarkdownConverter**

Create `Sources/MDViewerCore/MarkdownConverter.swift`:

```swift
import Foundation
import JavaScriptCore

public class MarkdownConverter {
    private var htmlToMdContext: JSContext?
    private var mdToHtmlContext: JSContext?

    public init() {}

    public func htmlToMarkdown(_ html: String) -> String {
        let ctx = getHtmlToMdContext()
        ctx.setObject(html, forKeyedSubscript: "__inputHTML" as NSString)
        let result = ctx.evaluateScript("""
            var service = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced' });
            if (typeof turndownPluginGfm !== 'undefined') {
                service.use(turndownPluginGfm.gfm);
            }
            service.turndown(__inputHTML);
        """)
        return result?.toString() ?? html
    }

    public func markdownToHTML(_ markdown: String) -> String {
        let ctx = getMdToHtmlContext()
        ctx.setObject(markdown, forKeyedSubscript: "__inputMD" as NSString)
        let result = ctx.evaluateScript("md.render(__inputMD)")
        let body = result?.toString() ?? "<p>\(markdown)</p>"

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
            body { font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.5; color: #333; }
            h1 { font-size: 20pt; } h2 { font-size: 16pt; } h3 { font-size: 13pt; }
            code { font-family: monospace; background: #f5f5f5; padding: 2px 4px; border-radius: 3px; }
            pre { background: #f5f5f5; padding: 12px; border-radius: 4px; overflow-x: auto; }
            pre code { background: none; padding: 0; }
            blockquote { border-left: 3px solid #ccc; padding-left: 12px; color: #666; }
            table { border-collapse: collapse; } th, td { border: 1px solid #ccc; padding: 6px 12px; }
            img { max-width: 100%; }
        </style>
        </head><body>\(body)</body></html>
        """
    }

    private func getHtmlToMdContext() -> JSContext {
        if let ctx = htmlToMdContext { return ctx }
        let ctx = JSContext()!

        // Load Turndown
        if let url = Bundle.module.url(forResource: "turndown.min", withExtension: "js", subdirectory: "Resources"),
           let js = try? String(contentsOf: url) {
            ctx.evaluateScript(js)
        }

        // Load GFM plugin
        if let url = Bundle.module.url(forResource: "turndown-plugin-gfm.min", withExtension: "js", subdirectory: "Resources"),
           let js = try? String(contentsOf: url) {
            ctx.evaluateScript(js)
        }

        htmlToMdContext = ctx
        return ctx
    }

    private func getMdToHtmlContext() -> JSContext {
        if let ctx = mdToHtmlContext { return ctx }
        let ctx = JSContext()!

        // Load markdown-it
        if let url = Bundle.module.url(forResource: "markdown-it.min", withExtension: "js", subdirectory: "Resources"),
           let js = try? String(contentsOf: url) {
            ctx.evaluateScript(js)
        }

        // Load plugins
        if let url = Bundle.module.url(forResource: "markdown-it-plugins.min", withExtension: "js", subdirectory: "Resources"),
           let js = try? String(contentsOf: url) {
            ctx.evaluateScript(js)
        }

        ctx.evaluateScript("""
            var md = markdownit({ html: true, linkify: true, typographer: true });
            if (typeof markdownitFootnote !== 'undefined') md.use(markdownitFootnote);
            if (typeof markdownitEmoji !== 'undefined') md.use(markdownitEmoji.full || markdownitEmoji);
            if (typeof markdownitMark !== 'undefined') md.use(markdownitMark);
            if (typeof markdownitSub !== 'undefined') md.use(markdownitSub);
            if (typeof markdownitSup !== 'undefined') md.use(markdownitSup);
        """)

        mdToHtmlContext = ctx
        return ctx
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/vivek/MDViewer && swift test --filter MarkdownConverterTests 2>&1 | tail -10
```

Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MDViewerCore/Resources/turndown.min.js Sources/MDViewerCore/Resources/turndown-plugin-gfm.min.js Sources/MDViewerCore/MarkdownConverter.swift Tests/MDViewerCoreTests/MarkdownConverterTests.swift
git commit -m "feat: add MarkdownConverter with Turndown.js and markdown-it

HTML→Markdown via Turndown.js with GFM plugin (tables, strikethrough,
task lists). Markdown→HTML via markdown-it with all plugins. Both run
in standalone JSContext instances, cached for reuse."
```

---

## Task 4: GoogleDocsService

API client for Google Drive import/export.

**Files:**
- Create: `Sources/MDViewerCore/GoogleDocsService.swift`

- [ ] **Step 1: Implement GoogleDocsService**

Create `Sources/MDViewerCore/GoogleDocsService.swift`:

```swift
import Foundation

@MainActor
public class GoogleDocsService {
    private let auth: GoogleAuthManager

    public init(auth: GoogleAuthManager) {
        self.auth = auth
    }

    /// Fetch a Google Doc as HTML
    public func fetchDocHTML(docID: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(docID)/export?mimeType=text/html")!
        let data = try await authenticatedRequest(url: url, method: "GET")
        guard let html = String(data: data, encoding: .utf8) else {
            throw DocsError.invalidResponse
        }
        return html
    }

    /// Update an existing Google Doc with HTML content
    public func updateDoc(docID: String, html: String) async throws {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(docID)?uploadType=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("text/html", forHTTPHeaderField: "Content-Type")
        request.httpBody = html.data(using: .utf8)

        _ = try await authenticatedDataRequest(request: request)
    }

    /// Create a new Google Doc from HTML, returns the document URL
    public func createDoc(name: String, html: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!

        let boundary = UUID().uuidString
        var body = Data()

        // Metadata part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        let metadata = ["name": name, "mimeType": "application/vnd.google-apps.document"]
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n".data(using: .utf8)!)

        // Content part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/html\r\n\r\n".data(using: .utf8)!)
        body.append(html.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await authenticatedDataRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let docID = json["id"] as? String else {
            throw DocsError.createFailed
        }

        return "https://docs.google.com/document/d/\(docID)/edit"
    }

    // MARK: - Authenticated requests with auto-retry on 401

    private func authenticatedRequest(url: URL, method: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return try await authenticatedDataRequest(request: request)
    }

    private func authenticatedDataRequest(request: URLRequest) async throws -> Data {
        var req = request
        let token = try await auth.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                // Token expired, refresh and retry once
                let newToken = try await auth.handleUnauthorized()
                req.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await URLSession.shared.data(for: req)
                try checkResponse(retryResponse, data: retryData)
                return retryData
            }
            try checkResponse(response, data: data)
        }

        return data
    }

    private func checkResponse(_ response: URLResponse?, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DocsError.apiError(statusCode: http.statusCode, message: body)
        }
    }

    // MARK: - Errors

    public enum DocsError: LocalizedError {
        case invalidResponse
        case createFailed
        case apiError(statusCode: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Google."
            case .createFailed: return "Failed to create Google Doc."
            case .apiError(let code, let msg):
                if code == 403 { return "Access denied. Make sure you have permission to access this document." }
                if code == 404 { return "Document not found. Check the URL and try again." }
                return "Google API error (\(code)): \(msg)"
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Sources/MDViewerCore/GoogleDocsService.swift
git commit -m "feat: add GoogleDocsService for Drive API import/export

Fetch Google Doc as HTML, update existing doc, and create new doc via
multipart upload. Auto-retries on 401 with token refresh."
```

---

## Task 5: Command Palette Integration

Wire everything together with 3 new command palette actions: Import, Push, Disconnect.

**Files:**
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewer/MDViewerApp.swift`

- [ ] **Step 1: Add GoogleDocsService and auth to the app**

In `Sources/MDViewer/MDViewerApp.swift`, the `GoogleAuthManager` was added as a `@StateObject` in Task 2. Now add `GoogleDocsService` and `MarkdownConverter` as dependencies.

Since `GoogleDocsService` needs `GoogleAuthManager`, create it in `MDViewerApp.body` or as a lazy property. The simplest approach: create them in ContentView since that's where the command palette lives.

Actually, the cleanest approach: add them to ContentView directly since it already has `@EnvironmentObject var manager`.

- [ ] **Step 2: Add Google Docs actions to ContentView**

In `Sources/MDViewerCore/ContentView.swift`:

1. Add the environment object and state:

```swift
@EnvironmentObject var authManager: GoogleAuthManager
@State private var showGDocURLInput = false
@State private var gdocURLInput = ""
```

2. Create lazy properties for the services (inside the struct or as computed):

```swift
private var docsService: GoogleDocsService { GoogleDocsService(auth: authManager) }
private var converter: MarkdownConverter { MarkdownConverter() }
```

3. Add Google Docs items to `buildCommandPaletteItems()`, before the "Open File..." action:

```swift
        // Google Docs
        items.append(CommandPaletteItem(
            icon: "arrow.down.doc.fill",
            title: "Import from Google Doc",
            shortcut: nil,
            action: { handleImportFromGoogleDoc() }
        ))

        if manager.selectedTab != nil {
            items.append(CommandPaletteItem(
                icon: "arrow.up.doc.fill",
                title: "Push to Google Doc",
                shortcut: nil,
                action: { handlePushToGoogleDoc() }
            ))
        }

        if authManager.isAuthenticated {
            items.append(CommandPaletteItem(
                icon: "person.crop.circle.badge.xmark",
                title: "Disconnect Google Account",
                shortcut: nil,
                action: {
                    Task { try? await authManager.disconnect() }
                }
            ))
        }
```

4. Add the handler methods to ContentView:

```swift
    private func handleImportFromGoogleDoc() {
        // Check if current tab is linked to a Google Doc
        if let tab = manager.selectedTab, let gdocURL = tab.gdocURL,
           let docID = FrontmatterParser.extractDocID(from: gdocURL) {
            // Linked doc — confirm and import
            let alert = NSAlert()
            alert.messageText = "Update from Google Doc?"
            alert.informativeText = "This will replace the current file contents with the Google Doc."
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await ensureAuthenticated()
                    let html = try await docsService.fetchDocHTML(docID: docID)
                    let markdown = converter.htmlToMarkdown(html)
                    let newContent = FrontmatterParser.setField("gdoc", value: gdocURL, in: markdown)
                    try newContent.write(to: tab.fileURL, atomically: true, encoding: .utf8)
                } catch {
                    showError(error)
                }
            }
        } else {
            // No linked doc — ask for URL
            showGDocURLInput = true
            gdocURLInput = ""
        }
    }

    private func handleImportWithURL() {
        guard let docID = FrontmatterParser.extractDocID(from: gdocURLInput) else {
            showError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Google Docs URL. Expected: https://docs.google.com/document/d/.../edit"]))
            return
        }

        Task {
            do {
                try await ensureAuthenticated()
                let html = try await docsService.fetchDocHTML(docID: docID)
                let markdown = converter.htmlToMarkdown(html)
                let gdocURL = "https://docs.google.com/document/d/\(docID)/edit"
                let newContent = FrontmatterParser.setField("gdoc", value: gdocURL, in: markdown)

                // Save to new file
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = "imported.md"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }

                try newContent.write(to: url, atomically: true, encoding: .utf8)
                manager.openFile(url: url)
            } catch {
                showError(error)
            }
        }
    }

    private func handlePushToGoogleDoc() {
        guard let tab = manager.selectedTab else { return }

        let parsed = FrontmatterParser.parse(tab.content)
        let markdownBody = parsed.body

        if let gdocURL = parsed.fields["gdoc"],
           let docID = FrontmatterParser.extractDocID(from: gdocURL) {
            // Linked — update existing
            let alert = NSAlert()
            alert.messageText = "Push to Google Doc?"
            alert.informativeText = "This will replace the Google Doc contents with this file."
            alert.addButton(withTitle: "Push")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await ensureAuthenticated()
                    let html = converter.markdownToHTML(markdownBody)
                    try await docsService.updateDoc(docID: docID, html: html)
                } catch {
                    showError(error)
                }
            }
        } else {
            // Not linked — create new
            let alert = NSAlert()
            alert.messageText = "Create new Google Doc?"
            alert.informativeText = "This will create a new Google Doc from this file and link it."
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await ensureAuthenticated()
                    let html = converter.markdownToHTML(markdownBody)
                    let name = tab.filename.replacingOccurrences(of: ".md", with: "")
                    let docURL = try await docsService.createDoc(name: name, html: html)

                    // Write gdoc link into frontmatter
                    let updatedContent = FrontmatterParser.setField("gdoc", value: docURL, in: tab.content)
                    try updatedContent.write(to: tab.fileURL, atomically: true, encoding: .utf8)
                } catch {
                    showError(error)
                }
            }
        }
    }

    private func ensureAuthenticated() async throws {
        if !authManager.isAuthenticated {
            try await authManager.authenticate()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
```

5. Add a URL input sheet overlay for when the user needs to paste a Google Docs URL. Add this to the `.overlay` modifier chain in the body, alongside the command palette overlay:

```swift
.sheet(isPresented: $showGDocURLInput) {
    VStack(spacing: 16) {
        Text("Import from Google Doc")
            .font(.headline)
        TextField("Paste Google Docs URL...", text: $gdocURLInput)
            .textFieldStyle(.roundedBorder)
            .frame(width: 400)
            .onSubmit { showGDocURLInput = false; handleImportWithURL() }
        HStack {
            Button("Cancel") { showGDocURLInput = false }
                .keyboardShortcut(.cancelAction)
            Button("Import") { showGDocURLInput = false; handleImportWithURL() }
                .keyboardShortcut(.defaultAction)
                .disabled(gdocURLInput.isEmpty)
        }
    }
    .padding(24)
}
```

- [ ] **Step 3: Build and verify**

```bash
cd /Users/vivek/MDViewer && swift build 2>&1 | tail -10
```

Fix any compilation errors. The key integration points:
- `authManager` must be available as `@EnvironmentObject` (set up in MDViewerApp)
- `GoogleDocsService` and `MarkdownConverter` are created inline
- `FrontmatterParser` is used for reading/writing gdoc links
- NSAlert is used for confirmations

- [ ] **Step 4: Commit**

```bash
git add Sources/MDViewerCore/ContentView.swift Sources/MDViewer/MDViewerApp.swift
git commit -m "feat: add Google Docs import/push/disconnect to command palette

Import from Google Doc (paste URL or auto-detect linked doc), push
markdown to Google Docs (update existing or create new with frontmatter
link), and disconnect Google account. All accessible via Cmd+K."
```

---

## Task 6: URL Scheme Registration in bundle.sh

Register the `mdviewer://` custom URL scheme so macOS routes OAuth callbacks to the app.

**Files:**
- Modify: `scripts/bundle.sh`

- [ ] **Step 1: Add CFBundleURLTypes to Info.plist in bundle.sh**

In `scripts/bundle.sh`, find the Info.plist heredoc. Add the URL scheme registration inside the top-level `<dict>`, after the `NSSupportsSuddenTermination` entry:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>MDViewer OAuth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>mdviewer</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 2: Build the bundle and verify**

```bash
cd /Users/vivek/MDViewer && bash scripts/bundle.sh 2>&1 | tail -3
# Verify the URL scheme is in the plist
grep -A5 "CFBundleURLSchemes" MDViewer.app/Contents/Info.plist
```

Expected: Shows `<string>mdviewer</string>` in the output.

- [ ] **Step 3: Commit**

```bash
git add scripts/bundle.sh
git commit -m "feat: register mdviewer:// URL scheme for OAuth callback"
```

---

## Verification Checklist

After all tasks are complete, verify the full flow:

- [ ] `FrontmatterParser` tests pass: `swift test --filter FrontmatterParserTests`
- [ ] `MarkdownConverter` tests pass: `swift test --filter MarkdownConverterTests`
- [ ] App builds cleanly: `swift build -c release`
- [ ] Bundle builds: `bash scripts/bundle.sh`
- [ ] Cmd+K shows "Import from Google Doc" and "Push to Google Doc"
- [ ] "Disconnect Google Account" only appears when authenticated
- [ ] Import flow: paste URL → save dialog → creates .md with `gdoc:` frontmatter
- [ ] Push flow (unlinked): creates new Google Doc → writes `gdoc:` into frontmatter
- [ ] Push flow (linked): updates existing Google Doc
- [ ] Import flow (linked): auto-detects linked doc, confirms, overwrites file
- [ ] OAuth: first action opens browser, callback returns to app, subsequent actions use stored token

**Note:** Full OAuth testing requires a real Google Cloud OAuth client ID. Replace `YOUR_CLIENT_ID.apps.googleusercontent.com` in `GoogleAuthManager.swift` with a real client ID from the Google Cloud Console. Create one at: https://console.cloud.google.com/apis/credentials → Create Credentials → OAuth client ID → Desktop application → Add `mdviewer://oauth/callback` as redirect URI.
