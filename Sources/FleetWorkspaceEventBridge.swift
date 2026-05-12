import CMUXFleet
import Combine
import Foundation

/// Watches `TabManager.tabs` (and each `Workspace`'s `objectWillChange`),
/// diffs successive snapshots, and publishes the minimal set of
/// `workspace.added` / `workspace.removed` / `workspace.updated` envelopes
/// to the fleet broadcaster so connected peers see lifecycle in real time
/// instead of waiting for the 10s peer-discovery poll.
///
/// Events are serialized through an `AsyncStream` so the wire order matches
/// the order in which we observed the local changes — the broadcaster
/// assigns sequence numbers in `publish()`, so out-of-order Task scheduling
/// would corrupt the seq monotonicity.
@MainActor
final class FleetWorkspaceEventBridge {
    private let broadcaster: FleetEventBroadcaster
    private let tabManager: TabManager
    private var tabsCancellable: AnyCancellable?
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var lastSnapshot: [String: RemoteWorkspace] = [:]
    private let stream: AsyncStream<FleetEvent>
    private let continuation: AsyncStream<FleetEvent>.Continuation
    private var pumpTask: Task<Void, Never>?
    private var started = false

    init(broadcaster: FleetEventBroadcaster, tabManager: TabManager) {
        self.broadcaster = broadcaster
        self.tabManager = tabManager
        let (stream, continuation) = AsyncStream<FleetEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func start() {
        guard !started else { return }
        started = true

        let broadcaster = self.broadcaster
        pumpTask = Task { [stream] in
            for await event in stream {
                let envelope = await broadcaster.publish(event)
#if DEBUG
                let summary: String
                switch event {
                case .workspaceAdded(let w): summary = "added id=\(w.id) name=\(w.name)"
                case .workspaceRemoved(let id): summary = "removed id=\(id)"
                case .workspaceUpdated(let w): summary = "updated id=\(w.id) name=\(w.name)"
                }
                cmuxDebugLog("fleet.event seq=\(envelope.seq) \(summary)")
#endif
            }
        }

        // Seed snapshot without emitting events; subscribers seed via
        // /v1/workspaces and only need diffs from this point forward.
        lastSnapshot = Self.snapshot(tabManager: tabManager)
        for workspace in tabManager.tabs {
            subscribeWorkspace(workspace)
        }

        tabsCancellable = tabManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
    }

    func stop() {
        tabsCancellable = nil
        workspaceCancellables.removeAll()
        continuation.finish()
        pumpTask?.cancel()
        pumpTask = nil
        started = false
    }

    private func subscribeWorkspace(_ workspace: Workspace) {
        if workspaceCancellables[workspace.id] != nil { return }
        let cancellable = workspace.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
        workspaceCancellables[workspace.id] = cancellable
    }

    /// `objectWillChange` fires synchronously before the new value is
    /// assigned, so dispatch to the next runloop tick to read the post-change
    /// state.
    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let next = Self.snapshot(tabManager: tabManager)
        let prev = lastSnapshot

        for (id, _) in prev where next[id] == nil {
            continuation.yield(.workspaceRemoved(workspaceId: id))
        }
        for (id, workspace) in next {
            if let oldWorkspace = prev[id] {
                if oldWorkspace != workspace {
                    continuation.yield(.workspaceUpdated(workspace))
                }
            } else {
                continuation.yield(.workspaceAdded(workspace))
            }
        }

        lastSnapshot = next

        // Refresh per-workspace subscriptions: add for new tabs, drop for closed ones.
        let liveIds = Set(tabManager.tabs.map(\.id))
        for id in workspaceCancellables.keys where !liveIds.contains(id) {
            workspaceCancellables.removeValue(forKey: id)
        }
        for workspace in tabManager.tabs where workspaceCancellables[workspace.id] == nil {
            subscribeWorkspace(workspace)
        }
    }

    static func snapshot(tabManager: TabManager) -> [String: RemoteWorkspace] {
        let selectedId = tabManager.selectedTabId
        var out: [String: RemoteWorkspace] = [:]
        for workspace in tabManager.tabs {
            let id = workspace.id.uuidString
            out[id] = RemoteWorkspace(
                id: id,
                name: workspace.customTitle ?? workspace.title,
                cwd: workspace.currentDirectory,
                color: workspace.customColor,
                lastActiveAtUnix: nil,
                isAttachedLocally: workspace.id == selectedId
            )
        }
        return out
    }
}
