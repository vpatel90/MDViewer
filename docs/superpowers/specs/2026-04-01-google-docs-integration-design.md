# Google Docs Integration Design

**Date:** 2026-04-01
**Status:** Approved
**Goal:** Add full round-trip Google Docs integration — import from a Google Doc URL, export/push rendered markdown to Google Docs, and link local `.md` files to Google Docs via frontmatter for future sync.

**Context:** MDViewer is a personal daily-driver markdown viewer. The user wants to bridge local markdown files with Google Docs for collaboration/sharing. All actions are manual (no auto-sync). OAuth via browser flow.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  MDViewer.app                                   │
│                                                 │
│  ┌──────────────┐  ┌────────────────────────┐   │
│  │ CommandPalette│  │ ContentView            │   │
│  │ (3 new items)│  │ (confirmation dialogs) │   │
│  └──────┬───────┘  └────────────┬───────────┘   │
│         │                       │               │
│  ┌──────▼───────────────────────▼───────────┐   │
│  │         GoogleDocsService                 │   │
│  │  - importDoc(url) → markdown string       │   │
│  │  - pushDoc(markdown, docID?) → url        │   │
│  └──────┬────────────────┬──────────────────┘   │
│         │                │                      │
│  ┌──────▼──────┐  ┌─────▼──────────────┐       │
│  │ GoogleAuth  │  │ MarkdownConverter   │       │
│  │ Manager     │  │ (Turndown.js +      │       │
│  │ (OAuth +    │  │  markdown-it in     │       │
│  │  Keychain)  │  │  JSContext)          │       │
│  └─────────────┘  └────────────────────┘        │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │ FrontmatterParser                        │    │
│  │ - read(fileContent) → (frontmatter, body)│    │
│  │ - write(frontmatter, body) → fileContent │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
   Google OAuth          Google Drive API
   (browser flow)        (export/upload HTML)
```

---

## Component 1: GoogleAuthManager

Handles OAuth 2.0 authentication with Google.

**OAuth Registration:**
- Google Cloud Console project with OAuth 2.0 credentials
- Scope: `https://www.googleapis.com/auth/drive.file` (access only to files the app creates/opens)
- Redirect URI: `mdviewer://oauth/callback`
- Client ID baked into the app
- Uses PKCE (Proof Key for Code Exchange) — no client secret needed for desktop apps
- Generate `code_verifier` (random 43-128 char string) and `code_challenge` (SHA256 hash, base64url encoded)

**Custom URL Scheme:**
- Register `mdviewer://` in Info.plist under `CFBundleURLTypes`
- AppDelegate handles `mdviewer://oauth/callback?code=...`

**Flow:**
1. Any Google Docs action checks `GoogleAuthManager.isAuthenticated`
2. If not authenticated, calls `GoogleAuthManager.authenticate()`
3. App opens system browser to Google consent URL: `https://accounts.google.com/o/oauth2/v2/auth?client_id=...&redirect_uri=mdviewer://oauth/callback&response_type=code&scope=...&code_challenge=...&code_challenge_method=S256`
4. User grants access, browser redirects to `mdviewer://oauth/callback?code=AUTH_CODE`
5. AppDelegate receives the URL, extracts the code, passes to GoogleAuthManager
6. GoogleAuthManager exchanges code for tokens via POST to `https://oauth2.googleapis.com/token`
7. Stores access token + refresh token in macOS Keychain

**Token Management:**
- Access token used in `Authorization: Bearer` header on all API requests
- On 401 response, refresh using refresh token via POST to `https://oauth2.googleapis.com/token`
- If refresh fails, clear tokens and re-prompt user to authenticate

**Disconnect:**
- Delete tokens from Keychain
- Revoke token via `https://oauth2.googleapis.com/revoke?token=...`

**Interface:**
```swift
class GoogleAuthManager {
    var isAuthenticated: Bool
    func authenticate() async throws  // triggers browser OAuth
    func handleCallback(url: URL) async throws  // called from AppDelegate
    func accessToken() async throws -> String  // returns valid token, refreshing if needed
    func disconnect() async throws
}
```

---

## Component 2: GoogleDocsService

Makes Google Drive API calls.

**Import (fetch doc as HTML):**
```
GET https://www.googleapis.com/drive/v3/files/{docID}/export?mimeType=text/html
Authorization: Bearer {token}
```
Returns HTML string of the document.

**Push to existing doc:**
```
PATCH https://www.googleapis.com/upload/drive/v3/files/{docID}?uploadType=media
Authorization: Bearer {token}
Content-Type: text/html

{rendered HTML body}
```
Google converts the uploaded HTML back to a native Google Doc, replacing the existing content.

**Create new doc:**
Single multipart upload with metadata + content:
```
POST https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart
Authorization: Bearer {token}
Content-Type: multipart/related; boundary=boundary

--boundary
Content-Type: application/json

{"name": "filename", "mimeType": "application/vnd.google-apps.document"}
--boundary
Content-Type: text/html

{rendered HTML body}
--boundary--
```

Returns JSON with the new doc's `id`. Construct URL: `https://docs.google.com/document/d/{id}/edit`

**Interface:**
```swift
class GoogleDocsService {
    let auth: GoogleAuthManager

    func fetchDocHTML(docID: String) async throws -> String
    func updateDoc(docID: String, html: String) async throws
    func createDoc(name: String, html: String) async throws -> String  // returns doc URL
}
```

**Doc ID extraction:** Parse Google Docs URLs with regex:
```
https://docs.google.com/document/d/([a-zA-Z0-9_-]+)
```

---

## Component 3: MarkdownConverter

Converts between HTML and markdown using JS libraries in a standalone JSContext.

**HTML → Markdown (Turndown.js):**
- Bundle Turndown.js (~30KB) in Resources
- Load into a JSContext
- Configure for GFM (tables, strikethrough, task lists)
- Call `turndownService.turndown(html)` → returns markdown string

**Markdown → HTML (markdown-it):**
- Reuse the existing bundled markdown-it + plugins in a JSContext (same pattern as Quick Look extension)
- Call `md.render(markdown)` → returns HTML string
- Wraps output in a minimal HTML document with inline CSS for reasonable formatting in Google Docs

**Interface:**
```swift
class MarkdownConverter {
    func htmlToMarkdown(_ html: String) -> String
    func markdownToHTML(_ markdown: String) -> String
}
```

**Image handling:** Google Docs HTML references images via `googleusercontent.com` URLs. Turndown converts these to `![alt](url)` markdown with remote URLs. Images render in the WebView since it allows HTTPS loads.

---

## Component 4: FrontmatterParser

Reads and writes YAML frontmatter on markdown files.

**Format:**
```yaml
---
gdoc: https://docs.google.com/document/d/ABC123/edit
---

# Document content starts here
```

**Reading:**
- Detect leading `---\n` delimiter
- Find closing `---\n` delimiter
- Parse the YAML between them (simple key-value, no need for a full YAML parser — just line-by-line `key: value` extraction)
- Return `(frontmatter: [String: String], body: String)`

**Writing:**
- If frontmatter exists: find and update the `gdoc:` line, preserve all other fields and their order
- If no frontmatter exists: prepend `---\ngdoc: {url}\n---\n\n` to the file content
- Never strip, reorder, or modify other frontmatter fields

**Integration with DocumentTab:**
- Add `gdocURL: String?` computed property to `DocumentTab` that reads from frontmatter on access
- No need to store separately — parse from `content` each time (frontmatter is always at the top, fast to check)

**Interface:**
```swift
struct FrontmatterParser {
    static func parse(_ content: String) -> (fields: [String: String], body: String)
    static func setField(_ key: String, value: String, in content: String) -> String
}
```

---

## Component 5: Command Palette Actions

Three new actions added to the command palette:

### "Import from Google Doc"
- **Always visible** (doesn't require a linked doc)
- Flow:
  1. If current tab has a `gdoc:` link → ask "Update from linked Google Doc?" (confirm/cancel)
  2. On confirm (or if no `gdoc:` link) → show text input for URL
  3. If current tab is linked and confirmed, skip URL input — use the frontmatter URL
  4. OAuth if needed
  5. Fetch HTML → convert to markdown → prepend frontmatter
  6. If current tab was linked: overwrite current file
  7. If new URL: NSSavePanel → save file → open in new tab

### "Push to Google Doc"
- **Visible when a tab is open**
- Flow:
  1. If current file has `gdoc:` link → "Push changes to linked Google Doc?" (confirm/cancel)
  2. On confirm → render markdown to HTML → update existing doc via API
  3. If no `gdoc:` link → "Create new Google Doc from this file?" (confirm/cancel)
  4. On confirm → render markdown to HTML → create new doc → write `gdoc:` URL into file's frontmatter
  5. OAuth if needed at any point

### "Disconnect Google Account"
- **Visible when authenticated**
- Clears Keychain tokens, revokes with Google

---

## Error Handling

- **No internet:** Show alert "Could not connect to Google. Check your internet connection."
- **OAuth denied/cancelled:** User simply doesn't complete the flow. No error. Action is cancelled.
- **Token expired + refresh failed:** Clear tokens, show "Please sign in to Google again." Re-trigger OAuth.
- **Invalid Google Docs URL:** Show alert "Invalid Google Docs URL. Please paste a URL like https://docs.google.com/document/d/.../edit"
- **API errors (403, 404):** Show alert with the error. "Could not access this document. Make sure you have permission to view it."
- **Conversion errors:** If Turndown or markdown-it throws, show alert "Could not convert document." Fall back gracefully.

---

## Files to Create/Modify

**New files:**
- `Sources/MDViewerCore/GoogleAuthManager.swift` — OAuth flow, Keychain storage, token refresh
- `Sources/MDViewerCore/GoogleDocsService.swift` — Drive API calls
- `Sources/MDViewerCore/MarkdownConverter.swift` — Turndown + markdown-it in JSContext
- `Sources/MDViewerCore/FrontmatterParser.swift` — YAML frontmatter read/write
- `Sources/MDViewerCore/Resources/turndown.min.js` — Turndown library

**Modified files:**
- `Sources/MDViewerCore/ContentView.swift` — add Google Docs actions to command palette builder
- `Sources/MDViewerCore/DocumentTab.swift` — add `gdocURL` computed property
- `Sources/MDViewer/MDViewerApp.swift` — handle `mdviewer://` URL scheme callback in AppDelegate
- Info.plist (via bundle.sh or project.yml) — register `CFBundleURLTypes` for `mdviewer://`

---

## Dependencies

| Dependency | Size | Purpose |
|------------|------|---------|
| Turndown.js | ~30KB | HTML → Markdown conversion |
| Security.framework | (system) | Keychain token storage |

No new external Swift dependencies. All API calls via Foundation `URLSession`.

---

## Out of Scope

- Auto-sync (push on save, pull on interval)
- Google Docs comments or suggestions
- Downloading images locally
- Status bar indicator for linked docs
- Google Drive folder browsing
- Conflict detection/resolution
- Multiple Google account support
