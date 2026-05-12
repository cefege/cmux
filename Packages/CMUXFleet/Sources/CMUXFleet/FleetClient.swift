import Foundation

public struct FleetHelloResponse: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostId: UUID
    public let displayName: String
    public let version: String

    public init(schemaVersion: Int, hostId: UUID, displayName: String, version: String) {
        self.schemaVersion = schemaVersion
        self.hostId = hostId
        self.displayName = displayName
        self.version = version
    }
}

public enum FleetClientError: Error, CustomStringConvertible {
    case httpStatus(Int)
    case timeout
    case malformedResponse(String)
    case network(String)

    public var description: String {
        switch self {
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .timeout:
            return "timeout"
        case .malformedResponse(let detail):
            return "malformed response: \(detail)"
        case .network(let detail):
            return "network: \(detail)"
        }
    }
}

public protocol FleetClient: Sendable {
    func hello(host: String, port: UInt16, timeout: TimeInterval) async throws -> FleetHelloResponse
    func workspaces(host: String, port: UInt16, timeout: TimeInterval) async throws -> FleetWorkspacesResponse
}

public struct URLSessionFleetClient: FleetClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func hello(host: String, port: UInt16, timeout: TimeInterval) async throws -> FleetHelloResponse {
        try await fetchJSON(host: host, port: port, path: "/v1/hello", timeout: timeout)
    }

    public func workspaces(host: String, port: UInt16, timeout: TimeInterval) async throws -> FleetWorkspacesResponse {
        try await fetchJSON(host: host, port: port, path: "/v1/workspaces", timeout: timeout)
    }

    private func fetchJSON<T: Decodable>(
        host: String,
        port: UInt16,
        path: String,
        timeout: TimeInterval
    ) async throws -> T {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw FleetClientError.network("invalid URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("cmux-fleet/1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FleetClientError.timeout
        } catch {
            throw FleetClientError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FleetClientError.malformedResponse("not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FleetClientError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FleetClientError.malformedResponse(error.localizedDescription)
        }
    }
}
