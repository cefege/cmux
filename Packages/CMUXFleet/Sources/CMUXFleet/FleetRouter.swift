import Foundation

public actor FleetRouter {
    private var routes: [String: FleetRequestHandler] = [:]

    public init() {}

    public func register(
        method: String,
        path: String,
        handler: @escaping FleetRequestHandler
    ) {
        routes[Self.key(method: method, path: path)] = handler
    }

    public func handle(_ request: FleetHTTPRequest, _ ctx: FleetRequestContext) async -> FleetHTTPResponse {
        if let handler = routes[Self.key(method: request.method, path: request.path)] {
            return await handler(request, ctx)
        }
        return .plainText(404, "Not Found", "no route for \(request.method) \(request.path)")
    }

    public func makeHandler() -> FleetRequestHandler {
        { [self] request, ctx in
            await handle(request, ctx)
        }
    }

    private static func key(method: String, path: String) -> String {
        "\(method.uppercased()) \(path)"
    }
}
