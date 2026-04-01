import Foundation

public struct FrontmatterParser: Sendable {

    /// Parse YAML frontmatter from markdown content.
    /// Returns extracted key-value fields and the body (content after frontmatter).
    public static func parse(_ content: String) -> (fields: [String: String], body: String) {
        let lines = content.components(separatedBy: "\n")

        guard !lines.isEmpty, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return (fields: [:], body: content)
        }

        // Find the closing ---
        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let closing = closingIndex else {
            return (fields: [:], body: content)
        }

        // Extract fields between the delimiters
        var fields: [String: String] = [:]
        for i in 1..<closing {
            let line = lines[i]
            if let colonRange = line.range(of: ":") {
                let key = String(line[line.startIndex..<colonRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(line[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    fields[key] = value
                }
            }
        }

        // Body is everything after the closing delimiter, skipping one blank line if present
        var bodyStart = closing + 1
        if bodyStart < lines.count && lines[bodyStart].trimmingCharacters(in: .whitespaces).isEmpty {
            bodyStart += 1
        }

        let body: String
        if bodyStart >= lines.count {
            body = ""
        } else {
            body = lines[bodyStart...].joined(separator: "\n")
        }

        return (fields: fields, body: body)
    }

    /// Set a field in frontmatter. Adds to existing frontmatter, updates an existing field,
    /// or creates new frontmatter if none is present.
    public static func setField(_ key: String, value: String, in content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let hasOpening = !lines.isEmpty && lines[0].trimmingCharacters(in: .whitespaces) == "---"

        // Find closing delimiter if frontmatter exists
        var closingIndex: Int?
        if hasOpening {
            for i in 1..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    closingIndex = i
                    break
                }
            }
        }

        if let closing = closingIndex {
            // Frontmatter exists — check if the key already exists
            var mutableLines = lines
            var found = false
            for i in 1..<closing {
                if let colonRange = mutableLines[i].range(of: ":") {
                    let existingKey = String(mutableLines[i][mutableLines[i].startIndex..<colonRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if existingKey == key {
                        mutableLines[i] = "\(key): \(value)"
                        found = true
                        break
                    }
                }
            }
            if !found {
                // Insert before closing ---
                mutableLines.insert("\(key): \(value)", at: closing)
            }
            return mutableLines.joined(separator: "\n")
        } else {
            // No frontmatter — prepend new frontmatter
            return "---\n\(key): \(value)\n---\n\n\(content)"
        }
    }

    /// Extract Google Doc ID from a URL like `https://docs.google.com/document/d/ABC123/edit`.
    public static func extractDocID(from url: String) -> String? {
        let pattern = #"docs\.google\.com/document/d/([a-zA-Z0-9_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: url,
                range: NSRange(url.startIndex..., in: url)
              ),
              let captureRange = Range(match.range(at: 1), in: url)
        else {
            return nil
        }
        return String(url[captureRange])
    }
}
