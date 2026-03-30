import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let isDarkMode: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingContent = content
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
        context.coordinator.renderContent(content)
        context.coordinator.applyDarkMode(isDarkMode)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingContent: String?
        var pendingDarkMode: Bool?
        var isLoaded = false
        private var lastRenderedContent: String?
        private var lastDarkMode: Bool?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let darkMode = pendingDarkMode {
                pendingDarkMode = nil
                applyDarkMode(darkMode)
            }
            if let content = pendingContent {
                pendingContent = nil
                renderContent(content)
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

        func renderContent(_ content: String) {
            guard isLoaded, let webView = webView else {
                pendingContent = content
                return
            }

            if content == lastRenderedContent { return }
            lastRenderedContent = content

            guard let jsonData = try? JSONEncoder().encode(content),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            webView.evaluateJavaScript("renderMarkdown(\(jsonString))") { _, error in
                if let error = error {
                    print("MDViewer render error: \(error.localizedDescription)")
                }
            }
        }
    }
}
