import Foundation

public enum FleetCoordinatorError: Error, CustomStringConvertible {
    case tailscaleUnavailable
    case noTailscaleIPv4
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case .tailscaleUnavailable:
            return "Tailscale CLI not installed or not running"
        case .noTailscaleIPv4:
            return "This host has no IPv4 Tailscale address"
        case .alreadyRunning:
            return "Fleet coordinator already started"
        case .notRunning:
            return "Fleet coordinator is not started"
        }
    }
}

/// Top-level entry point used by the cmux app. Loads identity, probes
/// Tailscale, starts the HTTP service bound to the local Tailscale IPv4
/// address, and registers the default routes (currently `/v1/hello`).
public actor FleetCoordinator {
    private let identityStorage: FleetIdentityStorage
    private let probeFactory: @Sendable () -> TailscaleProbe?
    private let clientFactory: @Sendable () -> FleetClient
    private let workspaceProvider: FleetWorkspaceProvider
    private let attachProvider: WorkspaceAttachProvider
    private let version: String
    private let preferredPorts: [UInt16]
    private let peerRegistryConfig: (UInt16) -> FleetPeerRegistryConfig

    private var identity: FleetIdentity?
    private var router: FleetRouter?
    private var service: FleetService?
    private var registry: FleetPeerRegistry?
    private var broadcaster: FleetEventBroadcaster?
    private var boundIP: String?
    private var boundPort: UInt16 = 0

    public init(
        version: String,
        identityStorage: FleetIdentityStorage = FleetIdentityFileStorage(),
        probeFactory: @escaping @Sendable () -> TailscaleProbe? = { TailscaleCLIProbe() },
        clientFactory: @escaping @Sendable () -> FleetClient = { URLSessionFleetClient() },
        workspaceProvider: FleetWorkspaceProvider = EmptyFleetWorkspaceProvider(),
        attachProvider: WorkspaceAttachProvider = NoopWorkspaceAttachProvider(),
        preferredPorts: [UInt16] = Array(FleetPort.multiInstanceRange),
        peerRegistryConfig: @escaping (UInt16) -> FleetPeerRegistryConfig = { FleetPeerRegistryConfig(port: $0) }
    ) {
        self.version = version
        self.identityStorage = identityStorage
        self.probeFactory = probeFactory
        self.clientFactory = clientFactory
        self.workspaceProvider = workspaceProvider
        self.attachProvider = attachProvider
        self.preferredPorts = preferredPorts
        self.peerRegistryConfig = peerRegistryConfig
    }

    public func currentPeers() async -> [FleetPeer] {
        guard let registry = registry else { return [] }
        return await registry.snapshot()
    }

    public func peerStream() async -> AsyncStream<[FleetPeer]>? {
        await registry?.subscribe()
    }

    public func eventBroadcaster() -> FleetEventBroadcaster? {
        broadcaster
    }

    public func currentIdentity() -> FleetIdentity? {
        identity
    }

    public func currentBinding() -> (ip: String, port: UInt16)? {
        guard let ip = boundIP else { return nil }
        return (ip, boundPort)
    }

    public func start() async throws -> (ip: String, port: UInt16) {
        if service != nil {
            throw FleetCoordinatorError.alreadyRunning
        }

        guard let probe = probeFactory() else {
            throw FleetCoordinatorError.tailscaleUnavailable
        }

        let status = try await probe.status()
        guard let ipv4 = status.selfNode.tailscaleIPs.first(where: FleetIPv4.isValid) else {
            throw FleetCoordinatorError.noTailscaleIPv4
        }
        guard let userId = status.selfNode.userId else {
            throw FleetCoordinatorError.tailscaleUnavailable
        }

        let identity = try FleetIdentityProvider.loadOrCreate(
            storage: identityStorage,
            defaultDisplayName: status.selfNode.hostName
        )

        let router = FleetRouter()
        await registerDefaultRoutes(router: router, identity: identity)

        let broadcaster = FleetEventBroadcaster(hostId: identity.hostId)
        let eventsEndpoint = FleetWebSocketEndpoint.exact(
            "/v1/events",
            handler: Self.makeEventsHandler(broadcaster: broadcaster)
        )
        let attachEndpoint = FleetWebSocketEndpoint.template(
            "/v1/workspaces/{id}/attach",
            handler: Self.makeAttachHandler(provider: attachProvider)
        )

        let (service, port) = try startServiceOnFirstAvailablePort(
            ipv4: ipv4,
            probe: probe,
            userId: userId,
            handler: await router.makeHandler(),
            webSocketEndpoints: [eventsEndpoint, attachEndpoint]
        )

        let registry = FleetPeerRegistry(
            probe: probe,
            client: clientFactory(),
            config: peerRegistryConfig(port)
        )
        await registry.start()

        self.identity = identity
        self.router = router
        self.service = service
        self.registry = registry
        self.broadcaster = broadcaster
        self.boundIP = ipv4
        self.boundPort = port

        return (ipv4, port)
    }

    public func stop() async {
        let service = self.service
        let registry = self.registry
        let broadcaster = self.broadcaster
        self.service = nil
        self.registry = nil
        self.router = nil
        self.broadcaster = nil
        self.boundIP = nil
        self.boundPort = 0
        await registry?.stop()
        await broadcaster?.shutdown()
        service?.stop()
    }

    /// Builds the `/v1/events` WS handler. Subscribes the channel to the
    /// broadcaster and forwards every envelope as a single JSON text frame.
    /// Returns when the broadcaster ends the subscription or the channel
    /// receive stream terminates (peer disconnect).
    private static func makeEventsHandler(broadcaster: FleetEventBroadcaster) -> FleetWebSocketHandler {
        { channel, _ in
            let receiveStream = channel.start()
            let eventStream = await broadcaster.subscribe()

            let receiveTask = Task<Void, Never> {
                do {
                    for try await _ in receiveStream {
                        // Ignore application payloads from the client; pings
                        // are handled inside the channel.
                    }
                } catch {
                    // receive loop ended on error — outer task will exit on
                    // the next event yield or via cancellation.
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for await envelope in eventStream {
                guard !Task.isCancelled else { break }
                guard let data = try? encoder.encode(envelope),
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                if receiveTask.isCancelled { break }
                channel.sendText(text)
            }
            receiveTask.cancel()
        }
    }

    /// Step 6 attach handler. Looks the workspace id out of `pathParams`,
    /// asks the host's `WorkspaceAttachProvider` to subscribe to the local
    /// manual PTY's output, and fans the bytes to the peer as one
    /// `{"type":"out","data":<base64>}` text frame per chunk. Sends
    /// `{"type":"attach_hello",...}` first so clients have a known
    /// handshake marker. On unknown workspace id or noop provider the
    /// peer gets `{"type":"not_found","workspaceId":...}` and the
    /// channel closes.
    ///
    /// Input frames from the peer aren't forwarded yet — the protocol is
    /// output-only in this slice. Bidirectional flow lands once the host
    /// exposes an input sink alongside the output subscription.
    private static func makeAttachHandler(provider: WorkspaceAttachProvider) -> FleetWebSocketHandler {
        { channel, ctx in
            let workspaceId = ctx.pathParams["id"] ?? ""

            let subscription = await provider.subscribe(workspaceId: workspaceId) { chunk in
                let payload: [String: Any] = [
                    "type": "out",
                    "data": chunk.base64EncodedString(),
                ]
                guard
                    let data = try? JSONSerialization.data(
                        withJSONObject: payload,
                        options: [.sortedKeys]
                    ),
                    let text = String(data: data, encoding: .utf8)
                else { return }
                channel.sendText(text)
            }

            guard let subscription else {
                let payload: [String: Any] = [
                    "type": "not_found",
                    "workspaceId": workspaceId,
                ]
                if let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.sortedKeys]
                ), let text = String(data: data, encoding: .utf8) {
                    channel.sendText(text)
                }
                channel.close(code: 1000, reason: "workspace not found")
                return
            }

            let hello: [String: Any] = [
                "type": "attach_hello",
                "workspaceId": workspaceId,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: hello,
                options: [.sortedKeys]
            ), let text = String(data: data, encoding: .utf8) {
                channel.sendText(text)
            }

            // Keep the channel open until the peer disconnects. The receive
            // loop just drains frames (input handling is a later slice);
            // when it ends we tear down the subscription so the host stops
            // forwarding bytes.
            let receiveStream = channel.start()
            do {
                for try await _ in receiveStream {
                    // Input frames are ignored until bidirectional support
                    // lands; the iteration still keeps the connection alive.
                }
            } catch {
                // Receive errored — peer dropped or framing broke. Fall
                // through to subscription cleanup + channel close.
            }
            subscription.close()
            channel.close(code: 1000, reason: "attach complete")
        }
    }

    /// Falls back to ephemeral (port 0) only if every preferred port is in
    /// use; peers using FleetPort.default won't find a fallback-bound host,
    /// which is acceptable for DEV/STAGING side-by-side runs.
    private func startServiceOnFirstAvailablePort(
        ipv4: String,
        probe: TailscaleProbe,
        userId: Int64,
        handler: @escaping FleetRequestHandler,
        webSocketEndpoints: [FleetWebSocketEndpoint]
    ) throws -> (FleetService, UInt16) {
        var attempts: [UInt16] = preferredPorts
        attempts.append(0)
        var lastError: Error?
        for candidate in attempts {
            let service = FleetService(
                config: FleetServiceConfig(boundIP: ipv4, port: candidate, version: version),
                probe: probe,
                selfUserId: userId,
                handler: handler,
                webSocketEndpoints: webSocketEndpoints
            )
            do {
                let port = try service.start()
                return (service, port)
            } catch {
                lastError = error
                service.stop()
                continue
            }
        }
        throw lastError ?? FleetCoordinatorError.tailscaleUnavailable
    }

    private func registerDefaultRoutes(router: FleetRouter, identity: FleetIdentity) async {
        let v = version
        await router.register(method: "GET", path: "/v1/hello") { _, _ in
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "hostId": identity.hostId.uuidString,
                "displayName": identity.displayName,
                "version": v,
            ]
            return .json(200, "OK", payload)
        }

        let provider = workspaceProvider
        let hostId = identity.hostId
        await router.register(method: "GET", path: "/v1/workspaces") { _, _ in
            let workspaces = await provider.currentWorkspaces()
            let response = FleetWorkspacesResponse(hostId: hostId, workspaces: workspaces)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(response)) ?? Data()
            return FleetHTTPResponse(
                status: 200,
                statusText: "OK",
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        }
    }

}
