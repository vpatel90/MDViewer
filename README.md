# MDViewer

A native macOS markdown viewer with beautiful rendering and Mermaid diagram support. Open multiple documents in tabs.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Beautiful markdown rendering** — GitHub-flavored styling with clean typography
- **Mermaid diagrams** — flowcharts, sequence diagrams, gantt charts, and more rendered inline
- **Tabbed interface** — open multiple documents in tabs
- **Dark mode** — toggle between light and dark themes (mermaid diagrams re-render with matching colors)
- **File watching** — auto-refreshes when files are edited externally
- **Session persistence** — remembers open tabs and selected document across restarts
- **Drag and drop** — drop `.md` files onto the window to open them
- **File association** — set as default viewer for `.md` files

## Install

### Build from source

Requires macOS 14+ and Swift 5.9+ (Xcode Command Line Tools is sufficient, full Xcode not required).

```bash
git clone https://github.com/vpatel90/MDViewer.git
cd MDViewer
./scripts/bundle.sh
cp -r MDViewer.app /Applications/
```

### Run without installing

```bash
cd MDViewer
swift run MDViewer
```

## Usage

- **Open files:** `Cmd+O` or drag and drop `.md` files onto the window
- **Close tab:** `Cmd+W`
- **Switch tabs:** `Cmd+]` / `Cmd+[`
- **Dark mode:** Toggle switch in the top-right corner
- **From terminal:** `open -a MDViewer file.md`

## Architecture

SwiftUI app shell with WKWebView rendering engine. Markdown is parsed by [markdown-it](https://github.com/markdown-it/markdown-it) and diagrams are rendered by [mermaid.js](https://github.com/mermaid-js/mermaid) — both bundled with the app (no internet required).

## License

MIT
