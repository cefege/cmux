import Foundation

/// Workspace metadata shared between fleet peers. Deliberately small — does
/// not carry layout, PTY scrollback, or session state. Just enough to render
/// in the sidebar of another host.
public struct RemoteWorkspace: Codable, Sendable, Equatable {
    public let id: String
    public let hostId: UUID
    public let name: String
    public let cwd: String?
    public let color: String?
    public let lastActiveAtUnix: Int64?
    public let isAttachedLocally: Bool

    public init(
        id: String,
        hostId: UUID,
        name: String,
        cwd: String?,
        color: String?,
        lastActiveAtUnix: Int64?,
        isAttachedLocally: Bool
    ) {
        self.id = id
        self.hostId = hostId
        self.name = name
        self.cwd = cwd
        self.color = color
        self.lastActiveAtUnix = lastActiveAtUnix
        self.isAttachedLocally = isAttachedLocally
    }
}

public struct FleetWorkspacesResponse: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostId: UUID
    public let workspaces: [RemoteWorkspace]

    public init(schemaVersion: Int = 1, hostId: UUID, workspaces: [RemoteWorkspace]) {
        self.schemaVersion = schemaVersion
        self.hostId = hostId
        self.workspaces = workspaces
    }
}

public protocol FleetWorkspaceProvider: Sendable {
    func currentWorkspaces() async -> [RemoteWorkspace]
}

public struct EmptyFleetWorkspaceProvider: FleetWorkspaceProvider {
    public init() {}
    public func currentWorkspaces() async -> [RemoteWorkspace] { [] }
}

public struct StaticFleetWorkspaceProvider: FleetWorkspaceProvider {
    public let workspaces: [RemoteWorkspace]
    public init(_ workspaces: [RemoteWorkspace]) {
        self.workspaces = workspaces
    }
    public func currentWorkspaces() async -> [RemoteWorkspace] {
        workspaces
    }
}
