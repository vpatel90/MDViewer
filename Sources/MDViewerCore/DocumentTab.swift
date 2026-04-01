import Foundation

public struct DocumentTab: Identifiable, Equatable {
    public let id: UUID
    public let fileURL: URL
    public var filename: String { fileURL.lastPathComponent }
    public var content: String

    public var gdocURL: String? {
        let parsed = FrontmatterParser.parse(content)
        return parsed.fields["gdoc"]
    }

    public init(fileURL: URL, content: String) {
        self.id = UUID()
        self.fileURL = fileURL
        self.content = content
    }
}
