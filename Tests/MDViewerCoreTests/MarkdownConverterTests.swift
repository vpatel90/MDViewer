import Foundation
import Testing
@testable import MDViewerCore

struct MarkdownConverterTests {
    @Test func htmlToMarkdown_basicFormatting() {
        let converter = MarkdownConverter()
        let html = "<h1>Title</h1><p>Hello <strong>bold</strong> and <em>italic</em>.</p>"
        let md = converter.htmlToMarkdown(html)
        #expect(md.contains("# Title") || md.contains("Title\n="))
        #expect(md.contains("**bold**"))
        #expect(md.contains("*italic*") || md.contains("_italic_"))
    }

    @Test func htmlToMarkdown_list() {
        let converter = MarkdownConverter()
        let html = "<ul><li>One</li><li>Two</li></ul>"
        let md = converter.htmlToMarkdown(html)
        #expect(md.contains("One"))
        #expect(md.contains("Two"))
    }

    @Test func htmlToMarkdown_link() {
        let converter = MarkdownConverter()
        let html = "<p><a href=\"https://example.com\">Click</a></p>"
        let md = converter.htmlToMarkdown(html)
        #expect(md.contains("[Click](https://example.com)"))
    }

    @Test func markdownToHTML_basicFormatting() {
        let converter = MarkdownConverter()
        let md = "# Title\n\nHello **bold**."
        let html = converter.markdownToHTML(md)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
    }
}
