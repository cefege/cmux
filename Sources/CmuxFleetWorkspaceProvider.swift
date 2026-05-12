import CMUXFleet
import Foundation

/// Bridges cmux's local `TabManager.tabs` into the wire shape used by the
/// `/v1/workspaces` endpoint. Looks up the live TabManager through
/// `AppDelegate.shared` on every call so it works even when the fleet
/// service starts before `AppDelegate.configure(tabManager:...)` runs.
final class CmuxFleetWorkspaceProvider: FleetWorkspaceProvider, @unchecked Sendable {
    func currentWorkspaces() async -> [RemoteWorkspace] {
        await MainActor.run {
            guard let tm = AppDelegate.shared?.tabManager else { return [] }
            let selectedId = tm.selectedTabId
            return tm.tabs.map { workspace in
                RemoteWorkspace(
                    id: workspace.id.uuidString,
                    name: workspace.customTitle ?? workspace.title,
                    cwd: workspace.currentDirectory,
                    color: workspace.customColor,
                    lastActiveAtUnix: nil,
                    isAttachedLocally: workspace.id == selectedId
                )
            }
        }
    }
}
