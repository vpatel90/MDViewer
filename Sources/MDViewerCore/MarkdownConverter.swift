import Foundation
import JavaScriptCore

public class MarkdownConverter {
    private var htmlToMdContext: JSContext?
    private var mdToHtmlContext: JSContext?

    public init() {}

    // MARK: - Public API

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

    // MARK: - Context Setup

    private func getHtmlToMdContext() -> JSContext {
        if let ctx = htmlToMdContext { return ctx }
        let ctx = JSContext()!

        // Set up exception handler for debugging
        ctx.exceptionHandler = { _, exception in
            if let exc = exception {
                print("JSContext error: \(exc)")
            }
        }

        // 1. Provide minimal window/document globals before loading any libraries
        ctx.evaluateScript("var window = this; var document = {};")

        // 2. Load linkedom to provide DOMParser for Turndown
        loadResource("linkedom.min", ext: "js", into: ctx)

        // 3. Wire up DOMParser so Turndown's canParseHTMLNatively() succeeds
        ctx.evaluateScript("""
            window.DOMParser = linkedom.DOMParser;
            document.implementation = { createHTMLDocument: function() { return new linkedom.DOMParser().parseFromString('', 'text/html'); } };
        """)

        // 4. Load Turndown
        loadResource("turndown.min", ext: "js", into: ctx)

        // 5. Load GFM plugin (CJS module - needs exports shim)
        ctx.evaluateScript("var exports = {}; var module = { exports: exports };")
        loadResource("turndown-plugin-gfm.min", ext: "js", into: ctx)
        ctx.evaluateScript("var turndownPluginGfm = module.exports && Object.keys(module.exports).length > 0 ? module.exports : exports;")

        htmlToMdContext = ctx
        return ctx
    }

    private func getMdToHtmlContext() -> JSContext {
        if let ctx = mdToHtmlContext { return ctx }
        let ctx = JSContext()!

        ctx.exceptionHandler = { _, exception in
            if let exc = exception {
                print("JSContext error: \(exc)")
            }
        }

        // Provide minimal browser globals for plugins that check for window
        ctx.evaluateScript("var window = this; var document = {};")

        loadResource("markdown-it.min", ext: "js", into: ctx)
        loadResource("markdown-it-plugins.min", ext: "js", into: ctx)

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

    private func loadResource(_ name: String, ext: String, into ctx: JSContext) {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources"),
           let js = try? String(contentsOf: url) {
            ctx.evaluateScript(js)
        }
    }
}
