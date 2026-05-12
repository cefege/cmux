import CMUXFleet
import Combine
import Foundation

/// Per-peer cache of `RemoteWorkspace`s populated by seeding from
/// `/v1/workspaces` and then applying live events from `/v1/events`. Replaces
/// the on-expand HTTP fetch the sidebar used to do, so add/rename/remove on a
/// remote host shows up in this Mac's sidebar without waiting for the user to
/// click the peer or for the 10s peer-discovery poll.
@MainActor
final class FleetPeerWorkspacesStore: ObservableObject {
    @Published private(set) var workspacesByNodeId: [String: [RemoteWorkspace]] = [:]
    @Published private(set) var lastErrorByNodeId: [String: String] = [:]

    private struct PeerSession {
        let task: Task<Void, Never>
        let peer: FleetPeer
    }

    private var sessions: [String: PeerSession] = [:]
    private let client: FleetClient
    private let eventsClient: FleetEventsClient
    private let seedTimeout: TimeInterval

    init(
        client: FleetClient = URLSessionFleetClient(),
        eventsClient: FleetEventsClient = URLSessionFleetEventsClient(),
        seedTimeout: TimeInterval = 5
    ) {
        self.client = client
        self.eventsClient = eventsClient
        self.seedTimeout = seedTimeout
    }

    /// Reconciles connection state against a fresh peer snapshot. Online peers
    /// gain a session; peers that just went offline have theirs torn down and
    /// their cache dropped (a stale list would be more confusing than empty).
    func update(peers: [FleetPeer]) {
        let online = peers.filter { $0.isOnline && !$0.isSelf }
        let onlineById = Dictionary(uniqueKeysWithValues: online.map { ($0.nodeId, $0) })

        for nodeId in Array(sessions.keys) {
            guard let stillOnline = onlineById[nodeId] else {
                cancelSession(nodeId: nodeId, dropCache: true)
                continue
            }
            // Reconnect if the peer's tailscaleIP/port changed.
            if let existing = sessions[nodeId]?.peer,
               existing.tailscaleIP != stillOnline.tailscaleIP || existing.port != stillOnline.port
            {
                cancelSession(nodeId: nodeId, dropCache: false)
                startSession(peer: stillOnline)
            }
        }

        for (nodeId, peer) in onlineById where sessions[nodeId] == nil {
            startSession(peer: peer)
        }
    }

    func shutdown() {
        for nodeId in Array(sessions.keys) {
            cancelSession(nodeId: nodeId, dropCache: true)
        }
    }

    private func cancelSession(nodeId: String, dropCache: Bool) {
        sessions[nodeId]?.task.cancel()
        sessions.removeValue(forKey: nodeId)
        if dropCache {
            workspacesByNodeId.removeValue(forKey: nodeId)
            lastErrorByNodeId.removeValue(forKey: nodeId)
        }
    }

    private func startSession(peer: FleetPeer) {
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.runSessionLoop(peer: peer)
        }
        sessions[peer.nodeId] = PeerSession(task: task, peer: peer)
    }

    private func runSessionLoop(peer: FleetPeer) async {
        var backoffSeconds: TimeInterval = 1
        while !Task.isCancelled {
            do {
                let seed = try await client.workspaces(
                    host: peer.tailscaleIP,
                    port: peer.port,
                    timeout: seedTimeout
                )
                workspacesByNodeId[peer.nodeId] = seed.workspaces
                lastErrorByNodeId.removeValue(forKey: peer.nodeId)
                backoffSeconds = 1
                try await consumeEvents(peer: peer)
            } catch {
                if Task.isCancelled { return }
                lastErrorByNodeId[peer.nodeId] = String(describing: error)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    private func consumeEvents(peer: FleetPeer) async throws {
        let stream = eventsClient.subscribe(host: peer.tailscaleIP, port: peer.port)
        for try await envelope in stream {
            if Task.isCancelled { return }
            applyEvent(envelope: envelope, peerNodeId: peer.nodeId)
        }
    }

    private func applyEvent(envelope: FleetEventEnvelope, peerNodeId: String) {
        var workspaces = workspacesByNodeId[peerNodeId] ?? []
        switch envelope.event {
        case .workspaceAdded(let workspace):
            if !workspaces.contains(where: { $0.id == workspace.id }) {
                workspaces.append(workspace)
            }
        case .workspaceRemoved(let id):
            workspaces.removeAll { $0.id == id }
        case .workspaceUpdated(let workspace):
            if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[idx] = workspace
            } else {
                workspaces.append(workspace)
            }
        }
        workspacesByNodeId[peerNodeId] = workspaces
    }
}
