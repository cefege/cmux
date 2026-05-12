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
    private let version: String
    private let preferredPorts: [UInt16]
    private let peerRegistryConfig: (UInt16) -> FleetPeerRegistryConfig

    private var identity: FleetIdentity?
    private var router: FleetRouter?
    private var service: FleetService?
    private var registry: FleetPeerRegistry?
    private var boundIP: String?
    private var boundPort: UInt16 = 0

    public init(
        version: String,
        identityStorage: FleetIdentityStorage = FleetIdentityFileStorage(),
        probeFactory: @escaping @Sendable () -> TailscaleProbe? = { TailscaleCLIProbe() },
        clientFactory: @escaping @Sendable () -> FleetClient = { URLSessionFleetClient() },
        workspaceProvider: FleetWorkspaceProvider = EmptyFleetWorkspaceProvider(),
        preferredPorts: [UInt16] = Array(FleetPort.multiInstanceRange),
        peerRegistryConfig: @escaping (UInt16) -> FleetPeerRegistryConfig = { FleetPeerRegistryConfig(port: $0) }
    ) {
        self.version = version
        self.identityStorage = identityStorage
        self.probeFactory = probeFactory
        self.clientFactory = clientFactory
        self.workspaceProvider = workspaceProvider
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

        let (service, port) = try startServiceOnFirstAvailablePort(
            ipv4: ipv4,
            probe: probe,
            userId: userId,
            handler: await router.makeHandler()
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
        self.boundIP = ipv4
        self.boundPort = port

        return (ipv4, port)
    }

    public func stop() async {
        let service = self.service
        let registry = self.registry
        self.service = nil
        self.registry = nil
        self.router = nil
        self.boundIP = nil
        self.boundPort = 0
        await registry?.stop()
        service?.stop()
    }

    /// Falls back to ephemeral (port 0) only if every preferred port is in
    /// use; peers using FleetPort.default won't find a fallback-bound host,
    /// which is acceptable for DEV/STAGING side-by-side runs.
    private func startServiceOnFirstAvailablePort(
        ipv4: String,
        probe: TailscaleProbe,
        userId: Int64,
        handler: @escaping FleetRequestHandler
    ) throws -> (FleetService, UInt16) {
        var attempts: [UInt16] = preferredPorts
        attempts.append(0)
        var lastError: Error?
        for candidate in attempts {
            let service = FleetService(
                config: FleetServiceConfig(boundIP: ipv4, port: candidate, version: version),
                probe: probe,
                selfUserId: userId,
                handler: handler
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
