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
        let context = JSContext()!

        // Load markdown-it from bundle
        if let url = Bundle.main.url(forResource: "markdown-it.min", withExtension: "js"),
           let js = try? String(contentsOf: url) {
            context.evaluateScript(js)
        }

        // Load highlight.js from bundle
        if let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
           let js = try? String(contentsOf: url) {
            context.evaluateScript(js)
        }

        // Initialize markdown-it with highlighting
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

        // Escape the markdown for JS template literal
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let result = context.evaluateScript("md.render(`\(escaped)`)")
        let renderedHTML = result?.toString() ?? "<p>Failed to render markdown</p>"

        return wrapInHTML(renderedHTML)
    }

    private func wrapInHTML(_ body: String) -> String {
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
            h1, h2, h3, h4, h5, h6 {
                font-weight: 600; line-height: 1.25;
                letter-spacing: -0.02em; color: #1f2328;
            }
            h1, h2 { margin-top: 2em; }
            h3, h4, h5, h6 { margin-top: 1.5em; }
            h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
            h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
            h3 { font-size: 1.25em; }
            p { margin-bottom: 1.25em; }
            a { color: #0969da; text-decoration: none; }
            code {
                font-family: "SF Mono", Menlo, monospace; font-size: 0.85em;
                background: #f6f8fa; padding: 0.2em 0.4em;
                border-radius: 6px; border: 1px solid #d0d7de;
            }
            pre {
                background: #f6f8fa; border: 1px solid #d0d7de;
                border-radius: 8px; padding: 16px; overflow-x: auto;
            }
            pre code { background: none; border: none; padding: 0; }
            blockquote {
                border-left: 4px solid #d0d7de;
                padding: 0.25em 1em; color: #656d76;
            }
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
