import Foundation

/// Client minimale per endpoint di chat in streaming (Server-Sent Events).
enum SSEClient {
    struct HTTPError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? {
            "HTTP \(status): \(String(body.prefix(300)))"
        }
    }

    /// Esegue la richiesta e consegna il payload JSON di ogni evento `data:`.
    /// Si ferma a fine stream o quando il payload è "[DONE]".
    static func stream(
        request: URLRequest,
        onData: (Data) throws -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError(message: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2000 { break }
            }
            throw HTTPError(status: http.statusCode, body: body)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            try onData(data)
        }
    }

    static func makeRequest(url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
