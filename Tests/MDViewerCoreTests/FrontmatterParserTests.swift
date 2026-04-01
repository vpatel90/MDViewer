import Foundation
import Testing
@testable import MDViewerCore

struct FrontmatterParserTests {

    @Test func parse_withFrontmatter_returnsFieldsAndBody() {
        let content = "---\ngdoc: https://docs.google.com/document/d/ABC123/edit\ntitle: My Doc\n---\n\n# Hello"
        let result = FrontmatterParser.parse(content)

        #expect(result.fields["gdoc"] == "https://docs.google.com/document/d/ABC123/edit")
        #expect(result.fields["title"] == "My Doc")
        #expect(result.body == "# Hello")
    }

    @Test func parse_withoutFrontmatter_returnsEmptyFieldsAndFullBody() {
        let content = "# Just Markdown\n\nSome text here."
        let result = FrontmatterParser.parse(content)

        #expect(result.fields.isEmpty)
        #expect(result.body == content)
    }

    @Test func parse_withEmptyFrontmatter_returnsEmptyFields() {
        let content = "---\n---\n\n# Hello"
        let result = FrontmatterParser.parse(content)

        #expect(result.fields.isEmpty)
        #expect(result.body == "# Hello")
    }

    @Test func setField_addsToExistingFrontmatter() {
        let content = "---\ntitle: My Doc\n---\n\n# Hello"
        let result = FrontmatterParser.setField("gdoc", value: "https://example.com", in: content)
        let parsed = FrontmatterParser.parse(result)

        #expect(parsed.fields["gdoc"] == "https://example.com")
        #expect(parsed.fields["title"] == "My Doc")
        #expect(parsed.body == "# Hello")
    }

    @Test func setField_updatesExistingField() {
        let content = "---\ngdoc: old-url\ntitle: My Doc\n---\n\n# Hello"
        let result = FrontmatterParser.setField("gdoc", value: "new-url", in: content)
        let parsed = FrontmatterParser.parse(result)

        #expect(parsed.fields["gdoc"] == "new-url")
        #expect(parsed.fields["title"] == "My Doc")
    }

    @Test func setField_createsNewFrontmatter() {
        let content = "# Hello\n\nSome text."
        let result = FrontmatterParser.setField("gdoc", value: "https://example.com", in: content)

        #expect(result.hasPrefix("---\ngdoc: https://example.com\n---\n\n"))
        #expect(result.hasSuffix("# Hello\n\nSome text."))
    }

    @Test func setField_preservesOtherFields() {
        let content = "---\ntitle: My Doc\nauthor: Jane\ntags: swift, macOS\n---\n\n# Hello"
        let result = FrontmatterParser.setField("gdoc", value: "url", in: content)
        let parsed = FrontmatterParser.parse(result)

        #expect(parsed.fields["title"] == "My Doc")
        #expect(parsed.fields["author"] == "Jane")
        #expect(parsed.fields["tags"] == "swift, macOS")
        #expect(parsed.fields["gdoc"] == "url")
        #expect(parsed.body == "# Hello")
    }
}
