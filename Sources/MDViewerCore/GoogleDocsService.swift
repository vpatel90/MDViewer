import Foundation

@MainActor
public class GoogleDocsService {
    private let auth: GoogleAuthManager

    public init(auth: GoogleAuthManager) {
        self.auth = auth
    }

    /// Fetch a Google Doc as HTML
    public func fetchDocHTML(docID: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(docID)/export?mimeType=text/html")!
        let data = try await authenticatedRequest(url: url, method: "GET")
        guard let html = String(data: data, encoding: .utf8) else {
            throw DocsError.invalidResponse
        }
        return html
    }

    /// Update an existing Google Doc with HTML content
    public func updateDoc(docID: String, html: String) async throws {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(docID)?uploadType=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("text/html", forHTTPHeaderField: "Content-Type")
        request.httpBody = html.data(using: .utf8)
        _ = try await authenticatedDataRequest(request: request)
    }

    /// Create a new Google Doc from HTML, returns the document URL
    public func createDoc(name: String, html: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!
        let boundary = UUID().uuidString
        var body = Data()

        // Metadata part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        let metadata: [String: String] = ["name": name, "mimeType": "application/vnd.google-apps.document"]
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n".data(using: .utf8)!)

        // Content part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/html\r\n\r\n".data(using: .utf8)!)
        body.append(html.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await authenticatedDataRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let docID = json["id"] as? String else {
            throw DocsError.createFailed
        }
        return "https://docs.google.com/document/d/\(docID)/edit"
    }

    // MARK: - Authenticated requests with auto-retry on 401

    private func authenticatedRequest(url: URL, method: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return try await authenticatedDataRequest(request: request)
    }

    private func authenticatedDataRequest(request: URLRequest) async throws -> Data {
        var req = request
        let token = try await auth.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            let newToken = try await auth.handleUnauthorized()
            req.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: req)
            try checkResponse(retryResponse, data: retryData)
            return retryData
        }

        try checkResponse(response, data: data)
        return data
    }

    private func checkResponse(_ response: URLResponse?, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DocsError.apiError(statusCode: http.statusCode, message: body)
        }
    }

    // MARK: - Errors

    public enum DocsError: LocalizedError {
        case invalidResponse
        case createFailed
        case apiError(statusCode: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Google."
            case .createFailed: return "Failed to create Google Doc."
            case .apiError(let code, let msg):
                if code == 403 { return "Access denied. Make sure you have permission to access this document." }
                if code == 404 { return "Document not found. Check the URL and try again." }
                return "Google API error (\(code)): \(msg)"
            }
        }
    }
}
