# MDViewer

A native macOS markdown viewer built for daily use. Beautiful typography, syntax highlighting, math rendering, diagrams, and a polished UI — all in a fast, lightweight app.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Rendering
- **Syntax highlighting** — language-aware code coloring via [highlight.js](https://highlightjs.org/) with copy-to-clipboard buttons
- **Math rendering** — `$inline$` and `$$display$$` math via [KaTeX](https://katex.org/) (lazy-loaded)
- **Mermaid diagrams** — flowcharts, sequence diagrams, gantt charts, and more (lazy-loaded)
- **GitHub-style alerts** — `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`
- **Extended markdown** — footnotes, emoji shortcodes, ==highlights==, subscript, superscript
- **Relative images** — `![](./images/photo.png)` resolves correctly against the file's directory

### UI & Navigation
- **Tabbed interface** — open multiple documents in tabs
- **Table of contents sidebar** — auto-generated from headings, highlights current section as you scroll
- **Command palette** (`Cmd+K`) — fuzzy search for headings, tabs, themes, and actions
- **Find in page** (`Cmd+F`) — match highlighting with keyboard navigation
- **Document stats** — word count and estimated reading time

### Visual Design
- **4 themes** — Default, Serif, Ink, Paper — each with light and dark variants
- **Inter font** — bundled variable font with fluid sizing
- **Vibrant tab bar** — translucent material with smooth animated tab indicator
- **Dark mode** — toggle with smooth CSS transitions; mermaid diagrams re-render with matching colors

### Performance
- **Persistent WebView** — single WKWebView reused across tabs (no reload on switch)
- **Scroll position memory** — remembers and restores per-tab scroll position
- **Incremental updates** — [morphdom](https://github.com/patrick-steele-idem/morphdom) diffs the DOM on file changes instead of full re-render
- **Lazy loading** — mermaid (2.9MB) and KaTeX (350KB) only load when needed

### Export & Integration
- **PDF export** (`Cmd+Shift+E`) — A4 PDF with print-optimized CSS
- **Copy as HTML** — paste rendered markdown into other apps
- **File watching** — auto-refreshes when files are edited externally
- **Session persistence** — remembers open tabs and selected document across restarts
- **Drag and drop** — drop `.md` files onto the window to open them
- **File association** — register as viewer for `.md` files
- **Quick Look extension** — preview `.md` files in Finder (requires Xcode build)

## Install

### Build from source

Requires macOS 14+ and Swift 6 (Xcode Command Line Tools is sufficient).

```bash
git clone https://github.com/vpatel90/MDViewer.git
cd MDViewer
./scripts/bundle.sh
cp -r MDViewer.app /Applications/
```

### Run without installing

```bash
swift run MDViewer
```

### Quick Look extension (optional)

Requires [xcodegen](https://github.com/yonaskolb/XcodeGen) and Xcode:

```bash
brew install xcodegen
xcodegen generate
open MDViewer.xcodeproj
# Build and run from Xcode
```

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Open file | `Cmd+O` |
| Close tab | `Cmd+W` |
| Next/previous tab | `Cmd+]` / `Cmd+[` |
| Jump to tab 1-9 | `Cmd+1` ... `Cmd+9` |
| Command palette | `Cmd+K` |
| Find in page | `Cmd+F` |
| Export as PDF | `Cmd+Shift+E` |
| Toggle dark mode | Toggle in tab bar |
| Toggle sidebar | Button in tab bar |
| From terminal | `open -a MDViewer file.md` |

## Architecture

SwiftUI app shell with a persistent WKWebView rendering engine. Markdown is parsed by [markdown-it](https://github.com/markdown-it/markdown-it) with plugins for footnotes, emoji, highlights, sub/superscript, and GitHub alerts. Code is highlighted by [highlight.js](https://highlightjs.org/), math by [KaTeX](https://katex.org/), diagrams by [mermaid.js](https://github.com/mermaid-js/mermaid). DOM updates use [morphdom](https://github.com/patrick-steele-idem/morphdom) for minimal diffing. Typography uses the [Inter](https://rsms.me/inter/) variable font. Everything is bundled — no internet required.

## License

MIT
