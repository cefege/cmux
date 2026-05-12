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
    private let version: String

    private var identity: FleetIdentity?
    private var router: FleetRouter?
    private var service: FleetService?
    private var boundIP: String?
    private var boundPort: UInt16 = 0

    public init(
        version: String,
        identityStorage: FleetIdentityStorage = FleetIdentityFileStorage(),
        probeFactory: @escaping @Sendable () -> TailscaleProbe? = { TailscaleCLIProbe() }
    ) {
        self.version = version
        self.identityStorage = identityStorage
        self.probeFactory = probeFactory
    }

    public func currentIdentity() -> FleetIdentity? {
        identity
    }

    public func currentBinding() -> (ip: String, port: UInt16)? {
        guard let ip = boundIP else { return nil }
        return (ip, boundPort)
    }

    /// Starts the fleet service. Returns the resolved (ip, port) the listener
    /// is bound to.
    public func start() async throws -> (ip: String, port: UInt16) {
        if service != nil {
            throw FleetCoordinatorError.alreadyRunning
        }

        guard let probe = probeFactory() else {
            throw FleetCoordinatorError.tailscaleUnavailable
        }

        let status = try await probe.status()
        guard let ipv4 = status.selfNode.tailscaleIPs.first(where: { Self.isIPv4($0) }) else {
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

        let service = FleetService(
            config: FleetServiceConfig(boundIP: ipv4, port: 0, version: version),
            probe: probe,
            selfUserId: userId,
            handler: await router.makeHandler()
        )
        let port = try service.start()

        self.identity = identity
        self.router = router
        self.service = service
        self.boundIP = ipv4
        self.boundPort = port

        return (ipv4, port)
    }

    public func stop() {
        let service = self.service
        self.service = nil
        self.router = nil
        self.boundIP = nil
        self.boundPort = 0
        service?.stop()
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
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
