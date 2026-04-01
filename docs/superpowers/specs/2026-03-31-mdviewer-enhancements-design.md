# MDViewer Enhancement Design: Good to Mindblowing

**Date:** 2026-03-31
**Status:** Approved
**Goal:** Transform MDViewer from a functional markdown previewer into a polished, performant daily-driver macOS app with refined typography, deep rendering capabilities, sidebar navigation, and system integration.

**Context:** MDViewer is a personal daily-driver markdown viewer used alongside a separate text editor (Marked 2 model). Content is mixed — code, prose, diagrams, math. Size budget is unconstrained but perceived performance must remain snappy.

---

## Architecture Overview

The app retains its SwiftUI + WKWebView architecture but gains:

- A persistent, reused WKWebView (no more per-tab recreation)
- A NavigationSplitView sidebar for table of contents
- A command palette overlay
- An expanded JS rendering pipeline with lazy-loaded libraries
- A Quick Look extension target (requires Xcode project migration)

```
┌──────────────────────────────────────────────────────┐
│  MDViewer.app                                        │
│  ┌─────────────┐  ┌──────────────────────────────┐   │
│  │  Sidebar     │  │  Content Area                │   │
│  │  (TOC)       │  │  ┌──────────────────────┐    │   │
│  │              │  │  │  Tab Bar (vibrancy)   │    │   │
│  │  H1 Intro    │  │  ├──────────────────────┤    │   │
│  │  H2 Setup ◀──│──│  │                      │    │   │
│  │  H2 Usage    │  │  │  WKWebView           │    │   │
│  │    H3 API    │  │  │  (persistent, reused) │    │   │
│  │  H2 FAQ      │  │  │                      │    │   │
│  │              │  │  ├──────────────────────┤    │   │
│  │              │  │  │  Status: 1,234 words  │    │   │
│  └─────────────┘  │  └──────────────────────┘    │   │
│                    └──────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐    │
│  │  Command Palette (Cmd+K overlay)             │    │
│  └──────────────────────────────────────────────┘    │
├──────────────────────────────────────────────────────┤
│  MDViewerQuickLook.appex (QL Preview Extension)      │
└──────────────────────────────────────────────────────┘
```

---

## Tier 1: Foundation

These changes are prerequisites for everything else.

### 1.1 Xcode Project Migration

Move from pure SwiftPM (`Package.swift` + `scripts/bundle.sh`) to an Xcode project.

**Why:** Quick Look extensions require an embedded app extension target, which SwiftPM cannot produce. Xcode also provides proper code signing, entitlements, and asset catalog management.

**Structure:**
```
MDViewer.xcodeproj
├── MDViewer (app target)
│   ├── Sources/ (existing Swift files)
│   ├── Resources/ (template.html, JS libs, fonts, icons)
│   └── Info.plist
├── MDViewerQuickLook (QL extension target)
│   ├── PreviewProvider.swift
│   └── Info.plist
└── Shared (shared resources group)
    ├── template.html
    ├── markdown-it.min.js
    └── CSS themes
```

- Existing Swift source files move unchanged
- `Package.swift` and `scripts/bundle.sh` are removed
- Build settings: macOS 14+ deployment target, Swift 6, strict concurrency
- Code signing: Development signing for local use, ad-hoc for distribution

### 1.2 WKWebView Reuse

**Current problem:** `MarkdownWebView` uses `.id(tab.id)`, causing SwiftUI to destroy and recreate the entire WKWebView on every tab switch. Each creation reloads template.html + markdown-it (124KB) + mermaid (2.9MB).

**Solution:** Maintain a single persistent `WKWebView` instance owned by the `Coordinator`. Remove the `.id(tab.id)` modifier. On tab switch:

1. Save current tab's scroll position via JS: `window.pageYOffset`
2. Store in a Swift-side dictionary: `scrollPositions: [UUID: CGFloat]`
3. Call `renderMarkdown(newContent, baseURL)` with the new tab's content
4. After render completes, restore scroll position from dictionary via JS: `window.scrollTo(0, position)`

The WebView loads the template once on app launch and is never reloaded. Content updates happen exclusively through JS calls.

### 1.3 Per-Tab Scroll Position Tracking

Tied to 1.2. The `DocumentManager` gains a `scrollPositions: [UUID: CGFloat]` property. The WebView's Coordinator:

- On tab-will-switch: queries `window.pageYOffset` via `evaluateJavaScript`, stores result
- On tab-did-switch + render complete: restores from dictionary
- On file-watcher reload: saves position before re-render, restores after morphdom diff

### 1.4 Relative Image Resolution

**Current problem:** The WebView's base URL points to the app's Resources bundle. Relative image paths in markdown (e.g., `![](./images/diagram.png)`) fail to resolve.

**Solution:** When rendering content, pass the markdown file's parent directory URL to JS. Inject a `<base href="file:///path/to/markdown/dir/">` tag into the document's `<head>` before rendering. WKWebView already has read access to local files — the `loadFileURL(_:allowingReadAccessTo:)` call needs to grant access to the markdown file's directory (or a common ancestor).

**Edge case:** When switching between tabs with files in different directories, the base URL must update with each render. The `renderMarkdown()` JS function gains a second parameter: `renderMarkdown(text, baseURL)`.

**Read access scope:** Since the WKWebView is persistent and `loadFileURL(_:allowingReadAccessTo:)` is only called once at template load time, set `allowingReadAccessTo:` to the user's home directory (or `/`) to ensure images from any tab's directory are accessible. This is safe — MDViewer is a local-only viewer with no untrusted web content.

### 1.5 morphdom DOM Diffing

**Current problem:** `renderMarkdown()` replaces `#content.innerHTML` wholesale, then scrolls to top. On file-watcher reload, the user loses their scroll position, images re-flash, and mermaid diagrams that haven't changed re-render.

**Solution:** Bundle morphdom (~5KB). Change `renderMarkdown()` to:

1. Create a temporary container and set its innerHTML to the new rendered HTML
2. Call `morphdom(document.getElementById('content'), tempContainer, options)` to diff and patch
3. morphdom preserves unchanged DOM nodes — scroll position, image load state, and CSS transitions all survive
4. After morphdom completes, only render mermaid diagrams on `.mermaid` divs whose content actually changed (compare `data-original` attribute)

**Fallback:** For the initial render (empty `#content`), skip morphdom and use direct innerHTML assignment for speed.

---

## Tier 2: Rendering Enhancements

### 2.1 Syntax Highlighting (highlight.js)

**Bundle:** highlight.js common languages pack (~16KB compressed) covering ~40 languages: Swift, Python, JavaScript, TypeScript, Go, Rust, Ruby, Java, C, C++, C#, SQL, Bash, JSON, YAML, TOML, HTML, CSS, Dockerfile, Makefile, and more.

**Integration:** Configure markdown-it's `highlight` option:
```js
const md = markdownit({
  highlight: function(str, lang) {
    if (lang && hljs.getLanguage(lang)) {
      return hljs.highlight(str, { language: lang }).value;
    }
    return hljs.highlightAuto(str).value; // auto-detect
  }
});
```

**Themes:** Two highlight.js CSS themes — one for light mode, one for dark mode. These map to the light/dark mode toggle only, not per-app-theme (code highlighting is functional, not decorative — consistent coloring across all four app themes is fine). Toggled via CSS class alongside the main dark mode toggle.

**Copy button:** Each code block gets a small copy-to-clipboard button positioned top-right, visible on hover. Implemented in the custom fence renderer. Uses `navigator.clipboard.writeText()`. Brief "Copied!" feedback animation.

### 2.2 KaTeX Math Rendering

**Bundle:** KaTeX CSS + JS + fonts (~350KB total).

**Integration:** `markdown-it-texmath` plugin recognizes:
- `$...$` for inline math
- `$$...$$` for display math (centered block)

**Lazy loading:** KaTeX is not loaded in the initial template. After markdown-it parses the content, check if any math delimiters were found. If yes, dynamically load KaTeX JS + CSS, then re-render the math elements. The library stays loaded for subsequent renders.

**Theming:** KaTeX inherits text color from CSS — no special dark mode handling needed beyond what the app themes provide.

### 2.3 GitHub-Style Alerts

Render blockquote-based callout syntax into styled alert boxes.

**Supported types:**
- `> [!NOTE]` — blue, info icon
- `> [!TIP]` — green, lightbulb icon
- `> [!IMPORTANT]` — purple, message icon
- `> [!WARNING]` — yellow, warning icon
- `> [!CAUTION]` — red, stop icon

**Integration:** `markdown-it-github-alerts` plugin. Each alert type gets distinct CSS styling with colored left border, background tint, and an SVG icon. Both light and dark variants.

### 2.4 Additional markdown-it Plugins

| Plugin | Syntax | Size |
|--------|--------|------|
| `markdown-it-footnote` | `[^1]` references | ~2KB |
| `markdown-it-emoji` | `:smile:` shortcodes | ~3KB |
| `markdown-it-mark` | `==highlighted==` | <1KB |
| `markdown-it-sub` | `H~2~O` | <1KB |
| `markdown-it-sup` | `x^2^` | <1KB |

All loaded unconditionally — negligible size, extend the parser's vocabulary.

### 2.5 Lazy Mermaid Loading

**Current:** mermaid.min.js (2.9MB) is loaded via `<script src>` in the template, blocking initial page load.

**Change:** Remove the `<script>` tag from template.html. After markdown-it renders, check if any `.mermaid` divs exist in the output. If yes, dynamically create a `<script>` element to load mermaid.min.js, initialize it with the appropriate theme config, and call `mermaid.run()`. Cache the loaded state — subsequent renders with mermaid blocks don't re-load the library.

**Result:** Documents without mermaid diagrams load faster. First mermaid document in a session has a brief delay as the library loads, then it's instant.

**Theme interaction:** If the user switches themes/dark mode before any mermaid content is loaded, no mermaid work is needed. Once mermaid is loaded, theme switches re-initialize mermaid with the appropriate theme config and re-render all mermaid diagrams (existing behavior, preserved).

---

## Tier 3: UI & Navigation

### 3.1 NavigationSplitView Sidebar (Table of Contents)

**Layout:** Replace the current flat `VStack` layout with `NavigationSplitView`:

```swift
NavigationSplitView {
    TOCSidebarView(headings: headings, activeHeadingID: activeID)
} detail: {
    // existing tab bar + WebView + status bar
}
```

**TOC extraction:** After each `renderMarkdown()` call, JS walks the rendered DOM for `h1`–`h6` elements, collects an array of `{ id, text, level }` objects, and posts it to Swift via `WKScriptMessageHandler` (`window.webkit.messageHandlers.tocUpdate.postMessage(headings)`).

**TOC rendering:** A SwiftUI `List` with indentation based on heading level. `h1` is flush left, `h2` indented one level, etc. Each row is tappable — sends a JS call to `document.getElementById(headingID).scrollIntoView({ behavior: 'smooth' })`.

**Sidebar styling:** Uses the system sidebar style (automatic vibrancy on macOS). Standard collapse/expand via toolbar button or `Cmd+Ctrl+S`.

**Persistence:** Sidebar visibility persisted via `@AppStorage("sidebarVisible")`.

### 3.2 Active Heading Tracking

**JS side:** An `IntersectionObserver` monitors all heading elements with `rootMargin: '0px 0px -80% 0px'` (triggers when a heading enters the top 20% of the viewport). On intersection change, posts the active heading ID to Swift via message handler.

**Swift side:** `activeHeadingID` is a `@Published` property on `DocumentManager`. The TOC sidebar highlights the corresponding row with a selection accent. Uses `.listRowBackground()` or `.tint()` for the highlight.

**Scroll-follows-TOC:** When the active heading changes, the sidebar `ScrollView` auto-scrolls to keep the active heading visible (via `ScrollViewReader.scrollTo()`).

### 3.3 Command Palette (Cmd+K)

A modal overlay triggered by `Cmd+K`.

**UI:** A floating panel centered in the window with:
- Text input field with placeholder "Type a command..."
- Filtered results list below, updating as you type
- Each result has an icon, title, and optional keyboard shortcut hint

**Available actions:**
| Action | Icon | Shortcut |
|--------|------|----------|
| Jump to heading (one entry per heading in current doc) | `text.alignleft` | — |
| Open file... | `doc` | `Cmd+O` |
| Open recent (one entry per recent file) | `clock` | — |
| Switch to tab (one entry per open tab) | `square.on.square` | — |
| Toggle dark mode | `moon` | — |
| Toggle sidebar | `sidebar.left` | `Cmd+Ctrl+S` |
| Export as PDF | `arrow.down.doc` | `Cmd+Shift+E` |
| Copy as HTML | `doc.richtext` | — |
| Set theme (one entry per theme) | `paintpalette` | — |

**Filtering:** Fuzzy substring match on action title. Headings are prioritized when typing looks like a heading name. Results capped at 10 visible.

**Interaction:** Arrow keys navigate, Enter activates, Escape dismisses. Clicking a result activates it.

**Implementation:** A SwiftUI `.overlay()` on the main content area, conditionally shown based on `@State var showCommandPalette`. Uses `.keyboardShortcut("k", modifiers: .command)` on a hidden button to trigger.

### 3.4 Find in Page (Cmd+F)

**Implementation:** Wire `Cmd+F` menu command to call `performTextFinderAction(.showFindInterface)` on the WKWebView. This activates the native macOS find bar — standard UI with match count, next/previous navigation, and done button. Zero custom code for the find UI itself.

**Requirements:** The WKWebView's `NSView` must be in the responder chain. The Coordinator may need to override `performKeyEquivalent` or the `Commands` menu needs to target the WebView correctly.

### 3.5 Document Stats

A subtle status bar below the WebView content area.

**Data:** After each render, JS computes:
- Word count: split rendered text content by whitespace, count non-empty tokens
- Character count: text content length
- Reading time: `Math.ceil(wordCount / 238)` minutes (average adult reading speed)

Posts stats to Swift via message handler. Displayed as: `1,234 words · 5 min read`

**Styling:** Small, muted text (`.font(.caption)`, `.foregroundStyle(.secondary)`). Fixed at the bottom of the content area, not inside the WebView.

---

## Tier 4: Visual Polish

### 4.1 Typography Overhaul

**Body font:** Bundle Inter variable font (~100KB). Set as the primary body font in the HTML template. Fallback chain: `Inter, -apple-system, BlinkMacSystemFont, system-ui, sans-serif`.

**Code font:** Keep `SF Mono, Fira Code, monospace` for code blocks. No change needed.

**Fluid sizing:**
```css
:root {
  font-size: clamp(1rem, 0.95rem + 0.25vw, 1.125rem);
}
```

**Reading width:** `max-width: 68ch` on `#content` — adapts to font, stays in the optimal readability range.

**Spacing:**
- Body line-height: `1.6` (down from 1.7 — tighter but still comfortable)
- Heading margin-top: `2em` for h2, `1.5em` for h3-h6 (clearer section breaks)
- Heading letter-spacing: `-0.02em` (subtle tightening for a typeset feel)
- Paragraph margin-bottom: `1.25em`

### 4.2 Multiple Themes

Four visual themes, each with light and dark variants (8 total looks).

**Default:** Clean, neutral. Light gray code backgrounds, blue links, minimal borders. The current look, refined with better spacing and Inter font.

**Serif:** Georgia / Charter font stack for body text. Warmer background tones (`#faf8f5` light, `#1a1a1a` dark). Slightly wider line-height (1.7). More traditional/literary feel.

**Ink:** High-contrast dark-first theme. Near-black background (`#0d1117`), bright off-white text (`#e6edf3`). GitHub-dark inspired. Minimal decorative elements — the content is the star.

**Paper:** Warm cream background (`#f5f0e8` light, `#2a2520` dark). Sepia-tinted. Gentle on the eyes for extended reading sessions.

**Implementation:** Each theme is a set of CSS custom property values applied via a class on `<body>` (e.g., `.theme-serif`, `.theme-ink`). Dark mode is an orthogonal class (`.dark`). Switching themes calls `setTheme(name)` via JS and persists via `@AppStorage("theme")`. Theme selector available in command palette and a menu item.

### 4.3 Tab Bar Vibrancy

Replace `Color(nsColor: .windowBackgroundColor).opacity(0.95)` with `.background(.ultraThinMaterial)` on the tab bar container. This gives the native macOS translucent/vibrancy effect — content behind the tab bar subtly shows through.

### 4.4 Tab Selection Animation

**matchedGeometryEffect:** Add a `@Namespace` to `TabBarView`. The selected tab's background highlight uses `.matchedGeometryEffect(id: "tabHighlight", in: namespace)` so the highlight pill smoothly slides between tabs when switching.

**Animation curve:** `.animation(.spring(.snappy), value: selectedTabID)` — quick settle, slight energy, no bounce.

**Tab close button:** `.opacity(isHovered ? 1 : 0)` with `.animation(.easeInOut(duration: 0.15))`.

### 4.5 Content Transitions

**Tab switch crossfade:** The WebView content area wraps in a `.transition(.opacity)` modifier. On tab switch, a brief `0.15s` opacity dip-to-black prevents a harsh content swap flash.

**Dark mode smooth transition:** CSS `transition` on `body` for `background-color` and `color` properties (`0.3s ease`). Key elements (code blocks, blockquotes, tables) also get CSS transitions so the entire page smoothly shifts colors.

**Empty state entrance:** The `EmptyStateView` uses `.transition(.scale(scale: 0.95).combined(with: .opacity))` with `.animation(.spring(.smooth))` for a gentle entrance when all tabs are closed.

### 4.6 Scrollbar Refinement

Thin (6px), rounded, auto-hiding scrollbar styled per theme:
```css
::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-thumb {
  border-radius: 3px;
  background: var(--scrollbar-thumb);
}
::-webkit-scrollbar-thumb:hover {
  background: var(--scrollbar-thumb-hover);
}
```

Each theme defines `--scrollbar-thumb` and `--scrollbar-thumb-hover` values.

---

## Tier 5: Export & System Integration

### 5.1 PDF Export (Cmd+Shift+E)

**Trigger:** Menu item (File > Export as PDF), command palette, or `Cmd+Shift+E`.

**Process:**
1. Inject print CSS into the WebView (via JS) that:
   - Removes `max-width` constraint
   - Sets `@page { margin: 2cm; }`
   - Adds `page-break-inside: avoid` on code blocks, blockquotes, tables, `.mermaid`
   - Forces light colors (black text, white background) for print readability
   - Hides copy buttons on code blocks
   - Expands link URLs inline: `a[href]::after { content: " (" attr(href) ")"; }`
2. Call `webView.createPDF(configuration:)` with A4 page size
3. Present `NSSavePanel` with suggested filename (tab's filename with `.pdf` extension)
4. Write PDF data to selected path
5. Remove injected print CSS

### 5.2 Copy as Rich HTML

**Trigger:** Menu item (Edit > Copy as HTML) or command palette.

**Process:**
1. Evaluate JS: `document.getElementById('content').innerHTML` to get rendered HTML
2. Wrap in a minimal `<html>` with inlined CSS (the current theme's styles)
3. Write to `NSPasteboard.general` with types: `.html` and `.string` (plain text fallback)

### 5.3 Quick Look Extension

**Target:** `MDViewerQuickLook` — a QL Preview Extension embedded in the app bundle.

**PreviewProvider implementation:**
```swift
class PreviewProvider: QLPreviewProvider {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let content = try String(contentsOf: request.fileURL, encoding: .utf8)
        let html = renderMarkdownToHTML(content) // lightweight render
        return QLPreviewReply(dataOfContentType: .html, contentSize: .zero) { replyToUpdate in
            return html.data(using: .utf8)!
        }
    }
}
```

**Rendering:** The QL extension cannot easily use WKWebView. Instead, use `JavaScriptCore` (`JSContext`) to run markdown-it + highlight.js and produce an HTML string. Wrap the rendered HTML in a self-contained HTML document with the Default theme CSS inlined. No mermaid, no KaTeX (keep Quick Look fast). Respects system dark/light appearance via `@media (prefers-color-scheme: dark)` in the inlined CSS.

**Registration:** Info.plist registers for UTIs: `net.daringfireball.markdown`, `public.markdown`.

---

## Out of Scope

The following were considered and explicitly deferred:

- **Shortcuts / App Intents** — nice for automation but not daily-driver essential
- **Spotlight indexing** — useful but adds background processing complexity
- **Handoff / Continuity** — requires iCloud entitlements and cross-device testing
- **Global hotkey** — third-party dependency (KeyboardShortcuts) for marginal gain
- **Presentation mode** — different use case (slides), large scope
- **WYSIWYG editing** — MDViewer is a viewer, not an editor
- **DOCX export** — requires Pandoc dependency, niche use case
- **Wiki-links / backlinks** — knowledge management features beyond a viewer's scope

---

## Dependencies Summary

| Dependency | Size | Purpose | Loading |
|------------|------|---------|---------|
| markdown-it 14.1.0 | 124KB | Markdown parsing | Eager (in template) |
| morphdom | ~5KB | DOM diffing | Eager (in template) |
| highlight.js (common) | ~16KB | Syntax highlighting | Eager (in template) |
| KaTeX | ~350KB | Math rendering | Lazy (on first math block) |
| mermaid 11.13.0 | 2.9MB | Diagram rendering | Lazy (on first mermaid block) |
| Inter (variable font) | ~100KB | Body typography | Eager (in CSS) |
| markdown-it-texmath | ~3KB | Math delimiter parsing | Eager (plugin) |
| markdown-it-github-alerts | ~2KB | Callout blocks | Eager (plugin) |
| markdown-it-footnote | ~2KB | Footnote syntax | Eager (plugin) |
| markdown-it-emoji | ~3KB | Emoji shortcodes | Eager (plugin) |
| markdown-it-mark | <1KB | Highlight syntax | Eager (plugin) |
| markdown-it-sub | <1KB | Subscript syntax | Eager (plugin) |
| markdown-it-sup | <1KB | Superscript syntax | Eager (plugin) |

**Total eager load:** ~250KB (up from ~124KB — markdown-it alone)
**Total with lazy libs:** ~3.5MB (mostly mermaid)
**Net impact on startup:** Faster, because mermaid's 2.9MB is deferred.
