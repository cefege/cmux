import Foundation

public struct FleetPeer: Sendable, Equatable {
    /// Tailscale stable node id. The primary key for a peer.
    public let nodeId: String
    /// Application-level id learned from the peer's /v1/hello. `nil` until the
    /// first successful probe.
    public let hostId: UUID?
    public let displayName: String
    public let tailscaleIP: String
    public let port: UInt16
    public let isOnline: Bool
    public let isSelf: Bool
    public let version: String?
    /// Unix timestamp of the most recent successful probe.
    public let lastSeenUnix: Int64?
    /// Unix timestamp of the most recent state transition (online↔offline).
    public let lastChangedUnix: Int64

    public init(
        nodeId: String,
        hostId: UUID?,
        displayName: String,
        tailscaleIP: String,
        port: UInt16,
        isOnline: Bool,
        isSelf: Bool,
        version: String?,
        lastSeenUnix: Int64?,
        lastChangedUnix: Int64
    ) {
        self.nodeId = nodeId
        self.hostId = hostId
        self.displayName = displayName
        self.tailscaleIP = tailscaleIP
        self.port = port
        self.isOnline = isOnline
        self.isSelf = isSelf
        self.version = version
        self.lastSeenUnix = lastSeenUnix
        self.lastChangedUnix = lastChangedUnix
    }
}

public struct FleetPeerRegistryConfig: Sendable {
    public var pollInterval: TimeInterval
    public var probeTimeout: TimeInterval
    public var port: UInt16

    public init(
        pollInterval: TimeInterval = 10,
        probeTimeout: TimeInterval = 2,
        port: UInt16 = FleetPort.default
    ) {
        self.pollInterval = pollInterval
        self.probeTimeout = probeTimeout
        self.port = port
    }
}

public actor FleetPeerRegistry {
    private let probe: TailscaleProbe
    private let client: FleetClient
    private let config: FleetPeerRegistryConfig
    private let now: @Sendable () -> Date

    private var peers: [String: FleetPeer] = [:]
    private var pollTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[FleetPeer]>.Continuation] = [:]

    public init(
        probe: TailscaleProbe,
        client: FleetClient,
        config: FleetPeerRegistryConfig = FleetPeerRegistryConfig(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.probe = probe
        self.client = client
        self.config = config
        self.now = now
    }

    public func snapshot() -> [FleetPeer] {
        Array(peers.values).sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    public func subscribe() -> AsyncStream<[FleetPeer]> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// Runs a single discovery pass. Exposed so tests don't have to wait on the
    /// poll loop's timer.
    public func tick() async {
        let status: TailscaleStatus
        do {
            status = try await probe.status()
        } catch {
            return
        }

        let selfUserId = status.selfNode.userId
        let candidates = ([status.selfNode] + status.peers).filter { node in
            node.online
                && (node.userId != nil)
                && (node.userId == selfUserId)
                && !node.tailscaleIPs.isEmpty
        }

        let port = config.port
        let timeout = config.probeTimeout
        let selfNodeId = status.selfNode.nodeId

        let probes = await withTaskGroup(of: (TailscaleNode, FleetHelloResponse?).self) { group in
            for node in candidates {
                guard let ip = node.tailscaleIPs.first(where: { Self.isIPv4($0) }) else { continue }
                let captured = node
                let client = self.client
                group.addTask { [client] in
                    do {
                        let hello = try await client.hello(host: ip, port: port, timeout: timeout)
                        return (captured, hello)
                    } catch {
                        return (captured, nil)
                    }
                }
            }
            var results: [(TailscaleNode, FleetHelloResponse?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let nowUnix = Int64(now().timeIntervalSince1970)
        var seenIds: Set<String> = []
        for (node, hello) in probes {
            seenIds.insert(node.nodeId)
            guard let ipv4 = node.tailscaleIPs.first(where: { Self.isIPv4($0) }) else { continue }
            let previous = peers[node.nodeId]
            let isOnline = hello != nil
            let lastChanged: Int64
            if let prev = previous, prev.isOnline == isOnline {
                lastChanged = prev.lastChangedUnix
            } else {
                lastChanged = nowUnix
            }
            peers[node.nodeId] = FleetPeer(
                nodeId: node.nodeId,
                hostId: hello?.hostId ?? previous?.hostId,
                displayName: hello?.displayName ?? previous?.displayName ?? node.hostName,
                tailscaleIP: ipv4,
                port: port,
                isOnline: isOnline,
                isSelf: node.nodeId == selfNodeId,
                version: hello?.version ?? previous?.version,
                lastSeenUnix: isOnline ? nowUnix : previous?.lastSeenUnix,
                lastChangedUnix: lastChanged
            )
        }

        // Any peer that vanished from the tailnet list becomes offline.
        for (nodeId, peer) in peers where !seenIds.contains(nodeId) && peer.isOnline {
            peers[nodeId] = FleetPeer(
                nodeId: peer.nodeId,
                hostId: peer.hostId,
                displayName: peer.displayName,
                tailscaleIP: peer.tailscaleIP,
                port: peer.port,
                isOnline: false,
                isSelf: peer.isSelf,
                version: peer.version,
                lastSeenUnix: peer.lastSeenUnix,
                lastChangedUnix: nowUnix
            )
        }

        broadcast()
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.config.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    private func broadcast() {
        let snap = snapshot()
        for (_, continuation) in subscribers {
            continuation.yield(snap)
        }
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
