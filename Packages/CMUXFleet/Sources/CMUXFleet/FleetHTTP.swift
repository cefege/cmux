import Foundation

public struct FleetHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let httpVersion: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, httpVersion: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
    }
}

public struct FleetHTTPResponse: Sendable {
    public var status: Int
    public var statusText: String
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, statusText: String, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ statusText: String, _ payload: Any) -> FleetHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return FleetHTTPResponse(
            status: status,
            statusText: statusText,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    public static func plainText(_ status: Int, _ statusText: String, _ text: String) -> FleetHTTPResponse {
        FleetHTTPResponse(
            status: status,
            statusText: statusText,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }
}

public enum FleetHTTPParseError: Error, Equatable {
    case incomplete
    case malformed(String)
}

public enum FleetHTTPParser {
    /// Attempts to parse an HTTP/1.1 request from `buffer`.
    /// - Returns: `(request, bytesConsumed)` if a full request was found,
    ///   `nil` if more bytes are needed.
    /// - Throws: `FleetHTTPParseError.malformed` if the buffer is clearly invalid.
    public static func tryParse(_ buffer: Data) throws -> (request: FleetHTTPRequest, consumed: Int)? {
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEnd = buffer.range(of: crlfcrlf) else {
            return nil
        }
        let headerBytes = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerString = String(data: headerBytes, encoding: .utf8) else {
            throw FleetHTTPParseError.malformed("non-utf8 header block")
        }

        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            throw FleetHTTPParseError.malformed("missing request line")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw FleetHTTPParseError.malformed("bad request line")
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let httpVersion = String(parts[2])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colonIndex = line.firstIndex(of: ":") else {
                throw FleetHTTPParseError.malformed("bad header line: \(line)")
            }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else {
            return nil
        }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)

        return (
            FleetHTTPRequest(
                method: method,
                path: path,
                httpVersion: httpVersion,
                headers: headers,
                body: body
            ),
            bodyEnd
        )
    }

    public static func serialize(_ response: FleetHTTPResponse) -> Data {
        var out = Data()
        out.append(Data("HTTP/1.1 \(response.status) \(response.statusText)\r\n".utf8))
        var headers = response.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(response.body.count)
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "close"
        }
        for (name, value) in headers {
            out.append(Data("\(name): \(value)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(response.body)
        return out
    }

}
