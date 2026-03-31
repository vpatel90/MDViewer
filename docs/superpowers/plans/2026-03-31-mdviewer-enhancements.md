# MDViewer Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform MDViewer from a functional markdown previewer into a polished, performant daily-driver macOS app with refined typography, deep rendering capabilities, sidebar navigation, and system integration.

**Architecture:** SwiftUI + persistent WKWebView with a NavigationSplitView sidebar. JavaScript rendering pipeline using markdown-it with plugins, morphdom for DOM diffing, lazy-loaded mermaid and KaTeX. Quick Look extension via Xcode project migration.

**Tech Stack:** Swift 6 / SwiftUI / WebKit / markdown-it / morphdom / highlight.js / KaTeX / mermaid.js / Inter font

**Spec:** `docs/superpowers/specs/2026-03-31-mdviewer-enhancements-design.md`

---

## Phase 1: Performance Foundation

### Task 1: WKWebView Reuse + Scroll Position Tracking

Remove per-tab WebView recreation. Maintain a single persistent WKWebView and swap content via JS. Track scroll positions per tab.

**Files:**
- Modify: `Sources/MDViewerCore/MarkdownWebView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Remove scrollTo from template.html**

In `Sources/MDViewerCore/Resources/template.html`, in the `renderMarkdown` function (~line 353), remove the `window.scrollTo(0, 0);` line:

```js
    async function renderMarkdown(text) {
        currentMarkdownText = text;
        const html = md.render(text);
        document.getElementById('content').innerHTML = html;
        await renderMermaidDiagrams();
    }
```

- [ ] **Step 2: Rewrite MarkdownWebView.swift with tab tracking**

Replace the entire contents of `Sources/MDViewerCore/MarkdownWebView.swift`:

```swift
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let tabID: UUID

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingContent = (content, tabID)
        context.coordinator.pendingDarkMode = isDarkMode

        if let templateURL = Bundle.module.url(
            forResource: "template",
            withExtension: "html",
            subdirectory: "Resources"
        ) {
            let resourceDir = templateURL.deletingLastPathComponent()
            webView.loadFileURL(templateURL, allowingReadAccessTo: resourceDir)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.renderContent(content, tabID: tabID)
        context.coordinator.applyDarkMode(isDarkMode)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingContent: (String, UUID)?
        var pendingDarkMode: Bool?
        var isLoaded = false
        private var lastRenderedContent: String?
        private var lastDarkMode: Bool?
        private var currentTabID: UUID?
        private var scrollPositions: [UUID: Double] = [:]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let darkMode = pendingDarkMode {
                pendingDarkMode = nil
                applyDarkMode(darkMode)
            }
            if let (content, tabID) = pendingContent {
                pendingContent = nil
                renderContent(content, tabID: tabID)
            }
        }

        func applyDarkMode(_ isDark: Bool) {
            guard isLoaded, let webView = webView else {
                pendingDarkMode = isDark
                return
            }
            if isDark == lastDarkMode { return }
            lastDarkMode = isDark
            webView.evaluateJavaScript("setDarkMode(\(isDark))") { _, _ in }
        }

        func renderContent(_ content: String, tabID: UUID) {
            guard isLoaded, let webView = webView else {
                pendingContent = (content, tabID)
                return
            }

            let isTabSwitch = tabID != currentTabID

            // Skip if same tab + same content (file watcher re-deliver)
            if !isTabSwitch && content == lastRenderedContent { return }

            // Save scroll position for outgoing tab
            if isTabSwitch, let outgoingID = currentTabID {
                webView.evaluateJavaScript("window.pageYOffset") { [weak self] result, _ in
                    if let pos = result as? Double {
                        self?.scrollPositions[outgoingID] = pos
                    }
                }
            }

            currentTabID = tabID
            lastRenderedContent = content

            guard let jsonData = try? JSONEncoder().encode(content),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let savedScroll = scrollPositions[tabID] ?? 0

            webView.evaluateJavaScript("renderMarkdown(\(jsonString))") { [weak self] _, error in
                if let error = error {
                    print("MDViewer render error: \(error.localizedDescription)")
                }
                if isTabSwitch && savedScroll > 0 {
                    self?.webView?.evaluateJavaScript("window.scrollTo(0, \(savedScroll))") { _, _ in }
                }
            }
        }

        func clearScrollPosition(for tabID: UUID) {
            scrollPositions.removeValue(forKey: tabID)
        }
    }
}
```

- [ ] **Step 3: Update ContentView to remove .id(tab.id) and pass tabID**

In `Sources/MDViewerCore/ContentView.swift`, replace the tab content block (lines 35-41):

```swift
                if let tab = manager.selectedTab {
                    MarkdownWebView(content: tab.content, isDarkMode: isDarkMode, tabID: tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
```

Note: The `.id(tab.id)` modifier is gone. This is the key change.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 5: Manual verification**

Run the app. Open two markdown files. Scroll down in the first file. Switch to the second tab. Scroll down. Switch back to the first tab. Verify:
1. No flash/reload when switching tabs (content swaps instantly)
2. Scroll position is restored when returning to the first tab

- [ ] **Step 6: Commit**

```bash
git add Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewerCore/ContentView.swift Sources/MDViewerCore/Resources/template.html
git commit -m "perf: reuse WKWebView across tabs with scroll position tracking

Stop recreating the WebView on every tab switch. Maintain a single
persistent instance, swap content via JS, and save/restore per-tab
scroll positions."
```

---

### Task 2: Relative Image Resolution

Make relative image paths in markdown (e.g., `![](./images/foo.png)`) resolve correctly relative to the markdown file's directory.

**Files:**
- Modify: `Sources/MDViewerCore/MarkdownWebView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Add image resolution to renderMarkdown in template.html**

In `Sources/MDViewerCore/Resources/template.html`, change the `renderMarkdown` function signature and add image resolution after setting innerHTML:

```js
    async function renderMarkdown(text, fileDir) {
        currentMarkdownText = text;
        const html = md.render(text);
        document.getElementById('content').innerHTML = html;

        // Resolve relative image paths against the markdown file's directory
        if (fileDir) {
            document.querySelectorAll('#content img').forEach(img => {
                const src = img.getAttribute('src');
                if (src && !src.startsWith('http') && !src.startsWith('file:')
                    && !src.startsWith('data:') && !src.startsWith('/')) {
                    img.src = fileDir + '/' + src;
                }
            });
        }

        await renderMermaidDiagrams();
    }
```

Also update `setDarkMode` to pass fileDir when re-rendering (~line 389):

```js
    let currentFileDir = '';

    async function renderMarkdown(text, fileDir) {
        currentMarkdownText = text;
        currentFileDir = fileDir || '';
        const html = md.render(text);
        document.getElementById('content').innerHTML = html;

        // Resolve relative image paths against the markdown file's directory
        if (currentFileDir) {
            document.querySelectorAll('#content img').forEach(img => {
                const src = img.getAttribute('src');
                if (src && !src.startsWith('http') && !src.startsWith('file:')
                    && !src.startsWith('data:') && !src.startsWith('/')) {
                    img.src = currentFileDir + '/' + src;
                }
            });
        }

        await renderMermaidDiagrams();
    }
```

And in `setDarkMode`, change the re-render call:

```js
    async function setDarkMode(isDark) {
        if (isDark) {
            document.body.classList.add('dark');
        } else {
            document.body.classList.remove('dark');
        }
        if (isDark !== currentDarkMode) {
            currentDarkMode = isDark;
            initMermaid(isDark);
            if (currentMarkdownText) {
                const html = md.render(currentMarkdownText);
                document.getElementById('content').innerHTML = html;
                // Re-resolve images
                if (currentFileDir) {
                    document.querySelectorAll('#content img').forEach(img => {
                        const src = img.getAttribute('src');
                        if (src && !src.startsWith('http') && !src.startsWith('file:')
                            && !src.startsWith('data:') && !src.startsWith('/')) {
                            img.src = currentFileDir + '/' + src;
                        }
                    });
                }
                await renderMermaidDiagrams();
            }
        }
    }
```

- [ ] **Step 2: Add fileDir parameter to MarkdownWebView**

In `Sources/MDViewerCore/MarkdownWebView.swift`, add `fileDir` to the struct and threading:

Add the property:
```swift
struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let tabID: UUID
    let fileDir: String
```

Update `makeNSView` to store fileDir in pending:
```swift
        context.coordinator.pendingContent = (content, tabID, fileDir)
```

Update `updateNSView`:
```swift
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.renderContent(content, tabID: tabID, fileDir: fileDir)
        context.coordinator.applyDarkMode(isDarkMode)
    }
```

Update Coordinator's `pendingContent` type:
```swift
        var pendingContent: (String, UUID, String)?
```

Update `didFinish`:
```swift
            if let (content, tabID, fileDir) = pendingContent {
                pendingContent = nil
                renderContent(content, tabID: tabID, fileDir: fileDir)
            }
```

Update `renderContent` to accept and pass fileDir:
```swift
        func renderContent(_ content: String, tabID: UUID, fileDir: String = "") {
            guard isLoaded, let webView = webView else {
                pendingContent = (content, tabID, fileDir)
                return
            }

            let isTabSwitch = tabID != currentTabID
            if !isTabSwitch && content == lastRenderedContent { return }

            if isTabSwitch, let outgoingID = currentTabID {
                webView.evaluateJavaScript("window.pageYOffset") { [weak self] result, _ in
                    if let pos = result as? Double {
                        self?.scrollPositions[outgoingID] = pos
                    }
                }
            }

            currentTabID = tabID
            lastRenderedContent = content

            guard let jsonData = try? JSONEncoder().encode(content),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let fileDirEscaped = fileDir
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            let savedScroll = scrollPositions[tabID] ?? 0

            webView.evaluateJavaScript("renderMarkdown(\(jsonString), '\(fileDirEscaped)')") { [weak self] _, error in
                if let error = error {
                    print("MDViewer render error: \(error.localizedDescription)")
                }
                if isTabSwitch && savedScroll > 0 {
                    self?.webView?.evaluateJavaScript("window.scrollTo(0, \(savedScroll))") { _, _ in }
                }
            }
        }
```

- [ ] **Step 3: Broaden loadFileURL read access**

In `makeNSView`, change `allowingReadAccessTo` to grant filesystem-wide read access:

```swift
        if let templateURL = Bundle.module.url(
            forResource: "template",
            withExtension: "html",
            subdirectory: "Resources"
        ) {
            webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
```

- [ ] **Step 4: Pass fileDir from ContentView**

In `Sources/MDViewerCore/ContentView.swift`, update the MarkdownWebView call:

```swift
                if let tab = manager.selectedTab {
                    MarkdownWebView(
                        content: tab.content,
                        isDarkMode: isDarkMode,
                        tabID: tab.id,
                        fileDir: tab.fileURL.deletingLastPathComponent().absoluteString
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
```

Note: `.absoluteString` gives `file:///path/to/dir/` which is what the JS expects for resolving relative URLs.

- [ ] **Step 5: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Expected: Build succeeds.

Test with a markdown file that references a relative image (e.g., `![test](./screenshot.png)` where screenshot.png exists in the same directory). Verify the image loads.

- [ ] **Step 6: Commit**

```bash
git add Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewerCore/ContentView.swift Sources/MDViewerCore/Resources/template.html
git commit -m "feat: resolve relative image paths against markdown file directory

Pass the markdown file's parent directory to JS renderMarkdown. After
rendering, resolve relative img src attributes against that directory.
Also broadens WKWebView file access to support images anywhere."
```

---

### Task 3: morphdom DOM Diffing

Replace innerHTML replacement with morphdom diffing to preserve scroll position and avoid flashing on file-watcher reloads.

**Files:**
- Create: `Sources/MDViewerCore/Resources/morphdom-umd.min.js`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Download morphdom**

```bash
curl -L -o Sources/MDViewerCore/Resources/morphdom-umd.min.js \
  "https://unpkg.com/morphdom@2.7.4/dist/morphdom-umd.min.js"
```

Verify the file exists and is ~15KB:
```bash
ls -la Sources/MDViewerCore/Resources/morphdom-umd.min.js
```

- [ ] **Step 2: Add morphdom script tag to template.html**

In `Sources/MDViewerCore/Resources/template.html`, add after the markdown-it script tag (line 227):

```html
<script src="markdown-it.min.js"></script>
<script src="morphdom-umd.min.js"></script>
<script src="mermaid.min.js"></script>
```

- [ ] **Step 3: Update renderMarkdown to use morphdom**

Replace the `renderMarkdown` function in template.html:

```js
    let isFirstRender = true;

    async function renderMarkdown(text, fileDir) {
        currentMarkdownText = text;
        currentFileDir = fileDir || '';
        const html = md.render(text);
        const contentEl = document.getElementById('content');

        if (isFirstRender || !contentEl.hasChildNodes()) {
            // First render: direct innerHTML for speed
            contentEl.innerHTML = html;
            isFirstRender = false;
        } else {
            // Subsequent renders: morphdom for minimal DOM changes
            const wrapper = document.createElement('div');
            wrapper.innerHTML = html;
            morphdom(contentEl, wrapper, { childrenOnly: true });
        }

        // Resolve relative image paths
        if (currentFileDir) {
            document.querySelectorAll('#content img').forEach(img => {
                const src = img.getAttribute('src');
                if (src && !src.startsWith('http') && !src.startsWith('file:')
                    && !src.startsWith('data:') && !src.startsWith('/')) {
                    img.src = currentFileDir + '/' + src;
                }
            });
        }

        await renderMermaidDiagrams();
    }
```

Also update `setDarkMode` to use the same pattern:

```js
    async function setDarkMode(isDark) {
        if (isDark) {
            document.body.classList.add('dark');
        } else {
            document.body.classList.remove('dark');
        }
        if (isDark !== currentDarkMode) {
            currentDarkMode = isDark;
            initMermaid(isDark);
            if (currentMarkdownText) {
                // Force full re-render for theme change (mermaid needs fresh SVGs)
                const html = md.render(currentMarkdownText);
                document.getElementById('content').innerHTML = html;
                if (currentFileDir) {
                    document.querySelectorAll('#content img').forEach(img => {
                        const src = img.getAttribute('src');
                        if (src && !src.startsWith('http') && !src.startsWith('file:')
                            && !src.startsWith('data:') && !src.startsWith('/')) {
                            img.src = currentFileDir + '/' + src;
                        }
                    });
                }
                await renderMermaidDiagrams();
            }
        }
    }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Expected: Build succeeds.

Test: Open a markdown file, scroll down. Edit the file externally (add a line at the top). Verify the content updates without jumping to the top.

- [ ] **Step 5: Commit**

```bash
git add Sources/MDViewerCore/Resources/morphdom-umd.min.js Sources/MDViewerCore/Resources/template.html
git commit -m "perf: add morphdom for incremental DOM updates

Use morphdom to diff and patch the rendered HTML instead of replacing
innerHTML. Preserves scroll position and avoids image re-flashing on
file-watcher reloads. First render still uses direct innerHTML for speed."
```

---

### Task 4: Lazy Mermaid Loading

Defer mermaid.js (2.9MB) loading until a document contains mermaid code blocks. Non-mermaid documents load faster.

**Files:**
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Remove mermaid script tag and replace with lazy loader**

In `Sources/MDViewerCore/Resources/template.html`:

1. Remove the line `<script src="mermaid.min.js"></script>`
2. Remove the `initMermaid(false);` call
3. Replace the mermaid-related code with lazy loading:

Replace the entire mermaid config and rendering section (from `const mermaidFont` through `renderMermaidDiagrams`) with:

```js
    // Mermaid lazy loading
    const mermaidFont = '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif';

    const lightMermaidConfig = {
        startOnLoad: false,
        theme: 'base',
        fontFamily: mermaidFont,
        flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis', padding: 15 },
        sequence: { useMaxWidth: true, mirrorActors: false, actorMargin: 80, messageFontSize: 13 },
        gantt: { useMaxWidth: false },
        themeVariables: {
            fontSize: '13px',
            primaryColor: '#dbeafe', primaryBorderColor: '#93c5fd', primaryTextColor: '#1e3a5f',
            lineColor: '#94a3b8',
            secondaryColor: '#ede9fe', secondaryBorderColor: '#c4b5fd', secondaryTextColor: '#3b0764',
            tertiaryColor: '#ecfdf5', tertiaryBorderColor: '#86efac', tertiaryTextColor: '#064e3b',
            noteBkgColor: '#fef9c3', noteBorderColor: '#fde68a', noteTextColor: '#713f12',
            actorBkg: '#dbeafe', actorBorder: '#93c5fd', actorTextColor: '#1e3a5f', actorLineColor: '#94a3b8',
            signalColor: '#334155', signalTextColor: '#334155',
            labelBoxBkgColor: '#f1f5f9', labelBoxBorderColor: '#cbd5e1', labelTextColor: '#334155',
            loopTextColor: '#475569',
            activationBorderColor: '#93c5fd', activationBkgColor: '#dbeafe',
            sequenceNumberColor: '#ffffff', nodeTextColor: '#1e3a5f',
        }
    };

    const darkMermaidConfig = {
        startOnLoad: false,
        theme: 'base',
        fontFamily: mermaidFont,
        flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis', padding: 15 },
        sequence: { useMaxWidth: true, mirrorActors: false, actorMargin: 80, messageFontSize: 13 },
        gantt: { useMaxWidth: false },
        themeVariables: {
            fontSize: '13px',
            primaryColor: '#1e3a5f', primaryBorderColor: '#3b82f6', primaryTextColor: '#e0ecff',
            lineColor: '#64748b',
            secondaryColor: '#2e1065', secondaryBorderColor: '#7c3aed', secondaryTextColor: '#e0d4ff',
            tertiaryColor: '#064e3b', tertiaryBorderColor: '#34d399', tertiaryTextColor: '#d1fae5',
            noteBkgColor: '#422006', noteBorderColor: '#a16207', noteTextColor: '#fef3c7',
            actorBkg: '#1e3a5f', actorBorder: '#3b82f6', actorTextColor: '#e0ecff', actorLineColor: '#64748b',
            signalColor: '#cbd5e1', signalTextColor: '#cbd5e1',
            labelBoxBkgColor: '#1e293b', labelBoxBorderColor: '#475569', labelTextColor: '#cbd5e1',
            loopTextColor: '#94a3b8',
            activationBorderColor: '#3b82f6', activationBkgColor: '#1e3a5f',
            sequenceNumberColor: '#ffffff', nodeTextColor: '#e0ecff',
            mainBkg: '#1e293b', nodeBorder: '#475569',
            clusterBkg: '#1e293b', clusterBorder: '#475569',
            titleColor: '#e2e8f0', edgeLabelBackground: '#1e293b', background: '#0d1117',
        }
    };

    let mermaidLoaded = false;
    let mermaidLoading = false;

    function initMermaid(isDark) {
        if (mermaidLoaded && typeof mermaid !== 'undefined') {
            mermaid.initialize(isDark ? darkMermaidConfig : lightMermaidConfig);
        }
    }

    async function loadMermaidIfNeeded() {
        if (mermaidLoaded) return true;
        if (mermaidLoading) {
            // Wait for ongoing load
            return new Promise(resolve => {
                const check = setInterval(() => {
                    if (mermaidLoaded) { clearInterval(check); resolve(true); }
                }, 50);
            });
        }

        mermaidLoading = true;
        return new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = 'mermaid.min.js';
            script.onload = () => {
                mermaidLoaded = true;
                mermaidLoading = false;
                mermaid.initialize(currentDarkMode ? darkMermaidConfig : lightMermaidConfig);
                resolve(true);
            };
            script.onerror = (e) => {
                mermaidLoading = false;
                console.error('Failed to load mermaid:', e);
                reject(e);
            };
            document.head.appendChild(script);
        });
    }

    async function renderMermaidDiagrams() {
        const mermaidDivs = document.querySelectorAll('.mermaid');
        if (mermaidDivs.length === 0) return;

        await loadMermaidIfNeeded();

        mermaidDivs.forEach(div => {
            if (div.getAttribute('data-processed')) {
                const code = div.getAttribute('data-original') || div.textContent;
                div.removeAttribute('data-processed');
                div.innerHTML = code;
            }
            if (!div.getAttribute('data-original')) {
                div.setAttribute('data-original', div.textContent);
            }
        });
        try {
            await mermaid.run({ querySelector: '.mermaid' });
        } catch(e) {
            console.error('Mermaid rendering error:', e);
        }
    }
```

- [ ] **Step 2: Update setDarkMode to handle lazy mermaid**

The `setDarkMode` function needs to only re-init mermaid if it's loaded:

```js
    async function setDarkMode(isDark) {
        if (isDark) {
            document.body.classList.add('dark');
        } else {
            document.body.classList.remove('dark');
        }
        if (isDark !== currentDarkMode) {
            currentDarkMode = isDark;
            initMermaid(isDark); // no-op if mermaid not loaded yet
            if (currentMarkdownText) {
                const html = md.render(currentMarkdownText);
                document.getElementById('content').innerHTML = html;
                if (currentFileDir) {
                    document.querySelectorAll('#content img').forEach(img => {
                        const src = img.getAttribute('src');
                        if (src && !src.startsWith('http') && !src.startsWith('file:')
                            && !src.startsWith('data:') && !src.startsWith('/')) {
                            img.src = currentFileDir + '/' + src;
                        }
                    });
                }
                await renderMermaidDiagrams();
            }
        }
    }
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open a non-mermaid markdown file. Verify it renders immediately (no 2.9MB mermaid load). Then open a file with a mermaid block. Verify the diagram renders after a brief delay.

- [ ] **Step 4: Commit**

```bash
git add Sources/MDViewerCore/Resources/template.html
git commit -m "perf: lazy-load mermaid.js only when mermaid blocks detected

Defer loading the 2.9MB mermaid library until a document actually
contains mermaid code blocks. Non-mermaid documents load faster.
Library stays loaded for subsequent renders."
```

---

## Phase 2: Rendering Enhancements

### Task 5: Syntax Highlighting with highlight.js

Add language-aware syntax coloring to fenced code blocks with a copy-to-clipboard button.

**Files:**
- Create: `Sources/MDViewerCore/Resources/highlight.min.js`
- Create: `Sources/MDViewerCore/Resources/hljs-github.css`
- Create: `Sources/MDViewerCore/Resources/hljs-github-dark.css`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Download highlight.js and themes**

```bash
cd /Users/vivek/MDViewer/Sources/MDViewerCore/Resources

# Download highlight.js core + common languages bundle
curl -L -o highlight.min.js \
  "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js"

# Download GitHub light theme
curl -L -o hljs-github.css \
  "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/github.min.css"

# Download GitHub dark theme
curl -L -o hljs-github-dark.css \
  "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/github-dark.min.css"
```

Verify files exist:
```bash
ls -la highlight.min.js hljs-github.css hljs-github-dark.css
```

Note: If the common languages bundle from cdnjs doesn't include enough languages, download additional language modules from `https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/languages/{lang}.min.js` and load them in template.html. The core bundle includes ~40 common languages.

- [ ] **Step 2: Add highlight.js tags and CSS to template.html**

In `Sources/MDViewerCore/Resources/template.html`, add in the `<head>` section, before the closing `</style>` tag, add CSS for the copy button and highlight theme toggling:

```css
    /* Highlight.js theme toggle */
    .hljs-light { display: block; }
    .hljs-dark { display: none; }
    body.dark .hljs-light { display: none; }
    body.dark .hljs-dark { display: block; }

    /* Code block wrapper */
    .code-block {
        position: relative;
        margin-bottom: 1em;
    }
    .code-block pre {
        margin-bottom: 0;
    }
    .copy-btn {
        position: absolute;
        top: 8px;
        right: 8px;
        padding: 3px 8px;
        font-size: 0.7em;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        color: var(--blockquote-text);
        background: var(--code-bg);
        border: 1px solid var(--code-border);
        border-radius: 4px;
        cursor: pointer;
        opacity: 0;
        transition: opacity 0.15s;
    }
    .code-block:hover .copy-btn { opacity: 1; }
    .copy-btn:hover { background: var(--border); }
    .copy-btn.copied { color: #22c55e; }
```

After the `</style>` tag, add the highlight.js CSS links:

```html
<link rel="stylesheet" href="hljs-github.css" class="hljs-light">
<link rel="stylesheet" href="hljs-github-dark.css" class="hljs-dark">
```

Add the highlight.js script tag before the markdown-it script:

```html
<script src="highlight.min.js"></script>
<script src="markdown-it.min.js"></script>
```

- [ ] **Step 3: Update markdown-it config and fence renderer**

Replace the markdown-it initialization and custom fence renderer in template.html:

```js
    // Initialize markdown-it with syntax highlighting
    const md = window.markdownit({
        html: true,
        linkify: true,
        typographer: true,
        highlight: function(str, lang) {
            if (lang && hljs.getLanguage(lang)) {
                try {
                    return hljs.highlight(str, { language: lang, ignoreIllegals: true }).value;
                } catch (_) {}
            }
            try {
                return hljs.highlightAuto(str).value;
            } catch (_) {}
            return ''; // use default escaping
        }
    });

    // Custom fence renderer: mermaid → div, everything else → code block with copy button
    const defaultFence = md.renderer.rules.fence;
    md.renderer.rules.fence = function(tokens, idx, options, env, self) {
        const token = tokens[idx];
        const lang = token.info.trim().split(/\s+/)[0].toLowerCase();

        if (lang === 'mermaid') {
            return '<div class="mermaid">' + md.utils.escapeHtml(token.content) + '</div>';
        }

        // Render with highlight.js (already done by the highlight option)
        let highlighted;
        if (options.highlight) {
            highlighted = options.highlight(token.content, lang) || md.utils.escapeHtml(token.content);
        } else {
            highlighted = md.utils.escapeHtml(token.content);
        }

        const langAttr = lang ? ` data-lang="${md.utils.escapeHtml(lang)}"` : '';
        return '<div class="code-block"' + langAttr + '>' +
               '<button class="copy-btn" onclick="copyCode(this)">Copy</button>' +
               '<pre><code class="hljs">' + highlighted + '</code></pre>' +
               '</div>';
    };
```

Add the copyCode function:

```js
    function copyCode(btn) {
        const code = btn.parentElement.querySelector('code');
        navigator.clipboard.writeText(code.textContent).then(() => {
            btn.textContent = 'Copied!';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.textContent = 'Copy';
                btn.classList.remove('copied');
            }, 2000);
        });
    }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open a markdown file with fenced code blocks (e.g., ```python, ```swift, ```json). Verify:
1. Code is syntax-colored
2. Hover over a code block shows a "Copy" button
3. Clicking "Copy" copies the code and shows "Copied!" briefly
4. Toggle dark mode — highlight colors switch to dark theme

- [ ] **Step 5: Commit**

```bash
git add Sources/MDViewerCore/Resources/highlight.min.js Sources/MDViewerCore/Resources/hljs-github.css Sources/MDViewerCore/Resources/hljs-github-dark.css Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add syntax highlighting with highlight.js

Integrate highlight.js for language-aware code coloring in fenced code
blocks. Includes GitHub light/dark themes, auto-language detection, and
a copy-to-clipboard button that appears on hover."
```

---

### Task 6: markdown-it Plugins (Footnotes, Emoji, Mark, Sub, Sup)

Bundle and integrate additional markdown-it plugins for extended syntax support.

**Files:**
- Create: `Sources/MDViewerCore/Resources/markdown-it-plugins.min.js`
- Create: `scripts/bundle-plugins.sh`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Create the plugin bundling script**

Create `scripts/bundle-plugins.sh`:

```bash
#!/bin/bash
# Bundle markdown-it plugins into a single JS file for the browser
set -e

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

cd "$WORK"
npm init -y --silent > /dev/null 2>&1
npm install --silent \
  markdown-it-footnote@4 \
  markdown-it-emoji@3 \
  markdown-it-mark@4 \
  markdown-it-sub@2 \
  markdown-it-sup@2 \
  esbuild@latest > /dev/null 2>&1

cat > entry.js << 'ENTRY'
window.markdownitFootnote = require('markdown-it-footnote');
window.markdownitEmoji = require('markdown-it-emoji');
window.markdownitMark = require('markdown-it-mark');
window.markdownitSub = require('markdown-it-sub');
window.markdownitSup = require('markdown-it-sup');
ENTRY

npx esbuild entry.js --bundle --outfile=bundle.js --format=iife --minify --platform=browser 2>/dev/null

DEST="${1:-Sources/MDViewerCore/Resources/markdown-it-plugins.min.js}"
cp bundle.js "$DEST"
echo "Bundled to $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes)"
```

- [ ] **Step 2: Run the bundling script**

```bash
cd /Users/vivek/MDViewer
chmod +x scripts/bundle-plugins.sh
./scripts/bundle-plugins.sh
```

Expected: Creates `Sources/MDViewerCore/Resources/markdown-it-plugins.min.js` (~30-50KB).

Verify:
```bash
ls -la Sources/MDViewerCore/Resources/markdown-it-plugins.min.js
```

- [ ] **Step 3: Add plugin script tag and usage to template.html**

Add the script tag after markdown-it in template.html:

```html
<script src="markdown-it.min.js"></script>
<script src="markdown-it-plugins.min.js"></script>
```

After the `const md = window.markdownit({...})` initialization, add plugin registration:

```js
    // Register plugins
    md.use(window.markdownitFootnote);
    md.use(window.markdownitEmoji);
    md.use(window.markdownitMark);
    md.use(window.markdownitSub);
    md.use(window.markdownitSup);
```

- [ ] **Step 4: Add CSS for mark (highlight) styling**

In the `<style>` section of template.html, add:

```css
    mark {
        background-color: #fff3b0;
        padding: 0.1em 0.2em;
        border-radius: 2px;
    }
    body.dark mark {
        background-color: #854d0e;
        color: #fef3c7;
    }
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test with markdown containing:
- `[^1]` footnotes — verify footnote links and back-references render
- `:smile:` emoji — verify emoji renders
- `==highlighted==` — verify yellow highlight
- `H~2~O` — verify subscript
- `x^2^` — verify superscript

- [ ] **Step 6: Commit**

```bash
git add scripts/bundle-plugins.sh Sources/MDViewerCore/Resources/markdown-it-plugins.min.js Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add markdown-it plugins for footnotes, emoji, mark, sub, sup

Bundle markdown-it-footnote, markdown-it-emoji, markdown-it-mark,
markdown-it-sub, and markdown-it-sup into a single JS file. Adds
support for extended markdown syntax."
```

---

### Task 7: GitHub-Style Alerts

Add support for `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]` callout blocks.

**Files:**
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Add GitHub alerts as a custom markdown-it plugin**

In template.html, after the plugin registrations (`.use(window.markdownitSup)`), add:

```js
    // GitHub-style alerts plugin (inline implementation)
    const alertTypes = {
        'NOTE':      { icon: '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>', color: '#0969da', darkColor: '#58a6ff' },
        'TIP':       { icon: '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"/></svg>', color: '#1a7f37', darkColor: '#3fb950' },
        'IMPORTANT': { icon: '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>', color: '#8250df', darkColor: '#a371f7' },
        'WARNING':   { icon: '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>', color: '#9a6700', darkColor: '#d29922' },
        'CAUTION':   { icon: '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>', color: '#cf222e', darkColor: '#f85149' },
    };

    // Hook into blockquote rendering to detect alert syntax
    const defaultBlockquoteOpen = md.renderer.rules.blockquote_open;
    const defaultBlockquoteClose = md.renderer.rules.blockquote_close;

    md.core.ruler.after('block', 'github_alerts', function(state) {
        const tokens = state.tokens;
        for (let i = 0; i < tokens.length; i++) {
            if (tokens[i].type !== 'blockquote_open') continue;

            // Find the first inline content in this blockquote
            let j = i + 1;
            while (j < tokens.length && tokens[j].type !== 'blockquote_close') {
                if (tokens[j].type === 'inline') {
                    const match = tokens[j].content.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*\n?/);
                    if (match) {
                        const type = match[1];
                        const info = alertTypes[type];
                        tokens[j].content = tokens[j].content.slice(match[0].length);
                        tokens[i].type = 'alert_open';
                        tokens[i].tag = 'div';
                        tokens[i].info = type;
                        tokens[i].attrSet('class', 'markdown-alert markdown-alert-' + type.toLowerCase());
                        tokens[i].attrSet('style', '--alert-color: ' + info.color + '; --alert-dark-color: ' + info.darkColor);

                        // Find matching close
                        let depth = 1;
                        for (let k = i + 1; k < tokens.length; k++) {
                            if (tokens[k].type === 'blockquote_open') depth++;
                            if (tokens[k].type === 'blockquote_close') {
                                depth--;
                                if (depth === 0) {
                                    tokens[k].type = 'alert_close';
                                    tokens[k].tag = 'div';
                                    break;
                                }
                            }
                        }
                    }
                    break;
                }
                j++;
            }
        }
    });

    md.renderer.rules.alert_open = function(tokens, idx) {
        const type = tokens[idx].info;
        const info = alertTypes[type];
        return '<div class="markdown-alert markdown-alert-' + type.toLowerCase() + '">' +
               '<p class="markdown-alert-title">' + info.icon + ' ' + type.charAt(0) + type.slice(1).toLowerCase() + '</p>';
    };

    md.renderer.rules.alert_close = function() {
        return '</div>';
    };
```

- [ ] **Step 2: Add CSS for alerts**

In the `<style>` section of template.html:

```css
    .markdown-alert {
        padding: 0.5em 1em;
        margin-bottom: 1em;
        border-left: 4px solid var(--alert-color, var(--blockquote-border));
        border-radius: 0 6px 6px 0;
        background: color-mix(in srgb, var(--alert-color, var(--blockquote-border)) 8%, transparent);
    }
    body.dark .markdown-alert {
        border-left-color: var(--alert-dark-color, var(--blockquote-border));
        background: color-mix(in srgb, var(--alert-dark-color, var(--blockquote-border)) 10%, transparent);
    }
    .markdown-alert-title {
        display: flex;
        align-items: center;
        gap: 0.5em;
        font-weight: 600;
        font-size: 0.875em;
        color: var(--alert-color);
        margin-bottom: 0.25em;
    }
    body.dark .markdown-alert-title { color: var(--alert-dark-color); }
    .markdown-alert-title svg { flex-shrink: 0; }
    .markdown-alert p:last-child { margin-bottom: 0; }
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test with markdown containing:
```
> [!NOTE]
> This is a note.

> [!WARNING]
> This is a warning.
```

Verify: styled callout boxes with colored left border, icon, and title.

- [ ] **Step 4: Commit**

```bash
git add Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add GitHub-style alert callouts

Support > [!NOTE], > [!TIP], > [!IMPORTANT], > [!WARNING], and
> [!CAUTION] blockquote syntax with styled callout boxes, SVG icons,
and light/dark theme support."
```

---

### Task 8: KaTeX Math Rendering (Lazy-Loaded)

Add support for `$inline$` and `$$display$$` math expressions using KaTeX, loaded on demand.

**Files:**
- Create: `Sources/MDViewerCore/Resources/katex/` (directory with JS, CSS, fonts)
- Create: `scripts/download-katex.sh`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Download KaTeX**

Create and run `scripts/download-katex.sh`:

```bash
#!/bin/bash
set -e
DEST="Sources/MDViewerCore/Resources/katex"
mkdir -p "$DEST/fonts"

VERSION="0.16.21"
BASE="https://cdn.jsdelivr.net/npm/katex@${VERSION}/dist"

curl -L -o "$DEST/katex.min.js" "${BASE}/katex.min.js"
curl -L -o "$DEST/katex.min.css" "${BASE}/katex.min.css"

# Download required fonts
for font in KaTeX_Main-Regular KaTeX_Main-Bold KaTeX_Main-Italic KaTeX_Main-BoldItalic \
            KaTeX_Math-Italic KaTeX_Math-BoldItalic \
            KaTeX_Size1-Regular KaTeX_Size2-Regular KaTeX_Size3-Regular KaTeX_Size4-Regular \
            KaTeX_AMS-Regular KaTeX_Caligraphic-Regular KaTeX_Caligraphic-Bold \
            KaTeX_Fraktur-Regular KaTeX_Fraktur-Bold \
            KaTeX_SansSerif-Regular KaTeX_SansSerif-Bold KaTeX_SansSerif-Italic \
            KaTeX_Script-Regular KaTeX_Typewriter-Regular; do
    curl -sL -o "$DEST/fonts/${font}.woff2" "${BASE}/fonts/${font}.woff2"
done

echo "KaTeX ${VERSION} downloaded to ${DEST}"
ls -la "$DEST/katex.min.js" "$DEST/katex.min.css"
echo "Fonts: $(ls "$DEST/fonts/" | wc -l | tr -d ' ') files"
```

```bash
cd /Users/vivek/MDViewer
chmod +x scripts/download-katex.sh
./scripts/download-katex.sh
```

- [ ] **Step 2: Fix KaTeX CSS font paths**

The downloaded `katex.min.css` references fonts at `fonts/KaTeX_*`. Since our CSS is loaded from the `katex/` subdirectory and fonts are in `katex/fonts/`, this should work. But verify by checking the CSS:

```bash
head -5 Sources/MDViewerCore/Resources/katex/katex.min.css | grep -o 'url([^)]*)'  | head -3
```

If paths use `url(fonts/...)`, they're correct relative to the CSS file location. If they use `url(../fonts/...)` or absolute paths, fix with sed.

- [ ] **Step 3: Add KaTeX lazy loading and math parsing to template.html**

Add to the JS section of template.html, after the alert plugin code:

```js
    // KaTeX math rendering (lazy-loaded)
    let katexLoaded = false;
    let katexLoading = false;

    async function loadKaTeXIfNeeded() {
        if (katexLoaded) return true;
        if (katexLoading) {
            return new Promise(resolve => {
                const check = setInterval(() => {
                    if (katexLoaded) { clearInterval(check); resolve(true); }
                }, 50);
            });
        }
        katexLoading = true;
        return new Promise((resolve, reject) => {
            // Load CSS
            const link = document.createElement('link');
            link.rel = 'stylesheet';
            link.href = 'katex/katex.min.css';
            document.head.appendChild(link);

            // Load JS
            const script = document.createElement('script');
            script.src = 'katex/katex.min.js';
            script.onload = () => {
                katexLoaded = true;
                katexLoading = false;
                resolve(true);
            };
            script.onerror = (e) => {
                katexLoading = false;
                reject(e);
            };
            document.head.appendChild(script);
        });
    }

    // Render math expressions in the document
    async function renderMath() {
        const content = document.getElementById('content');
        // Check for math delimiters in the text content
        const text = content.innerHTML;
        if (!text.match(/\$\$[\s\S]+?\$\$|\$[^\$\n]+?\$/)) return;

        await loadKaTeXIfNeeded();

        // Process display math ($$...$$)
        content.querySelectorAll('p, li, td, th, blockquote').forEach(el => {
            el.innerHTML = el.innerHTML.replace(/\$\$([\s\S]+?)\$\$/g, (match, math) => {
                try {
                    return katex.renderToString(math.trim(), { displayMode: true, throwOnError: false });
                } catch(e) { return match; }
            });
        });

        // Process inline math ($...$) — avoid matching currency like "$5"
        content.querySelectorAll('p, li, td, th, blockquote').forEach(el => {
            // Skip elements that contain code blocks
            if (el.querySelector('code, pre')) return;
            el.innerHTML = el.innerHTML.replace(/\$([^\$\n]+?)\$/g, (match, math) => {
                // Skip if it looks like currency (number right after $)
                if (/^\d/.test(math.trim())) return match;
                try {
                    return katex.renderToString(math.trim(), { displayMode: false, throwOnError: false });
                } catch(e) { return match; }
            });
        });
    }
```

Update `renderMarkdown` to call `renderMath()` after mermaid:

```js
    async function renderMarkdown(text, fileDir) {
        currentMarkdownText = text;
        currentFileDir = fileDir || '';
        const html = md.render(text);
        const contentEl = document.getElementById('content');

        if (isFirstRender || !contentEl.hasChildNodes()) {
            contentEl.innerHTML = html;
            isFirstRender = false;
        } else {
            const wrapper = document.createElement('div');
            wrapper.innerHTML = html;
            morphdom(contentEl, wrapper, { childrenOnly: true });
        }

        if (currentFileDir) {
            document.querySelectorAll('#content img').forEach(img => {
                const src = img.getAttribute('src');
                if (src && !src.startsWith('http') && !src.startsWith('file:')
                    && !src.startsWith('data:') && !src.startsWith('/')) {
                    img.src = currentFileDir + '/' + src;
                }
            });
        }

        await renderMermaidDiagrams();
        await renderMath();
    }
```

Also update `setDarkMode` to call `renderMath()` after re-rendering.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test with markdown containing `$E = mc^2$` inline and `$$\int_0^1 x^2 dx = \frac{1}{3}$$` display math. Verify equations render beautifully. Also test that a file without math doesn't load KaTeX (check in Web Inspector that katex.min.js is not loaded).

- [ ] **Step 5: Commit**

```bash
git add scripts/download-katex.sh Sources/MDViewerCore/Resources/katex/ Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add KaTeX math rendering with lazy loading

Support \$inline\$ and \$\$display\$\$ math expressions using KaTeX.
Library is lazy-loaded only when math delimiters are detected in the
document. Includes fonts for proper mathematical typography."
```

---

## Phase 3: UI & Navigation

### Task 9: Table of Contents Sidebar with Active Heading Tracking

Add a collapsible NavigationSplitView sidebar showing document headings with active section highlighting.

**Files:**
- Create: `Sources/MDViewerCore/TOCSidebarView.swift`
- Modify: `Sources/MDViewerCore/DocumentManager.swift`
- Modify: `Sources/MDViewerCore/MarkdownWebView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Add heading model and properties to DocumentManager**

In `Sources/MDViewerCore/DocumentManager.swift`, add a heading struct and published properties:

```swift
public struct HeadingItem: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let level: Int
}
```

Add to the `DocumentManager` class:

```swift
    @Published public var headings: [HeadingItem] = []
    @Published public var activeHeadingID: String?
```

- [ ] **Step 2: Add WKScriptMessageHandler to MarkdownWebView**

In `Sources/MDViewerCore/MarkdownWebView.swift`:

Add `import Combine` at the top if needed, and add a message handler property:

```swift
struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let tabID: UUID
    let fileDir: String
    let onHeadingsUpdate: ([HeadingItem]) -> Void
    let onActiveHeadingChange: (String?) -> Void
```

In `makeNSView`, register message handlers:

```swift
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(context.coordinator, name: "tocUpdate")
        config.userContentController.add(context.coordinator, name: "activeHeading")

        let webView = WKWebView(frame: .zero, configuration: config)
        // ... rest unchanged
```

Add `WKScriptMessageHandler` to the Coordinator:

```swift
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        // ... existing properties ...
        var onHeadingsUpdate: (([HeadingItem]) -> Void)?
        var onActiveHeadingChange: ((String?) -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "tocUpdate", let headings = message.body as? [[String: Any]] {
                let items = headings.compactMap { dict -> HeadingItem? in
                    guard let id = dict["id"] as? String,
                          let text = dict["text"] as? String,
                          let level = dict["level"] as? Int else { return nil }
                    return HeadingItem(id: id, text: text, level: level)
                }
                onHeadingsUpdate?(items)
            } else if message.name == "activeHeading", let id = message.body as? String {
                onActiveHeadingChange?(id.isEmpty ? nil : id)
            }
        }
```

In `makeCoordinator`, wire the callbacks:

```swift
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onHeadingsUpdate = onHeadingsUpdate
        coordinator.onActiveHeadingChange = onActiveHeadingChange
        return coordinator
    }
```

Also add a `scrollToHeading` method to the Coordinator:

```swift
        func scrollToHeading(_ headingID: String) {
            guard isLoaded, let webView = webView else { return }
            let escaped = headingID.replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("document.getElementById('\(escaped)')?.scrollIntoView({ behavior: 'smooth', block: 'start' })") { _, _ in }
        }
```

- [ ] **Step 3: Add heading extraction and IntersectionObserver to template.html**

In the JS section of template.html, add after the `renderMath` function:

```js
    // TOC: Extract headings and send to Swift
    function extractHeadings() {
        const headings = [];
        document.querySelectorAll('#content h1, #content h2, #content h3, #content h4, #content h5, #content h6').forEach((el, i) => {
            // Assign an ID if missing
            if (!el.id) {
                el.id = 'heading-' + i;
            }
            headings.push({
                id: el.id,
                text: el.textContent,
                level: parseInt(el.tagName[1])
            });
        });
        try {
            window.webkit.messageHandlers.tocUpdate.postMessage(headings);
        } catch(e) {}
    }

    // Active heading tracking via IntersectionObserver
    let headingObserver = null;

    function setupHeadingObserver() {
        if (headingObserver) headingObserver.disconnect();

        const headingEls = document.querySelectorAll('#content h1, #content h2, #content h3, #content h4, #content h5, #content h6');
        if (headingEls.length === 0) return;

        headingObserver = new IntersectionObserver((entries) => {
            // Find the topmost visible heading
            let topHeading = null;
            let topY = Infinity;
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    const rect = entry.boundingClientRect;
                    if (rect.top < topY && rect.top >= -50) {
                        topY = rect.top;
                        topHeading = entry.target;
                    }
                }
            });
            if (topHeading) {
                try {
                    window.webkit.messageHandlers.activeHeading.postMessage(topHeading.id);
                } catch(e) {}
            }
        }, {
            rootMargin: '0px 0px -80% 0px',
            threshold: [0, 1]
        });

        headingEls.forEach(el => headingObserver.observe(el));
    }
```

Update `renderMarkdown` to call these after rendering:

```js
        // ... after renderMath()
        extractHeadings();
        setupHeadingObserver();
```

- [ ] **Step 4: Create TOCSidebarView.swift**

Create `Sources/MDViewerCore/TOCSidebarView.swift`:

```swift
import SwiftUI

struct TOCSidebarView: View {
    let headings: [HeadingItem]
    let activeHeadingID: String?
    let onHeadingTap: (String) -> Void

    var body: some View {
        List {
            ForEach(headings) { heading in
                Button(action: { onHeadingTap(heading.id) }) {
                    Text(heading.text)
                        .font(.system(size: fontSize(for: heading.level),
                                      weight: heading.level <= 2 ? .semibold : .regular))
                        .foregroundStyle(heading.id == activeHeadingID ? .primary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.leading, indentation(for: heading.level))
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(heading.id == activeHeadingID ? Color.accentColor.opacity(0.1) : Color.clear)
                        .padding(.horizontal, -4)
                )
            }
        }
        .listStyle(.sidebar)
    }

    private func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 13
        case 2: return 12.5
        default: return 12
        }
    }

    private func indentation(for level: Int) -> CGFloat {
        return CGFloat(max(0, level - 1)) * 12
    }
}
```

- [ ] **Step 5: Restructure ContentView with NavigationSplitView**

Replace the entire body of `Sources/MDViewerCore/ContentView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var manager: DocumentManager
    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: sidebarBinding) {
            if manager.headings.isEmpty {
                Text("No headings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TOCSidebarView(
                    headings: manager.headings,
                    activeHeadingID: manager.activeHeadingID,
                    onHeadingTap: { headingID in
                        scrollToHeadingAction?(headingID)
                    }
                )
            }
        } detail: {
            VStack(spacing: 0) {
                if manager.tabs.isEmpty {
                    EmptyStateView()
                        .environmentObject(manager)
                } else {
                    HStack(spacing: 0) {
                        TabBarView()
                            .environmentObject(manager)

                        Spacer()

                        Toggle(isOn: $isDarkMode) {
                            Image(systemName: isDarkMode ? "moon.fill" : "sun.max.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.trailing, 12)
                    }
                    .frame(height: 36)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .overlay(Divider(), alignment: .bottom)

                    if let tab = manager.selectedTab {
                        MarkdownWebView(
                            content: tab.content,
                            isDarkMode: isDarkMode,
                            tabID: tab.id,
                            fileDir: tab.fileURL.deletingLastPathComponent().absoluteString,
                            onHeadingsUpdate: { headings in
                                manager.headings = headings
                            },
                            onActiveHeadingChange: { id in
                                manager.activeHeadingID = id
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(isDarkMode ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .navigationTitle(manager.selectedTab?.filename ?? "MDViewer")
    }

    // Bridge to pass scroll action to WebView coordinator
    @State private var scrollToHeadingAction: ((String) -> Void)?

    private var sidebarBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .doubleColumn : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased())
                else { return }

                Task { @MainActor in
                    manager.openFile(url: url)
                }
            }
            handled = true
        }
        return handled
    }
}
```

Wire `scrollToHeadingAction`: The MarkdownWebView struct should accept an additional callback `let onScrollToHeading: ((String) -> Void)?` that ContentView binds to a `@State` variable. When the MarkdownWebView creates its coordinator in `makeCoordinator`, store a reference. In `makeNSView`, set `scrollToHeadingAction` on ContentView's state to the coordinator's `scrollToHeading` method. Alternatively, use `NotificationCenter` to post a `MDViewerScrollToHeading` notification from the TOC tap handler and observe it in the Coordinator — this is simpler and avoids the closure wiring entirely.

- [ ] **Step 6: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open a markdown file with multiple headings (h1, h2, h3). Verify:
1. Sidebar appears with heading hierarchy
2. Clicking a heading scrolls the WebView to it
3. As you scroll, the active heading highlights in the sidebar
4. Sidebar can be collapsed/expanded

- [ ] **Step 7: Commit**

```bash
git add Sources/MDViewerCore/TOCSidebarView.swift Sources/MDViewerCore/DocumentManager.swift Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewerCore/ContentView.swift Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add table of contents sidebar with active heading tracking

NavigationSplitView with auto-generated TOC from document headings.
IntersectionObserver tracks which heading is visible and highlights it
in the sidebar. Click a heading to smooth-scroll to it."
```

---

### Task 10: Document Stats Bar

Show word count and estimated reading time in a subtle status bar below the content.

**Files:**
- Modify: `Sources/MDViewerCore/DocumentManager.swift`
- Modify: `Sources/MDViewerCore/MarkdownWebView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Add stats to template.html**

In the JS section of template.html, add after the heading observer code:

```js
    // Document stats
    function computeStats() {
        const text = document.getElementById('content').textContent || '';
        const words = text.split(/\s+/).filter(w => w.length > 0).length;
        const chars = text.length;
        const readingTime = Math.max(1, Math.ceil(words / 238));
        try {
            window.webkit.messageHandlers.docStats.postMessage({ words: words, chars: chars, readingTime: readingTime });
        } catch(e) {}
    }
```

Call `computeStats()` at the end of `renderMarkdown`, after `setupHeadingObserver()`.

- [ ] **Step 2: Add stats message handler and model**

In `Sources/MDViewerCore/DocumentManager.swift`, add:

```swift
public struct DocumentStats: Equatable {
    public let words: Int
    public let chars: Int
    public let readingTime: Int

    public var description: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let wordStr = formatter.string(from: NSNumber(value: words)) ?? "\(words)"
        return "\(wordStr) words \u{00B7} \(readingTime) min read"
    }
}
```

Add to `DocumentManager`:
```swift
    @Published public var documentStats: DocumentStats?
```

In `Sources/MDViewerCore/MarkdownWebView.swift`, add the `docStats` message handler and callback:

Add to struct:
```swift
    let onStatsUpdate: (DocumentStats) -> Void
```

Register in `makeNSView`:
```swift
        config.userContentController.add(context.coordinator, name: "docStats")
```

Add to Coordinator:
```swift
        var onStatsUpdate: ((DocumentStats) -> Void)?
```

Handle in `userContentController`:
```swift
            } else if message.name == "docStats", let stats = message.body as? [String: Any] {
                let words = stats["words"] as? Int ?? 0
                let chars = stats["chars"] as? Int ?? 0
                let readingTime = stats["readingTime"] as? Int ?? 0
                onStatsUpdate?(DocumentStats(words: words, chars: chars, readingTime: readingTime))
            }
```

Wire in `makeCoordinator`:
```swift
        coordinator.onStatsUpdate = onStatsUpdate
```

- [ ] **Step 3: Display stats in ContentView**

In `Sources/MDViewerCore/ContentView.swift`, below the MarkdownWebView, add the stats bar:

```swift
                    if let tab = manager.selectedTab {
                        MarkdownWebView(
                            // ... existing params ...
                            onStatsUpdate: { stats in
                                manager.documentStats = stats
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Stats bar
                        if let stats = manager.documentStats {
                            HStack {
                                Text(stats.description)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                        }
                    }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open a markdown file. Verify a subtle "1,234 words · 5 min read" bar appears at the bottom.

- [ ] **Step 5: Commit**

```bash
git add Sources/MDViewerCore/DocumentManager.swift Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewerCore/ContentView.swift Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add document stats bar with word count and reading time

Compute word count, character count, and estimated reading time in JS
after rendering. Display in a subtle status bar below the content."
```

---

### Task 11: Find in Page (Cmd+F)

Wire Cmd+F to the native WKWebView find bar.

**Files:**
- Modify: `Sources/MDViewer/MDViewerApp.swift`
- Modify: `Sources/MDViewerCore/MarkdownWebView.swift`

- [ ] **Step 1: Expose find action from MarkdownWebView**

In `Sources/MDViewerCore/MarkdownWebView.swift`, add a method to the Coordinator:

```swift
        func performFind() {
            guard let webView = webView else { return }
            // Use the built-in text finder
            webView.evaluateJavaScript("""
                if (!window.__findActive) {
                    window.__findActive = true;
                }
            """) { _, _ in }
            // WKWebView find via responder chain
            if let window = webView.window {
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: NSTextFinderAction.showFindInterface.rawValue as AnyObject)
            }
        }
```

Actually, a simpler approach: use JavaScript-based find. Add this to the Coordinator:

```swift
        func performFind() {
            guard let webView = webView else { return }
            // Trigger the browser's native Cmd+F find
            // WKWebView doesn't expose performTextFinderAction easily,
            // so we use a JS-based approach or NSResponder chain
            webView.window?.makeFirstResponder(webView)
        }
```

The best approach for WKWebView find-in-page is to make the WebView the first responder when Cmd+F is pressed, then forward the key event. Alternatively, implement a custom find UI.

Given the complexity of WKWebView find integration, a pragmatic approach is to implement a simple JS-based find overlay:

Add to template.html JS section:

```js
    // Find in page
    let findOverlayVisible = false;

    function showFindOverlay() {
        let overlay = document.getElementById('find-overlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = 'find-overlay';
            overlay.innerHTML = `
                <input type="text" id="find-input" placeholder="Find..." autofocus>
                <span id="find-count"></span>
                <button onclick="findNext()">&#9660;</button>
                <button onclick="findPrev()">&#9650;</button>
                <button onclick="closeFindOverlay()">&#10005;</button>
            `;
            document.body.prepend(overlay);
            document.getElementById('find-input').addEventListener('input', performFind);
            document.getElementById('find-input').addEventListener('keydown', (e) => {
                if (e.key === 'Enter') { e.shiftKey ? findPrev() : findNext(); }
                if (e.key === 'Escape') closeFindOverlay();
            });
        }
        overlay.style.display = 'flex';
        document.getElementById('find-input').focus();
        document.getElementById('find-input').select();
    }

    function closeFindOverlay() {
        const overlay = document.getElementById('find-overlay');
        if (overlay) overlay.style.display = 'none';
        clearHighlights();
    }

    let findMatches = [];
    let findIndex = -1;

    function performFind() {
        clearHighlights();
        const query = document.getElementById('find-input').value;
        if (!query) { document.getElementById('find-count').textContent = ''; return; }

        const walker = document.createTreeWalker(
            document.getElementById('content'), NodeFilter.SHOW_TEXT, null
        );
        const textNodes = [];
        while (walker.nextNode()) textNodes.push(walker.currentNode);

        findMatches = [];
        const lowerQuery = query.toLowerCase();
        textNodes.forEach(node => {
            const text = node.textContent.toLowerCase();
            let idx = text.indexOf(lowerQuery);
            while (idx !== -1) {
                findMatches.push({ node, index: idx, length: query.length });
                idx = text.indexOf(lowerQuery, idx + 1);
            }
        });

        findMatches.forEach(m => highlightMatch(m));
        findIndex = findMatches.length > 0 ? 0 : -1;
        updateFindCount();
        if (findIndex >= 0) scrollToMatch(findIndex);
    }

    function highlightMatch(match) {
        const range = document.createRange();
        range.setStart(match.node, match.index);
        range.setEnd(match.node, match.index + match.length);
        const span = document.createElement('mark');
        span.className = 'find-highlight';
        range.surroundContents(span);
    }

    function clearHighlights() {
        document.querySelectorAll('.find-highlight').forEach(el => {
            const parent = el.parentNode;
            parent.replaceChild(document.createTextNode(el.textContent), el);
            parent.normalize();
        });
        findMatches = [];
        findIndex = -1;
    }

    function findNext() {
        if (findMatches.length === 0) return;
        findIndex = (findIndex + 1) % findMatches.length;
        updateFindCount();
        scrollToMatch(findIndex);
    }

    function findPrev() {
        if (findMatches.length === 0) return;
        findIndex = (findIndex - 1 + findMatches.length) % findMatches.length;
        updateFindCount();
        scrollToMatch(findIndex);
    }

    function scrollToMatch(idx) {
        const highlights = document.querySelectorAll('.find-highlight');
        highlights.forEach(h => h.classList.remove('find-active'));
        if (highlights[idx]) {
            highlights[idx].classList.add('find-active');
            highlights[idx].scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
    }

    function updateFindCount() {
        const countEl = document.getElementById('find-count');
        if (findMatches.length === 0) {
            countEl.textContent = 'No results';
        } else {
            countEl.textContent = (findIndex + 1) + ' of ' + findMatches.length;
        }
    }
```

Add CSS for the find overlay:

```css
    #find-overlay {
        display: none;
        position: fixed;
        top: 0;
        right: 16px;
        z-index: 9999;
        background: var(--bg);
        border: 1px solid var(--border);
        border-top: none;
        border-radius: 0 0 8px 8px;
        padding: 8px 12px;
        gap: 6px;
        align-items: center;
        box-shadow: 0 2px 8px rgba(0,0,0,0.15);
        font-size: 13px;
    }
    #find-input {
        border: 1px solid var(--border);
        border-radius: 4px;
        padding: 4px 8px;
        font-size: 13px;
        background: var(--bg);
        color: var(--text);
        outline: none;
        width: 200px;
    }
    #find-input:focus { border-color: var(--link); }
    #find-count { font-size: 11px; color: var(--blockquote-text); min-width: 60px; }
    #find-overlay button {
        background: none;
        border: 1px solid var(--border);
        border-radius: 4px;
        padding: 2px 6px;
        cursor: pointer;
        color: var(--text);
        font-size: 12px;
    }
    #find-overlay button:hover { background: var(--code-bg); }
    .find-highlight { background: #fff3b0; color: #000; border-radius: 2px; }
    body.dark .find-highlight { background: #854d0e; color: #fef3c7; }
    .find-active { background: #f97316 !important; color: #fff !important; }
```

- [ ] **Step 2: Add Cmd+F command in MDViewerApp.swift**

In `Sources/MDViewer/MDViewerApp.swift`, add to the commands:

```swift
            CommandGroup(after: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .init("MDViewerFind"), object: nil)
                }
                .keyboardShortcut("f")
            }
```

- [ ] **Step 3: Handle find notification in MarkdownWebView**

In `Sources/MDViewerCore/MarkdownWebView.swift`, in `makeNSView`, add a notification observer:

```swift
        NotificationCenter.default.addObserver(forName: .init("MDViewerFind"), object: nil, queue: .main) { _ in
            context.coordinator.webView?.evaluateJavaScript("showFindOverlay()") { _, _ in }
        }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open a markdown file. Press Cmd+F. Verify:
1. Find overlay appears at top-right
2. Type a search term — matches highlight in yellow
3. Current match highlights in orange
4. Enter/arrows navigate between matches
5. Escape closes the overlay

- [ ] **Step 5: Commit**

```bash
git add Sources/MDViewer/MDViewerApp.swift Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add find in page with Cmd+F

Custom find overlay with match highlighting, match count, and keyboard
navigation (Enter/Shift+Enter for next/prev, Escape to close)."
```

---

### Task 12: Command Palette (Cmd+K)

A floating fuzzy-search overlay for quick access to headings, files, and actions.

**Files:**
- Create: `Sources/MDViewerCore/CommandPaletteView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewer/MDViewerApp.swift`

- [ ] **Step 1: Create CommandPaletteView.swift**

Create `Sources/MDViewerCore/CommandPaletteView.swift`:

```swift
import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let shortcut: String?
    let action: () -> Void
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let items: [CommandPaletteItem]
    @State private var query = ""
    @State private var selectedIndex = 0

    var filteredItems: [CommandPaletteItem] {
        if query.isEmpty { return items }
        let lower = query.lowercased()
        return items.filter { $0.title.lowercased().contains(lower) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Type a command...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { executeSelected() }
            }
            .padding(12)

            Divider()

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.prefix(10).enumerated()), id: \.element.id) { index, item in
                            HStack {
                                Image(systemName: item.icon)
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .lineLimit(1)
                                Spacer()
                                if let shortcut = item.shortcut {
                                    Text(shortcut)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                item.action()
                                isPresented = false
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
                .onChange(of: selectedIndex) { _, newIndex in
                    let items = filteredItems.prefix(10)
                    if newIndex < items.count {
                        proxy.scrollTo(items[newIndex].id)
                    }
                }
            }
        }
        .frame(width: 500)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(filteredItems.prefix(10).count - 1, selectedIndex + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private func executeSelected() {
        let items = Array(filteredItems.prefix(10))
        guard selectedIndex < items.count else { return }
        items[selectedIndex].action()
        isPresented = false
    }
}
```

- [ ] **Step 2: Add command palette overlay to ContentView**

In `Sources/MDViewerCore/ContentView.swift`, add state and overlay:

Add state:
```swift
    @State private var showCommandPalette = false
```

Wrap the NavigationSplitView in a ZStack and add the overlay:

```swift
    public var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: sidebarBinding) {
                // ... sidebar content ...
            } detail: {
                // ... detail content ...
            }
            .frame(minWidth: 600, minHeight: 400)
            .background(isDarkMode ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor))
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            .navigationTitle(manager.selectedTab?.filename ?? "MDViewer")

            // Command palette overlay
            if showCommandPalette {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showCommandPalette = false }

                VStack {
                    CommandPaletteView(
                        isPresented: $showCommandPalette,
                        items: buildCommandPaletteItems()
                    )
                    .padding(.top, 80)
                    Spacer()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("MDViewerCommandPalette"))) { _ in
            showCommandPalette.toggle()
        }
    }
```

Add the items builder:

```swift
    private func buildCommandPaletteItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // Headings
        for heading in manager.headings {
            items.append(CommandPaletteItem(
                icon: "text.alignleft",
                title: heading.text,
                shortcut: nil,
                action: { scrollToHeadingAction?(heading.id) }
            ))
        }

        // Tab switching
        for tab in manager.tabs {
            if tab.id != manager.selectedTabID {
                items.append(CommandPaletteItem(
                    icon: "square.on.square",
                    title: "Switch to \(tab.filename)",
                    shortcut: nil,
                    action: { manager.selectedTabID = tab.id }
                ))
            }
        }

        // Actions
        items.append(CommandPaletteItem(icon: "doc", title: "Open File...", shortcut: "\u{2318}O",
            action: { manager.openFileDialog() }))
        items.append(CommandPaletteItem(icon: isDarkMode ? "sun.max.fill" : "moon.fill",
            title: isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode", shortcut: nil,
            action: { isDarkMode.toggle() }))
        items.append(CommandPaletteItem(icon: "sidebar.left",
            title: sidebarVisible ? "Hide Sidebar" : "Show Sidebar", shortcut: nil,
            action: { sidebarVisible.toggle() }))

        return items
    }
```

- [ ] **Step 3: Add Cmd+K shortcut in MDViewerApp.swift**

In `Sources/MDViewer/MDViewerApp.swift`, add to commands:

```swift
            CommandGroup(after: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .init("MDViewerFind"), object: nil)
                }
                .keyboardShortcut("f")

                Button("Command Palette") {
                    NotificationCenter.default.post(name: .init("MDViewerCommandPalette"), object: nil)
                }
                .keyboardShortcut("k")
            }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Press Cmd+K. Verify:
1. Palette appears centered near top
2. Typing filters results
3. Arrow keys navigate, Enter executes
4. Escape or clicking outside dismisses
5. Heading items scroll the document
6. Action items work (dark mode toggle, open file, etc.)

- [ ] **Step 5: Commit**

```bash
git add Sources/MDViewerCore/CommandPaletteView.swift Sources/MDViewerCore/ContentView.swift Sources/MDViewer/MDViewerApp.swift
git commit -m "feat: add command palette with Cmd+K

Fuzzy-search overlay for jumping to headings, switching tabs, opening
files, toggling dark mode, and controlling the sidebar."
```

---

## Phase 4: Visual Polish

### Task 13: Typography Overhaul + Multiple Themes

Bundle Inter font, refine typography, and add 4 visual themes (Default, Serif, Ink, Paper) each with light/dark variants.

**Files:**
- Create: `Sources/MDViewerCore/Resources/InterVariable.woff2`
- Modify: `Sources/MDViewerCore/Resources/template.html`
- Modify: `Sources/MDViewerCore/ContentView.swift`
- Modify: `Sources/MDViewerCore/DocumentManager.swift`

- [ ] **Step 1: Download Inter font**

```bash
curl -L -o /tmp/inter.zip "https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
unzip -o /tmp/inter.zip -d /tmp/inter
cp /tmp/inter/InterVariable.woff2 Sources/MDViewerCore/Resources/InterVariable.woff2
ls -la Sources/MDViewerCore/Resources/InterVariable.woff2
rm -rf /tmp/inter /tmp/inter.zip
```

If the exact path within the zip differs, find it with:
```bash
find /tmp/inter -name "InterVariable.woff2"
```

- [ ] **Step 2: Replace the CSS in template.html with themed typography**

In `Sources/MDViewerCore/Resources/template.html`, replace the entire `<style>` block with the following. This includes the font-face declaration, typography refinements, and all 4 themes:

```css
    @font-face {
        font-family: 'Inter';
        src: url('InterVariable.woff2') format('woff2');
        font-weight: 100 900;
        font-display: swap;
    }

    /* === Theme: Default === */
    :root {
        --text: #24292f; --bg: #ffffff; --border: #d0d7de;
        --code-bg: #f6f8fa; --code-border: #d0d7de;
        --link: #0969da;
        --blockquote-border: #d0d7de; --blockquote-text: #656d76;
        --table-border: #d0d7de; --table-alt: #f6f8fa;
        --heading-text: #1f2328;
        --kbd-bg: #f6f8fa; --kbd-border: #d0d7de;
        --scrollbar-thumb: #c1c1c1; --scrollbar-thumb-hover: #a8a8a8;
        --body-font: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
        --heading-font: var(--body-font);
        --body-line-height: 1.6;
    }
    body.dark {
        --text: #e6edf3; --bg: #0d1117; --border: #30363d;
        --code-bg: #161b22; --code-border: #30363d;
        --link: #58a6ff;
        --blockquote-border: #30363d; --blockquote-text: #8b949e;
        --table-border: #30363d; --table-alt: #161b22;
        --heading-text: #f0f6fc;
        --kbd-bg: #161b22; --kbd-border: #30363d;
        --scrollbar-thumb: #484f58; --scrollbar-thumb-hover: #6e7681;
    }

    /* === Theme: Serif === */
    body.theme-serif {
        --bg: #faf8f5; --text: #2c2c2c; --heading-text: #1a1a1a;
        --code-bg: #f0ece6; --code-border: #d9d1c7; --border: #d9d1c7;
        --link: #8b4513; --blockquote-border: #d9d1c7; --blockquote-text: #6b6155;
        --table-border: #d9d1c7; --table-alt: #f0ece6;
        --kbd-bg: #f0ece6; --kbd-border: #d9d1c7;
        --scrollbar-thumb: #c4b9ac; --scrollbar-thumb-hover: #a89a8c;
        --body-font: Georgia, "Times New Roman", Charter, serif;
        --heading-font: Georgia, "Times New Roman", Charter, serif;
        --body-line-height: 1.7;
    }
    body.theme-serif.dark {
        --bg: #1a1a1a; --text: #d4cfc8; --heading-text: #e8e2da;
        --code-bg: #252220; --code-border: #3d3733; --border: #3d3733;
        --link: #d4a574; --blockquote-border: #3d3733; --blockquote-text: #8c8278;
        --table-border: #3d3733; --table-alt: #252220;
        --kbd-bg: #252220; --kbd-border: #3d3733;
        --scrollbar-thumb: #4a423b; --scrollbar-thumb-hover: #645a50;
    }

    /* === Theme: Ink === */
    body.theme-ink {
        --bg: #0d1117; --text: #e6edf3; --heading-text: #f0f6fc;
        --code-bg: #161b22; --code-border: #30363d; --border: #30363d;
        --link: #58a6ff; --blockquote-border: #30363d; --blockquote-text: #8b949e;
        --table-border: #30363d; --table-alt: #161b22;
        --kbd-bg: #161b22; --kbd-border: #30363d;
        --scrollbar-thumb: #484f58; --scrollbar-thumb-hover: #6e7681;
        --body-font: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        --heading-font: var(--body-font);
        --body-line-height: 1.6;
    }
    body.theme-ink.dark {
        --bg: #000000; --text: #e0e0e0; --heading-text: #ffffff;
        --code-bg: #0d0d0d; --code-border: #222; --border: #222;
        --link: #6cb6ff; --blockquote-border: #222; --blockquote-text: #777;
        --table-border: #222; --table-alt: #0d0d0d;
        --kbd-bg: #0d0d0d; --kbd-border: #222;
        --scrollbar-thumb: #333; --scrollbar-thumb-hover: #555;
    }

    /* === Theme: Paper === */
    body.theme-paper {
        --bg: #f5f0e8; --text: #3b3530; --heading-text: #2a2520;
        --code-bg: #ebe5db; --code-border: #d4cdc2; --border: #d4cdc2;
        --link: #6b5c3e; --blockquote-border: #d4cdc2; --blockquote-text: #7a7168;
        --table-border: #d4cdc2; --table-alt: #ebe5db;
        --kbd-bg: #ebe5db; --kbd-border: #d4cdc2;
        --scrollbar-thumb: #c4bdb2; --scrollbar-thumb-hover: #a8a094;
        --body-font: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        --heading-font: var(--body-font);
        --body-line-height: 1.65;
    }
    body.theme-paper.dark {
        --bg: #2a2520; --text: #d4cfc8; --heading-text: #e8e2da;
        --code-bg: #342e28; --code-border: #4a423b; --border: #4a423b;
        --link: #c4a878; --blockquote-border: #4a423b; --blockquote-text: #8c8278;
        --table-border: #4a423b; --table-alt: #342e28;
        --kbd-bg: #342e28; --kbd-border: #4a423b;
        --scrollbar-thumb: #4a423b; --scrollbar-thumb-hover: #645a50;
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    html {
        font-size: clamp(1rem, 0.95rem + 0.25vw, 1.125rem);
        -webkit-text-size-adjust: 100%;
    }

    body {
        font-family: var(--body-font);
        font-size: 1rem;
        line-height: var(--body-line-height);
        color: var(--text);
        background: var(--bg);
        max-width: 68ch;
        margin: 0 auto;
        padding: 32px 40px 80px;
        -webkit-font-smoothing: antialiased;
        -moz-osx-font-smoothing: grayscale;
        word-wrap: break-word;
        transition: background-color 0.3s ease, color 0.3s ease;
    }

    h1, h2, h3, h4, h5, h6 {
        font-family: var(--heading-font);
        color: var(--heading-text);
        font-weight: 600;
        line-height: 1.25;
        letter-spacing: -0.02em;
        margin-bottom: 0.625em;
    }
    h1, h2 { margin-top: 2em; }
    h3, h4, h5, h6 { margin-top: 1.5em; }

    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: 0.875em; }
    h6 { font-size: 0.85em; color: var(--blockquote-text); }

    h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }

    p { margin-bottom: 1.25em; }

    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 600; }

    img { max-width: 100%; height: auto; border-radius: 6px; }

    hr { border: none; border-top: 2px solid var(--border); margin: 1.5em 0; }

    code {
        font-family: "SF Mono", "Fira Code", "Fira Mono", Menlo, Consolas, monospace;
        font-size: 0.85em;
        background: var(--code-bg);
        padding: 0.2em 0.4em;
        border-radius: 6px;
        border: 1px solid var(--code-border);
        transition: background-color 0.3s ease;
    }

    pre {
        background: var(--code-bg);
        border: 1px solid var(--code-border);
        border-radius: 8px;
        padding: 16px;
        overflow-x: auto;
        margin-bottom: 1em;
        line-height: 1.5;
        transition: background-color 0.3s ease, border-color 0.3s ease;
    }
    pre code { background: none; border: none; padding: 0; font-size: 0.85em; border-radius: 0; }

    blockquote {
        border-left: 4px solid var(--blockquote-border);
        padding: 0.25em 1em;
        margin-bottom: 1em;
        color: var(--blockquote-text);
        transition: border-color 0.3s ease, color 0.3s ease;
    }
    blockquote p:last-child { margin-bottom: 0; }
    blockquote blockquote { margin-top: 0.5em; }

    ul, ol { padding-left: 2em; margin-bottom: 1em; }
    li { margin-bottom: 0.25em; }
    li > p { margin-bottom: 0.5em; }
    li > ul, li > ol { margin-bottom: 0; margin-top: 0.25em; }

    ul.contains-task-list { list-style: none; padding-left: 1.5em; }
    li.task-list-item { position: relative; }
    li.task-list-item input[type="checkbox"] {
        margin-right: 0.5em; margin-left: -1.3em; position: relative; top: 1px;
    }

    table { width: 100%; border-collapse: collapse; margin-bottom: 1em; overflow-x: auto; display: block; }
    th, td { border: 1px solid var(--table-border); padding: 8px 13px; text-align: left; }
    th { font-weight: 600; background: var(--code-bg); }
    tr:nth-child(2n) { background: var(--table-alt); }

    kbd {
        display: inline-block; padding: 3px 5px; font-size: 0.75em;
        font-family: "SF Mono", Menlo, Consolas, monospace; line-height: 1;
        color: var(--text); background: var(--kbd-bg); border: 1px solid var(--kbd-border);
        border-radius: 6px; box-shadow: inset 0 -1px 0 var(--kbd-border);
    }

    .mermaid {
        margin: 1.5em -40px; padding: 1.5em 2em;
        background: var(--code-bg); border-top: 1px solid var(--code-border);
        border-bottom: 1px solid var(--code-border); overflow-x: auto; text-align: center;
    }
    .mermaid svg { height: auto; max-width: none; }

    dl { margin-bottom: 1em; }
    dt { font-weight: 600; margin-top: 0.5em; }
    dd { margin-left: 2em; }

    .footnotes { font-size: 0.85em; margin-top: 2em; border-top: 1px solid var(--border); padding-top: 1em; }
    .footnotes ol { padding-left: 1.5em; }

    ::-webkit-scrollbar { width: 6px; height: 6px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--scrollbar-thumb); border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: var(--scrollbar-thumb-hover); }
```

- [ ] **Step 3: Add setTheme JS function**

In the JS section of template.html, add:

```js
    function setTheme(name) {
        document.body.className = document.body.className
            .replace(/theme-\w+/g, '')
            .trim();
        if (name && name !== 'default') {
            document.body.classList.add('theme-' + name);
        }
        // Re-apply dark mode class if needed
        if (currentDarkMode) {
            document.body.classList.add('dark');
        }
    }
```

- [ ] **Step 4: Add theme selection to Swift side**

In `Sources/MDViewerCore/MarkdownWebView.swift`, add a `theme` parameter:

```swift
struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let tabID: UUID
    let fileDir: String
    let theme: String
    // ... callbacks ...
```

In the Coordinator, add theme tracking and application:

```swift
        private var lastTheme: String?

        func applyTheme(_ theme: String) {
            guard isLoaded, let webView = webView else { return }
            if theme == lastTheme { return }
            lastTheme = theme
            let escaped = theme.replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("setTheme('\(escaped)')") { _, _ in }
        }
```

In `updateNSView`, call `applyTheme`:

```swift
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.renderContent(content, tabID: tabID, fileDir: fileDir)
        context.coordinator.applyTheme(theme)
        context.coordinator.applyDarkMode(isDarkMode)
    }
```

In `Sources/MDViewerCore/ContentView.swift`, add theme AppStorage and pass it:

```swift
    @AppStorage("appTheme") private var appTheme = "default"
```

Pass to MarkdownWebView:
```swift
    MarkdownWebView(
        content: tab.content,
        isDarkMode: isDarkMode,
        tabID: tab.id,
        fileDir: tab.fileURL.deletingLastPathComponent().absoluteString,
        theme: appTheme,
        // ... callbacks ...
    )
```

Add theme items to the command palette builder:

```swift
        // Themes
        for theme in ["default", "serif", "ink", "paper"] {
            let name = theme.capitalized
            items.append(CommandPaletteItem(
                icon: "paintpalette",
                title: "Theme: \(name)",
                shortcut: nil,
                action: { appTheme = theme }
            ))
        }
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open a markdown file. Press Cmd+K, type "theme", select "Serif". Verify:
1. Font changes to Georgia
2. Background warms up
3. Toggle dark mode — serif dark variant applies
4. Switch to "Ink" — high contrast dark theme
5. Switch to "Paper" — warm cream tones

- [ ] **Step 6: Commit**

```bash
git add Sources/MDViewerCore/Resources/InterVariable.woff2 Sources/MDViewerCore/Resources/template.html Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewerCore/ContentView.swift
git commit -m "feat: typography overhaul with Inter font and 4 visual themes

Bundle Inter variable font. Fluid font sizing with clamp(). Reading
width set to 68ch. Four themes: Default, Serif (Georgia), Ink (high
contrast dark), Paper (warm cream). Each with light/dark variants.
Theme selection via command palette, persisted in AppStorage."
```

---

### Task 14: Tab Bar Polish (Vibrancy + Animated Selection)

Add translucent material background and smooth sliding tab indicator.

**Files:**
- Modify: `Sources/MDViewerCore/TabBarView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`

- [ ] **Step 1: Add matchedGeometryEffect to TabBarView**

Replace `Sources/MDViewerCore/TabBarView.swift`:

```swift
import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var manager: DocumentManager
    @Namespace private var tabNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(manager.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        isSelected: tab.id == manager.selectedTabID,
                        namespace: tabNamespace
                    )
                }
            }
            .padding(.leading, 1)
        }
    }
}

struct TabItemView: View {
    let tab: DocumentTab
    let isSelected: Bool
    var namespace: Namespace.ID
    @EnvironmentObject var manager: DocumentManager
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(tab.filename)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Button(action: { manager.closeTab(id: tab.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .matchedGeometryEffect(id: "activeTab", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        )
        .animation(.spring(.snappy), value: isSelected)
        .onTapGesture {
            manager.selectedTabID = tab.id
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
```

- [ ] **Step 2: Add vibrancy to tab bar in ContentView**

In `Sources/MDViewerCore/ContentView.swift`, replace the tab bar background:

Change:
```swift
.background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
```
To:
```swift
.background(.ultraThinMaterial)
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test: Open multiple tabs. Switch between them. Verify:
1. The selected tab highlight slides smoothly between tabs (spring animation)
2. Tab bar has a translucent/frosted glass appearance
3. Close button fades in on hover

- [ ] **Step 4: Commit**

```bash
git add Sources/MDViewerCore/TabBarView.swift Sources/MDViewerCore/ContentView.swift
git commit -m "polish: add vibrancy and animated tab indicator

Tab bar uses ultraThinMaterial for native translucency. Selected tab
highlight slides between tabs using matchedGeometryEffect with spring
animation. Close button fades in on hover."
```

---

### Task 15: Content Transitions + Empty State Animation + Scrollbar

Add smooth transitions for dark mode, tab switching, and the empty state.

**Files:**
- Modify: `Sources/MDViewerCore/EmptyStateView.swift`
- Modify: `Sources/MDViewerCore/ContentView.swift`

- [ ] **Step 1: Add entrance animation to EmptyStateView**

Replace `Sources/MDViewerCore/EmptyStateView.swift`:

```swift
import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var manager: DocumentManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.quaternary)

            VStack(spacing: 8) {
                Text("MDViewer")
                    .font(.title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text("Open a Markdown file to get started")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }

            Button(action: { manager.openFileDialog() }) {
                Label("Open File", systemImage: "folder")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text("or drag and drop .md files here")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}
```

- [ ] **Step 2: Add content animation wrapper in ContentView**

In `Sources/MDViewerCore/ContentView.swift`, wrap the content switching in an animation:

Where the empty state / content toggle is, ensure it's wrapped:

```swift
            VStack(spacing: 0) {
                if manager.tabs.isEmpty {
                    EmptyStateView()
                        .environmentObject(manager)
                } else {
                    // ... tab bar + webview ...
                }
            }
            .animation(.spring(.smooth), value: manager.tabs.isEmpty)
```

Note: The CSS `transition` properties for dark mode were already added in Task 13 (the `body` and `code`/`pre`/`blockquote` rules include `transition: background-color 0.3s ease, color 0.3s ease`). Scrollbar CSS was also refined in Task 13 (6px width, 3px radius).

- [ ] **Step 3: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test:
1. Launch with no files — empty state appears with gentle scale+fade animation
2. Open a file — empty state animates out, content animates in
3. Close all tabs — empty state animates back in
4. Toggle dark mode — background and text colors transition smoothly (0.3s)

- [ ] **Step 4: Commit**

```bash
git add Sources/MDViewerCore/EmptyStateView.swift Sources/MDViewerCore/ContentView.swift
git commit -m "polish: add content transitions and empty state animation

Empty state enters with scale+opacity spring animation. Dark mode
toggles use CSS transitions for smooth color shifts."
```

---

## Phase 5: Export & System Integration

### Task 16: PDF Export + Copy as Rich HTML

Add PDF export via Cmd+Shift+E and rich HTML copy.

**Files:**
- Modify: `Sources/MDViewerCore/MarkdownWebView.swift`
- Modify: `Sources/MDViewer/MDViewerApp.swift`
- Modify: `Sources/MDViewerCore/Resources/template.html`

- [ ] **Step 1: Add print CSS to template.html**

In the `<style>` section of template.html, add at the end:

```css
    @media print {
        body {
            max-width: none;
            padding: 0;
            color: #000 !important;
            background: #fff !important;
        }
        pre, blockquote, table, .mermaid {
            page-break-inside: avoid;
        }
        a[href]::after {
            content: " (" attr(href) ")";
            font-size: 0.8em;
            color: #666;
        }
        .copy-btn, #find-overlay { display: none !important; }
        h1, h2, h3, h4 { page-break-after: avoid; }
    }
```

- [ ] **Step 2: Add export methods to MarkdownWebView Coordinator**

In `Sources/MDViewerCore/MarkdownWebView.swift`, add to the Coordinator:

```swift
        func exportPDF(suggestedName: String) {
            guard let webView = webView else { return }

            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89) // A4

            webView.createPDF(configuration: config) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let data):
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.pdf]
                        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: ".md", with: ".pdf")
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            try? data.write(to: url)
                        }
                    case .failure(let error):
                        print("PDF export error: \(error)")
                    }
                }
            }
        }

        func copyAsHTML() {
            guard let webView = webView else { return }
            webView.evaluateJavaScript("document.getElementById('content').innerHTML") { result, _ in
                guard let html = result as? String else { return }

                let fullHTML = """
                <!DOCTYPE html>
                <html><head><meta charset="utf-8"></head>
                <body>\(html)</body></html>
                """

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(fullHTML, forType: .html)
                pasteboard.setString(html, forType: .string)
            }
        }
```

Note: You'll need `import AppKit` in MarkdownWebView.swift (for NSSavePanel, NSPasteboard).

- [ ] **Step 3: Add menu commands**

In `Sources/MDViewer/MDViewerApp.swift`, add export commands:

```swift
            CommandGroup(after: .importExport) {
                Button("Export as PDF...") {
                    NotificationCenter.default.post(name: .init("MDViewerExportPDF"), object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(manager.tabs.isEmpty)

                Button("Copy as HTML") {
                    NotificationCenter.default.post(name: .init("MDViewerCopyHTML"), object: nil)
                }
                .disabled(manager.tabs.isEmpty)
            }
```

- [ ] **Step 4: Handle export notifications in MarkdownWebView**

In `Sources/MDViewerCore/MarkdownWebView.swift`, in `makeNSView`, add observers:

```swift
        NotificationCenter.default.addObserver(forName: .init("MDViewerExportPDF"), object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            let name = /* get filename from context somehow */ "document"
            coordinator?.exportPDF(suggestedName: name)
        }

        NotificationCenter.default.addObserver(forName: .init("MDViewerCopyHTML"), object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.copyAsHTML()
        }
```

Add a `filename` property to the MarkdownWebView struct: `let filename: String`. Pass it from ContentView: `filename: tab.filename`. Use it in the export notification observer to call `coordinator?.exportPDF(suggestedName: filename)`.

- [ ] **Step 5: Add export actions to command palette**

In `ContentView.swift`, in `buildCommandPaletteItems`:

```swift
        items.append(CommandPaletteItem(icon: "arrow.down.doc", title: "Export as PDF...", shortcut: "\u{21E7}\u{2318}E",
            action: { NotificationCenter.default.post(name: .init("MDViewerExportPDF"), object: nil) }))
        items.append(CommandPaletteItem(icon: "doc.richtext", title: "Copy as HTML", shortcut: nil,
            action: { NotificationCenter.default.post(name: .init("MDViewerCopyHTML"), object: nil) }))
```

- [ ] **Step 6: Build and verify**

Run: `cd /Users/vivek/MDViewer && swift build 2>&1 | tail -5`

Test:
1. Open a markdown file. Press Cmd+Shift+E. Verify save panel appears, saves a readable PDF.
2. Use "Copy as HTML" from the command palette. Paste into a rich text app — verify formatted content arrives.

- [ ] **Step 7: Commit**

```bash
git add Sources/MDViewerCore/MarkdownWebView.swift Sources/MDViewer/MDViewerApp.swift Sources/MDViewerCore/ContentView.swift Sources/MDViewerCore/Resources/template.html
git commit -m "feat: add PDF export and copy as rich HTML

Export rendered markdown as A4 PDF via Cmd+Shift+E using WKWebView's
native createPDF. Copy as HTML puts rendered content on the pasteboard
for pasting into rich text apps. Both accessible from menu and command
palette."
```

---

### Task 17: Xcode Project Migration + Quick Look Extension

Migrate from SwiftPM to an Xcode project and add a Quick Look preview extension for .md files.

**Files:**
- Create: `MDViewer.xcodeproj/` (Xcode project)
- Create: `MDViewerQuickLook/PreviewProvider.swift`
- Create: `MDViewerQuickLook/Info.plist`
- Remove: `Package.swift` (or keep for reference)
- Remove: `scripts/bundle.sh` (replaced by Xcode build)

- [ ] **Step 1: Create the Xcode project**

This step requires Xcode and is best done interactively. Create the project with:

1. Open Xcode → File → New → Project → macOS → App
2. Product Name: MDViewer, Bundle ID: com.mdviewer.app
3. Interface: SwiftUI, Language: Swift
4. Save in the MDViewer repo root (alongside existing files)

Then add a Quick Look Extension target:
1. File → New → Target → macOS → Quick Look Preview Extension
2. Product Name: MDViewerQuickLook
3. Embed in: MDViewer

Alternatively, use `xcodegen` if installed:

Create `project.yml`:

```yaml
name: MDViewer
options:
  bundleIdPrefix: com.mdviewer
  deploymentTarget:
    macOS: "14.0"
settings:
  SWIFT_VERSION: "6.0"
  STRICT_CONCURRENCY: complete
targets:
  MDViewer:
    type: application
    platform: macOS
    sources:
      - Sources/MDViewer
      - Sources/MDViewerCore
    resources:
      - Sources/MDViewerCore/Resources
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.mdviewer.app
      INFOPLIST_FILE: Sources/MDViewer/Info.plist
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    dependencies:
      - target: MDViewerQuickLook
        embed: true
  MDViewerQuickLook:
    type: appex
    platform: macOS
    sources:
      - MDViewerQuickLook
    resources:
      - Sources/MDViewerCore/Resources/markdown-it.min.js
      - Sources/MDViewerCore/Resources/highlight.min.js
      - Sources/MDViewerCore/Resources/hljs-github.css
      - Sources/MDViewerCore/Resources/hljs-github-dark.css
      - Sources/MDViewerCore/Resources/InterVariable.woff2
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.mdviewer.app.quicklook
      INFOPLIST_FILE: MDViewerQuickLook/Info.plist
```

```bash
# If xcodegen is installed:
cd /Users/vivek/MDViewer && xcodegen generate
```

If neither approach works easily, the implementing agent should create the Xcode project manually and configure targets.

- [ ] **Step 2: Create Quick Look PreviewProvider**

Create `MDViewerQuickLook/PreviewProvider.swift`:

```swift
import QuickLookUI
import Foundation
import JavaScriptCore

class PreviewProvider: QLPreviewProvider {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let markdownContent = try String(contentsOf: request.fileURL, encoding: .utf8)
        let htmlContent = renderMarkdown(markdownContent)

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in
            return htmlContent.data(using: .utf8)!
        }
    }

    private func renderMarkdown(_ markdown: String) -> String {
        // Use JavaScriptCore to run markdown-it
        let context = JSContext()!

        // Load markdown-it
        if let markdownItURL = Bundle.main.url(forResource: "markdown-it.min", withExtension: "js"),
           let markdownItJS = try? String(contentsOf: markdownItURL) {
            context.evaluateScript(markdownItJS)
        }

        // Load highlight.js
        if let hljsURL = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
           let hljsJS = try? String(contentsOf: hljsURL) {
            context.evaluateScript(hljsJS)
        }

        // Initialize and render
        context.evaluateScript("""
            var md = markdownit({
                html: true,
                linkify: true,
                typographer: true,
                highlight: function(str, lang) {
                    if (lang && hljs.getLanguage(lang)) {
                        try { return hljs.highlight(str, { language: lang }).value; } catch(_) {}
                    }
                    return '';
                }
            });
        """)

        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let result = context.evaluateScript("md.render(`\(escaped)`)")
        let renderedHTML = result?.toString() ?? "<p>Failed to render markdown</p>"

        return wrapInHTML(renderedHTML)
    }

    private func wrapInHTML(_ body: String) -> String {
        // Inline a minimal version of the app's CSS
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <style>
            @font-face {
                font-family: 'Inter';
                src: url('InterVariable.woff2') format('woff2');
                font-weight: 100 900;
                font-display: swap;
            }
            body {
                font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 16px; line-height: 1.6; color: #24292f;
                max-width: 68ch; margin: 0 auto; padding: 32px 40px;
                -webkit-font-smoothing: antialiased;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #e6edf3; background: #0d1117; }
                code, pre { background: #161b22; border-color: #30363d; }
                a { color: #58a6ff; }
                h1, h2, h3, h4, h5, h6 { color: #f0f6fc; }
                h1, h2 { border-bottom-color: #30363d; }
                blockquote { border-left-color: #30363d; color: #8b949e; }
                th { background: #161b22; }
                tr:nth-child(2n) { background: #161b22; }
                th, td { border-color: #30363d; }
            }
            h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; letter-spacing: -0.02em; color: #1f2328; }
            h1, h2 { margin-top: 2em; }
            h3, h4, h5, h6 { margin-top: 1.5em; }
            h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
            h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
            h3 { font-size: 1.25em; }
            p { margin-bottom: 1.25em; }
            a { color: #0969da; text-decoration: none; }
            code { font-family: "SF Mono", Menlo, monospace; font-size: 0.85em; background: #f6f8fa; padding: 0.2em 0.4em; border-radius: 6px; border: 1px solid #d0d7de; }
            pre { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 8px; padding: 16px; overflow-x: auto; }
            pre code { background: none; border: none; padding: 0; }
            blockquote { border-left: 4px solid #d0d7de; padding: 0.25em 1em; color: #656d76; }
            img { max-width: 100%; height: auto; border-radius: 6px; }
            table { width: 100%; border-collapse: collapse; margin-bottom: 1em; }
            th, td { border: 1px solid #d0d7de; padding: 8px 13px; }
            th { font-weight: 600; background: #f6f8fa; }
            tr:nth-child(2n) { background: #f6f8fa; }
            ul, ol { padding-left: 2em; margin-bottom: 1em; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
```

- [ ] **Step 3: Create Quick Look Info.plist**

Create `MDViewerQuickLook/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.markdown</string>
            </array>
            <key>QLSupportsSearchableItems</key>
            <true/>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).PreviewProvider</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 4: Build and verify**

Build the project in Xcode:
```bash
cd /Users/vivek/MDViewer
xcodebuild -project MDViewer.xcodeproj -scheme MDViewer build 2>&1 | tail -10
```

Or open in Xcode and build (Cmd+B).

Test Quick Look: In Finder, navigate to a .md file and press spacebar. Verify a rendered preview appears with syntax highlighting and proper typography.

Note: Quick Look extensions need the app to be installed in /Applications or run from Xcode to register with the system. You may need to run `qlmanage -r` to reset the Quick Look cache.

- [ ] **Step 5: Commit**

```bash
git add MDViewer.xcodeproj/ MDViewerQuickLook/ project.yml
git commit -m "feat: migrate to Xcode project and add Quick Look extension

Move from SwiftPM to Xcode project for app extension support. Add
Quick Look preview extension that renders .md files in Finder using
JavaScriptCore + markdown-it + highlight.js with the Default theme."
```

---

## Verification Checklist

After all tasks are complete, verify the full experience end-to-end:

- [ ] Launch app — fast load (no mermaid delay)
- [ ] Open a code-heavy .md — syntax highlighting works
- [ ] Open a file with math — KaTeX renders after brief lazy load
- [ ] Open a file with mermaid — diagrams render after brief lazy load
- [ ] Open a file with GitHub alerts — styled callout boxes appear
- [ ] Open a file with relative images — images load correctly
- [ ] Switch between tabs — instant, no flash, scroll positions preserved
- [ ] Edit a file externally — content updates smoothly (morphdom), scroll preserved
- [ ] Sidebar TOC — headings listed, click scrolls, active heading highlighted
- [ ] Cmd+F — find overlay works, highlights matches
- [ ] Cmd+K — command palette works, fuzzy search, actions execute
- [ ] Dark mode toggle — smooth CSS transition, all themes adapt
- [ ] Theme switching — all 4 themes work in light and dark
- [ ] Tab bar — translucent, animated selection indicator
- [ ] Empty state — gentle entrance animation
- [ ] Cmd+Shift+E — PDF exports correctly
- [ ] Copy as HTML — pastes formatted content
- [ ] Quick Look — .md preview in Finder (requires Xcode build + install)
- [ ] Word count / reading time — displayed in status bar
