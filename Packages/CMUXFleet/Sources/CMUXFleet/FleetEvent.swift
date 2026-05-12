import Foundation

/// Events broadcast by a fleet host when its workspace set changes. Consumed
/// over `/v1/events` so peer UIs don't have to poll `/v1/workspaces`.
///
/// Tagged-union JSON: `{"type": "workspace.added", "workspace": {…}}`.
public enum FleetEvent: Sendable, Equatable {
    case workspaceAdded(RemoteWorkspace)
    case workspaceRemoved(workspaceId: String)
    case workspaceUpdated(RemoteWorkspace)
}

extension FleetEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case workspace
        case workspaceId
    }

    private enum Discriminator: String, Codable {
        case workspaceAdded = "workspace.added"
        case workspaceRemoved = "workspace.removed"
        case workspaceUpdated = "workspace.updated"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Discriminator.self, forKey: .type)
        switch type {
        case .workspaceAdded:
            self = .workspaceAdded(try container.decode(RemoteWorkspace.self, forKey: .workspace))
        case .workspaceRemoved:
            self = .workspaceRemoved(workspaceId: try container.decode(String.self, forKey: .workspaceId))
        case .workspaceUpdated:
            self = .workspaceUpdated(try container.decode(RemoteWorkspace.self, forKey: .workspace))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspaceAdded(let workspace):
            try container.encode(Discriminator.workspaceAdded, forKey: .type)
            try container.encode(workspace, forKey: .workspace)
        case .workspaceRemoved(let id):
            try container.encode(Discriminator.workspaceRemoved, forKey: .type)
            try container.encode(id, forKey: .workspaceId)
        case .workspaceUpdated(let workspace):
            try container.encode(Discriminator.workspaceUpdated, forKey: .type)
            try container.encode(workspace, forKey: .workspace)
        }
    }
}

/// Envelope wrapping every event with the host identity, a per-host monotonic
/// sequence number (so subscribers can detect dropped events on reconnect),
/// and a server clock timestamp.
public struct FleetEventEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostId: UUID
    public let seq: Int64
    public let unixMillis: Int64
    public let event: FleetEvent

    public init(
        schemaVersion: Int = 1,
        hostId: UUID,
        seq: Int64,
        unixMillis: Int64,
        event: FleetEvent
    ) {
        self.schemaVersion = schemaVersion
        self.hostId = hostId
        self.seq = seq
        self.unixMillis = unixMillis
        self.event = event
    }
}

/// Fan-out actor that buffers no history but yields every published envelope
/// to every active subscriber. Subscribers receive events from the moment they
/// subscribed forward; bridging the gap to current state is the client's job
/// (it calls `/v1/workspaces` to seed, then consumes events).
public actor FleetEventBroadcaster {
    private let hostId: UUID
    private let now: @Sendable () -> Date
    private var subscribers: [UUID: AsyncStream<FleetEventEnvelope>.Continuation] = [:]
    private var lastSeq: Int64 = 0

    public init(hostId: UUID, now: @escaping @Sendable () -> Date = Date.init) {
        self.hostId = hostId
        self.now = now
    }

    public func subscribe() -> AsyncStream<FleetEventEnvelope> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    @discardableResult
    public func publish(_ event: FleetEvent) -> FleetEventEnvelope {
        lastSeq &+= 1
        let envelope = FleetEventEnvelope(
            hostId: hostId,
            seq: lastSeq,
            unixMillis: Int64(now().timeIntervalSince1970 * 1000),
            event: event
        )
        for (_, continuation) in subscribers {
            continuation.yield(envelope)
        }
        return envelope
    }

    public func currentSeq() -> Int64 { lastSeq }

    public func subscriberCount() -> Int { subscribers.count }

    public func shutdown() {
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()
    }
}
