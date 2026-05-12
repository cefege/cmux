import CMUXFleet
import SwiftUI

/// Sidebar section listing other cmux hosts discovered on the tailnet.
///
/// Pure value-snapshot view: receives `[FleetPeer]` + `[String: [RemoteWorkspace]]`
/// plus closure actions, holds no reference to `FleetPeerRegistry` /
/// `FleetCoordinator`. Subscription lives in the parent (`VerticalTabsSidebar`)
/// so this section and its rows can never re-render from orthogonal store
/// invalidations — see the snapshot-boundary rule in CLAUDE.md and issue #2586.
struct FleetPeersSection: View {
    let peers: [FleetPeer]
    let expandedPeerNodeIds: Set<String>
    let workspacesByPeerNodeId: [String: [RemoteWorkspace]]
    let inFlightFetchNodeIds: Set<String>
    let onTogglePeer: (FleetPeer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            VStack(spacing: 1) {
                ForEach(peers, id: \.nodeId) { peer in
                    FleetPeerRow(
                        peer: peer,
                        isExpanded: expandedPeerNodeIds.contains(peer.nodeId),
                        workspaces: workspacesByPeerNodeId[peer.nodeId],
                        isFetchingWorkspaces: inFlightFetchNodeIds.contains(peer.nodeId),
                        onToggle: { onTogglePeer(peer) }
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(String(localized: "sidebar.fleet.section.title", defaultValue: "Fleet peers"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            Text("\(peers.count)")
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

private struct FleetPeerRow: View {
    let peer: FleetPeer
    let isExpanded: Bool
    let workspaces: [RemoteWorkspace]?
    let isFetchingWorkspaces: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    chevron
                    statusDot
                    Text(peer.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(peer.isOnline ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!peer.isOnline)
            .opacity(peer.isOnline ? 1.0 : 0.5)
            .help(peer.isOnline
                ? String(localized: "sidebar.fleet.peer.online.help",
                                  defaultValue: "Click to view workspaces")
                : String(localized: "sidebar.fleet.peer.offline.help",
                                  defaultValue: "Peer is offline"))
            .accessibilityIdentifier("FleetPeerRow.\(peer.nodeId)")

            if isExpanded && peer.isOnline {
                expandedWorkspaces
                    .padding(.leading, 22)
                    .padding(.trailing, 6)
                    .padding(.bottom, 2)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: isExpanded && peer.isOnline ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 10)
            .opacity(peer.isOnline ? 1.0 : 0.0)
    }

    private var statusDot: some View {
        Circle()
            .fill(peer.isOnline ? Color.green : Color.gray)
            .frame(width: 6, height: 6)
            .overlay(
                Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var expandedWorkspaces: some View {
        if let workspaces = workspaces {
            if workspaces.isEmpty {
                Text(String(localized: "sidebar.fleet.peer.noWorkspaces",
                                     defaultValue: "No workspaces"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspaces, id: \.id) { workspace in
                        FleetRemoteWorkspaceRow(workspace: workspace)
                    }
                }
            }
        } else if isFetchingWorkspaces {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "sidebar.fleet.peer.loading",
                                     defaultValue: "Loading…"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.vertical, 2)
        } else {
            Text(String(localized: "sidebar.fleet.peer.unavailable",
                                 defaultValue: "Could not load workspaces"))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.vertical, 2)
        }
    }
}

private struct FleetRemoteWorkspaceRow: View {
    let workspace: RemoteWorkspace

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 12)
            Text(workspace.name)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier("FleetRemoteWorkspaceRow.\(workspace.id)")
    }
}
