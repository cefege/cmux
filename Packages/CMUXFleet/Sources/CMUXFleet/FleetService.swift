import Foundation
import Network

public struct FleetServiceConfig: Sendable {
    public var boundIP: String
    public var port: UInt16
    public var version: String

    public init(boundIP: String, port: UInt16 = 0, version: String) {
        self.boundIP = boundIP
        self.port = port
        self.version = version
    }
}

public typealias FleetRequestHandler = @Sendable (FleetHTTPRequest, FleetRequestContext) async -> FleetHTTPResponse

public typealias FleetWebSocketHandler = @Sendable (FleetWebSocketChannel, FleetRequestContext) async -> Void

public struct FleetRequestContext: Sendable {
    /// Tailscale identity of the peer (resolved via `tailscale whois`). `nil` when
    /// the request was rejected by auth and is about to be dropped — handlers
    /// don't normally see this case.
    public let peer: TailscaleWhois?
    public let peerAddress: String
    public let peerPort: UInt16
    /// Path parameters extracted by a `FleetWebSocketEndpoint.template` matcher
    /// (e.g. `["id": "<uuid>"]` for `/v1/workspaces/{id}/attach`). Empty for
    /// HTTP routes and for literal-path WS endpoints.
    public let pathParams: [String: String]

    public init(
        peer: TailscaleWhois?,
        peerAddress: String,
        peerPort: UInt16,
        pathParams: [String: String] = [:]
    ) {
        self.peer = peer
        self.peerAddress = peerAddress
        self.peerPort = peerPort
        self.pathParams = pathParams
    }
}

/// A WebSocket route. The matcher inspects the request path and returns the
/// extracted path parameters when the route applies, or nil to decline.
///
/// Construct with `.exact(_:handler:)` for literal paths like `/v1/events`,
/// or `.template(_:handler:)` for routes with curly-brace parameter slots
/// like `/v1/workspaces/{id}/attach`. FleetService picks the first matching
/// endpoint in registration order, so register specific routes before
/// catch-all ones.
public struct FleetWebSocketEndpoint: Sendable {
    public let label: String
    public let matcher: @Sendable (String) -> [String: String]?
    public let handler: FleetWebSocketHandler

    public init(
        label: String,
        matcher: @escaping @Sendable (String) -> [String: String]?,
        handler: @escaping FleetWebSocketHandler
    ) {
        self.label = label
        self.matcher = matcher
        self.handler = handler
    }

    public static func exact(
        _ path: String,
        handler: @escaping FleetWebSocketHandler
    ) -> FleetWebSocketEndpoint {
        FleetWebSocketEndpoint(
            label: path,
            matcher: { incoming in incoming == path ? [:] : nil },
            handler: handler
        )
    }

    public static func template(
        _ template: String,
        handler: @escaping FleetWebSocketHandler
    ) -> FleetWebSocketEndpoint {
        let segments = template.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return FleetWebSocketEndpoint(
            label: template,
            matcher: { incoming in
                let incomingSegments = incoming
                    .split(separator: "/", omittingEmptySubsequences: false)
                    .map(String.init)
                guard incomingSegments.count == segments.count else { return nil }
                var params: [String: String] = [:]
                for (seg, actual) in zip(segments, incomingSegments) {
                    if seg.hasPrefix("{"), seg.hasSuffix("}"), seg.count >= 2 {
                        let name = String(seg.dropFirst().dropLast())
                        guard !name.isEmpty, !actual.isEmpty else { return nil }
                        params[name] = actual
                    } else if seg != actual {
                        return nil
                    }
                }
                return params
            },
            handler: handler
        )
    }
}

public enum FleetServiceError: Error, CustomStringConvertible {
    case invalidBindIP(String)
    case listenerFailed(String)
    case notRunning

    public var description: String {
        switch self {
        case .invalidBindIP(let ip):
            return "Invalid bind IP \(ip)"
        case .listenerFailed(let detail):
            return "Fleet listener failed: \(detail)"
        case .notRunning:
            return "Fleet service is not running"
        }
    }
}

/// HTTP server that binds exclusively to a Tailscale interface address.
///
/// Auth: every accepted connection is resolved via `tailscale whois`. If the
/// peer is not on the same tailnet as `selfUserId`, the connection is closed
/// with a 403 before the handler runs.
public final class FleetService: @unchecked Sendable {
    private let config: FleetServiceConfig
    private let probe: TailscaleProbe
    private let selfUserId: Int64
    private let handler: FleetRequestHandler
    private let webSocketEndpoints: [FleetWebSocketEndpoint]
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: Set<ObjectIdentifier> = []
    private var activeChannels: [ObjectIdentifier: FleetWebSocketChannel] = [:]
    private var resolvedPort: UInt16 = 0
    private var startError: Error?
    private let whoisCache = WhoisCache(ttlSeconds: 60)

    public init(
        config: FleetServiceConfig,
        probe: TailscaleProbe,
        selfUserId: Int64,
        handler: @escaping FleetRequestHandler,
        webSocketEndpoints: [FleetWebSocketEndpoint] = []
    ) {
        self.config = config
        self.probe = probe
        self.selfUserId = selfUserId
        self.handler = handler
        self.webSocketEndpoints = webSocketEndpoints
        self.queue = DispatchQueue(label: "cmux.fleet.service", qos: .userInitiated, attributes: .concurrent)
    }

    public var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return resolvedPort
    }

    public func start() throws -> UInt16 {
        guard let host = ipv4HostEndpoint() else {
            throw FleetServiceError.invalidBindIP(config.boundIP)
        }
        let portEndpoint = config.port == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: config.port) ?? .any)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: host, port: portEndpoint)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw FleetServiceError.listenerFailed(String(describing: error))
        }

        let readySema = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.resolvedPort = listener.port?.rawValue ?? 0
                self.startError = nil
                self.lock.unlock()
                readySema.signal()
            case .failed(let error):
                self.lock.lock()
                self.startError = error
                self.lock.unlock()
                readySema.signal()
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        let timeout = readySema.wait(timeout: .now() + 5)
        if timeout == .timedOut {
            listener.cancel()
            throw FleetServiceError.listenerFailed("listener did not become ready within 5s")
        }

        lock.lock()
        let err = startError
        let port = resolvedPort
        lock.unlock()
        if let err = err {
            listener.cancel()
            throw FleetServiceError.listenerFailed(String(describing: err))
        }

        lock.lock()
        self.listener = listener
        lock.unlock()
        return port
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        let channels = Array(activeChannels.values)
        self.listener = nil
        self.activeChannels.removeAll()
        lock.unlock()
        listener?.cancel()
        for channel in channels {
            channel.close(code: 1001, reason: "service stopping")
        }
    }

    private func ipv4HostEndpoint() -> NWEndpoint.Host? {
        // Reject non-IPv4 to keep the binding crisp. Caller is expected to pass
        // a Tailscale 100.x.x.x address.
        let parts = config.boundIP.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return NWEndpoint.Host(config.boundIP)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        activeConnections.insert(id)
        lock.unlock()

        let cleanup: @Sendable () -> Void = { [weak self] in
            self?.lock.lock()
            self?.activeConnections.remove(id)
            self?.lock.unlock()
            connection.cancel()
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.handleAccepted(connection, cleanup: cleanup)
            case .failed, .cancelled:
                cleanup()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleAccepted(_ connection: NWConnection, cleanup: @escaping @Sendable () -> Void) {
        let (peerAddress, peerPort) = peerEndpoint(connection)
        readUntilRequest(connection: connection, buffer: Data(), cleanup: cleanup) { [weak self] request, leftover in
            guard let self = self else {
                cleanup()
                return
            }
            Task {
                await self.dispatchRequest(
                    connection: connection,
                    request: request,
                    leftover: leftover,
                    peerAddress: peerAddress,
                    peerPort: peerPort,
                    cleanup: cleanup
                )
            }
        }
    }

    private func dispatchRequest(
        connection: NWConnection,
        request: FleetHTTPRequest,
        leftover: Data,
        peerAddress: String,
        peerPort: UInt16,
        cleanup: @escaping @Sendable () -> Void
    ) async {
        let auth = await authenticate(peerAddress: peerAddress, peerPort: peerPort)
        switch auth {
        case .rejected(let response):
            sendAndClose(connection: connection, response: response, cleanup: cleanup)
        case .accepted(let whois):
            if request.method.uppercased() == "GET",
               Self.isWebSocketUpgrade(request),
               let (endpoint, pathParams) = matchWebSocketEndpoint(path: request.path)
            {
                let context = FleetRequestContext(
                    peer: whois,
                    peerAddress: peerAddress,
                    peerPort: peerPort,
                    pathParams: pathParams
                )
                await performUpgrade(
                    connection: connection,
                    request: request,
                    leftover: leftover,
                    context: context,
                    endpoint: endpoint,
                    cleanup: cleanup
                )
            } else {
                let context = FleetRequestContext(
                    peer: whois,
                    peerAddress: peerAddress,
                    peerPort: peerPort
                )
                let response = await handler(request, context)
                sendAndClose(connection: connection, response: response, cleanup: cleanup)
            }
        }
    }

    private func matchWebSocketEndpoint(path: String) -> (FleetWebSocketEndpoint, [String: String])? {
        for endpoint in webSocketEndpoints {
            if let params = endpoint.matcher(path) {
                return (endpoint, params)
            }
        }
        return nil
    }

    private enum AuthResult {
        case accepted(TailscaleWhois)
        case rejected(FleetHTTPResponse)
    }

    private func authenticate(peerAddress: String, peerPort: UInt16) async -> AuthResult {
        let nowUnix = Int64(Date().timeIntervalSince1970)
        let whois: TailscaleWhois?
        if let cached = whoisCache.get(key: peerAddress, now: nowUnix) {
            whois = cached.whois
        } else {
            let fresh = try? await probe.whois(host: peerAddress, port: peerPort)
            whoisCache.set(key: peerAddress, whois: fresh, now: nowUnix)
            whois = fresh
        }

        guard let whois = whois else {
            return .rejected(.plainText(403, "Forbidden", "whois failed"))
        }
        guard whois.user?.id == selfUserId else {
            return .rejected(.plainText(403, "Forbidden", "different tailnet user"))
        }
        return .accepted(whois)
    }

    private static func isWebSocketUpgrade(_ request: FleetHTTPRequest) -> Bool {
        let upgrade = (request.headers["upgrade"] ?? "").lowercased()
        return upgrade.contains("websocket")
    }

    private func performUpgrade(
        connection: NWConnection,
        request: FleetHTTPRequest,
        leftover: Data,
        context: FleetRequestContext,
        endpoint: FleetWebSocketEndpoint,
        cleanup: @escaping @Sendable () -> Void
    ) async {
        let handshake: FleetHTTPResponse
        do {
            handshake = try FleetWebSocket.handshakeResponse(forRequestHeaders: request.headers)
        } catch {
            sendAndClose(
                connection: connection,
                response: .plainText(400, "Bad Request", "websocket: \(error)"),
                cleanup: cleanup
            )
            return
        }

        let handshakeBytes = FleetHTTPParser.serialize(handshake)
        do {
            try await sendAsync(connection: connection, data: handshakeBytes)
        } catch {
            cleanup()
            return
        }

        // Connection ownership moves from "in-flight HTTP request" to the
        // channel. Drop it from activeConnections and track the channel
        // separately so stop() can close upgraded clients explicitly.
        unregisterConnection(ObjectIdentifier(connection))

        let channelBox = WeakChannelBox()
        let onChannelClose: @Sendable () -> Void = { [weak self] in
            guard let self = self else { return }
            guard let channel = channelBox.channel else { return }
            self.unregisterChannel(ObjectIdentifier(channel))
        }

        let channel = FleetWebSocketChannel(
            connection: connection,
            queue: queue,
            initialBuffer: leftover,
            onClose: onChannelClose
        )
        channelBox.channel = channel
        registerChannel(channel)

        await endpoint.handler(channel, context)
        // The handler returned — make sure the connection is torn down.
        channel.close()
    }

    private func unregisterConnection(_ id: ObjectIdentifier) {
        lock.lock()
        activeConnections.remove(id)
        lock.unlock()
    }

    private func registerChannel(_ channel: FleetWebSocketChannel) {
        let id = ObjectIdentifier(channel)
        lock.lock()
        activeChannels[id] = channel
        lock.unlock()
    }

    private func unregisterChannel(_ id: ObjectIdentifier) {
        lock.lock()
        activeChannels.removeValue(forKey: id)
        lock.unlock()
    }

    private func sendAndClose(
        connection: NWConnection,
        response: FleetHTTPResponse,
        cleanup: @escaping @Sendable () -> Void
    ) {
        let data = FleetHTTPParser.serialize(response)
        connection.send(content: data, completion: .contentProcessed { _ in
            cleanup()
        })
    }

    private func sendAsync(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readUntilRequest(
        connection: NWConnection,
        buffer: Data,
        cleanup: @escaping @Sendable () -> Void,
        onComplete: @escaping @Sendable (FleetHTTPRequest, Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if error != nil {
                cleanup()
                return
            }
            var next = buffer
            if let data = data, !data.isEmpty {
                next.append(data)
            }
            do {
                if let parsed = try FleetHTTPParser.tryParse(next) {
                    let leftover = next.count > parsed.consumed
                        ? next.subdata(in: parsed.consumed..<next.count)
                        : Data()
                    onComplete(parsed.request, leftover)
                    return
                }
            } catch {
                let bad = FleetHTTPParser.serialize(.plainText(400, "Bad Request", "malformed HTTP"))
                connection.send(content: bad, completion: .contentProcessed { _ in
                    cleanup()
                })
                return
            }
            if isComplete {
                cleanup()
                return
            }
            if next.count > 256 * 1024 {
                let bad = FleetHTTPParser.serialize(.plainText(413, "Payload Too Large", "request too large"))
                connection.send(content: bad, completion: .contentProcessed { _ in
                    cleanup()
                })
                return
            }
            self.readUntilRequest(connection: connection, buffer: next, cleanup: cleanup, onComplete: onComplete)
        }
    }

    private final class WeakChannelBox: @unchecked Sendable {
        weak var channel: FleetWebSocketChannel?
    }

    private func peerEndpoint(_ connection: NWConnection) -> (String, UInt16) {
        switch connection.endpoint {
        case .hostPort(let host, let port):
            return (Self.hostString(host), port.rawValue)
        default:
            return ("", 0)
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let v4):
            return v4.debugDescription
        case .ipv6(let v6):
            return v6.debugDescription
        case .name(let name, _):
            return name
        @unknown default:
            return ""
        }
    }
}

final class WhoisCache: @unchecked Sendable {
    struct Entry {
        let whois: TailscaleWhois?
        let expiresAtUnix: Int64
    }

    private let lock = NSLock()
    private let ttlSeconds: Int64
    private var entries: [String: Entry] = [:]

    init(ttlSeconds: Int64) {
        self.ttlSeconds = ttlSeconds
    }

    func get(key: String, now: Int64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], entry.expiresAtUnix > now else { return nil }
        return entry
    }

    func set(key: String, whois: TailscaleWhois?, now: Int64) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = Entry(whois: whois, expiresAtUnix: now + ttlSeconds)
    }
}
