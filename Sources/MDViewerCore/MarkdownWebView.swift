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
