import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let tabID: UUID
    let fileDir: String
    var onHeadingsUpdate: (([HeadingItem]) -> Void)?
    var onActiveHeadingChange: ((String?) -> Void)?
    var onStatsUpdate: ((DocumentStats) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(context.coordinator, name: "tocUpdate")
        config.userContentController.add(context.coordinator, name: "activeHeading")
        config.userContentController.add(context.coordinator, name: "docStats")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingContent = (content, tabID, fileDir)
        context.coordinator.pendingDarkMode = isDarkMode

        if let templateURL = Bundle.module.url(
            forResource: "template",
            withExtension: "html",
            subdirectory: "Resources"
        ) {
            webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        NotificationCenter.default.addObserver(forName: .init("MDViewerScrollToHeading"), object: nil, queue: .main) { [weak coordinator = context.coordinator] notification in
            if let headingID = notification.object as? String {
                MainActor.assumeIsolated {
                    coordinator?.scrollToHeading(headingID)
                }
            }
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.renderContent(content, tabID: tabID, fileDir: fileDir)
        context.coordinator.applyDarkMode(isDarkMode)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onHeadingsUpdate = onHeadingsUpdate
        coordinator.onActiveHeadingChange = onActiveHeadingChange
        coordinator.onStatsUpdate = onStatsUpdate
        return coordinator
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var pendingContent: (String, UUID, String)?
        var pendingDarkMode: Bool?
        var isLoaded = false
        var onHeadingsUpdate: (([HeadingItem]) -> Void)?
        var onActiveHeadingChange: ((String?) -> Void)?
        var onStatsUpdate: ((DocumentStats) -> Void)?
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
            if let (content, tabID, fileDir) = pendingContent {
                pendingContent = nil
                renderContent(content, tabID: tabID, fileDir: fileDir)
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

        func renderContent(_ content: String, tabID: UUID, fileDir: String = "") {
            guard isLoaded, let webView = webView else {
                pendingContent = (content, tabID, fileDir)
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

            let escapedDir = fileDir
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            webView.evaluateJavaScript("renderMarkdown(\(jsonString), '\(escapedDir)')") { [weak self] _, error in
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "tocUpdate", let headings = message.body as? [[String: Any]] {
                let items = headings.compactMap { dict -> HeadingItem? in
                    guard let id = dict["id"] as? String,
                          let text = dict["text"] as? String,
                          let level = dict["level"] as? Int else { return nil }
                    return HeadingItem(id: id, text: text, level: level)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onHeadingsUpdate?(items)
                }
            } else if message.name == "activeHeading" {
                let id = message.body as? String
                DispatchQueue.main.async { [weak self] in
                    self?.onActiveHeadingChange?(id?.isEmpty == true ? nil : id)
                }
            } else if message.name == "docStats", let stats = message.body as? [String: Any] {
                let words = stats["words"] as? Int ?? 0
                let chars = stats["chars"] as? Int ?? 0
                let readingTime = stats["readingTime"] as? Int ?? 0
                DispatchQueue.main.async { [weak self] in
                    self?.onStatsUpdate?(DocumentStats(words: words, chars: chars, readingTime: readingTime))
                }
            }
        }

        func scrollToHeading(_ headingID: String) {
            guard isLoaded, let webView = webView else { return }
            let escaped = headingID.replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("document.getElementById('\(escaped)')?.scrollIntoView({ behavior: 'smooth', block: 'start' })") { _, _ in }
        }
    }
}
