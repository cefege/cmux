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

public struct FleetRequestContext: Sendable {
    /// Tailscale identity of the peer (resolved via `tailscale whois`). `nil` when
    /// the request was rejected by auth and is about to be dropped — handlers
    /// don't normally see this case.
    public let peer: TailscaleWhois?
    public let peerAddress: String
    public let peerPort: UInt16
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
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: Set<ObjectIdentifier> = []
    private var resolvedPort: UInt16 = 0
    private var startError: Error?

    public init(
        config: FleetServiceConfig,
        probe: TailscaleProbe,
        selfUserId: Int64,
        handler: @escaping FleetRequestHandler
    ) {
        self.config = config
        self.probe = probe
        self.selfUserId = selfUserId
        self.handler = handler
        self.queue = DispatchQueue(label: "cmux.fleet.service", qos: .userInitiated)
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
        self.listener = nil
        lock.unlock()
        listener?.cancel()
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
        readUntilRequest(connection: connection, buffer: Data(), cleanup: cleanup) { [weak self] request in
            guard let self = self else {
                cleanup()
                return
            }
            Task {
                let response = await self.authenticateAndDispatch(
                    request: request,
                    peerAddress: peerAddress,
                    peerPort: peerPort
                )
                let data = FleetHTTPParser.serialize(response)
                connection.send(content: data, completion: .contentProcessed { _ in
                    cleanup()
                })
            }
        }
    }

    private func authenticateAndDispatch(
        request: FleetHTTPRequest,
        peerAddress: String,
        peerPort: UInt16
    ) async -> FleetHTTPResponse {
        let whois: TailscaleWhois?
        do {
            whois = try await probe.whois(host: peerAddress, port: peerPort)
        } catch {
            whois = nil
        }

        guard let whois = whois else {
            return .plainText(403, "Forbidden", "whois failed")
        }
        guard whois.user?.id == selfUserId else {
            return .plainText(403, "Forbidden", "different tailnet user")
        }

        let context = FleetRequestContext(peer: whois, peerAddress: peerAddress, peerPort: peerPort)
        return await handler(request, context)
    }

    private func readUntilRequest(
        connection: NWConnection,
        buffer: Data,
        cleanup: @escaping @Sendable () -> Void,
        onComplete: @escaping @Sendable (FleetHTTPRequest) -> Void
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
                    onComplete(parsed.request)
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
