import AppKit
import CMUXFleet
import Foundation
import os

private let fleetLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "Fleet"
)

extension AppDelegate {
    func startFleetCoordinatorIfPossible() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
        let coordinator = FleetCoordinator(
            version: version,
            workspaceProvider: CmuxFleetWorkspaceProvider()
        )
        self.fleetCoordinator = coordinator
        Task.detached(priority: .utility) {
            do {
                let binding = try await coordinator.start()
                fleetLogger.info("Fleet listener ready on \(binding.ip, privacy: .public):\(binding.port, privacy: .public)")
#if DEBUG
                cmuxDebugLog("fleet.start ip=\(binding.ip) port=\(binding.port)")
#endif
                await Self.attachWorkspaceEventBridge(coordinator: coordinator)
                if let stream = await coordinator.peerStream() {
                    for await peers in stream {
                        let online = peers.filter { $0.isOnline }.count
                        fleetLogger.info("Fleet peers: \(peers.count, privacy: .public) total, \(online, privacy: .public) online")
#if DEBUG
                        let summary = peers.map { "\($0.displayName)(\($0.isOnline ? "on" : "off"))" }.joined(separator: ",")
                        cmuxDebugLog("fleet.peers count=\(peers.count) online=\(online) [\(summary)]")
#endif
                    }
                }
            } catch {
                fleetLogger.info("Fleet did not start: \(String(describing: error), privacy: .public)")
#if DEBUG
                cmuxDebugLog("fleet.start.skipped reason=\(String(describing: error))")
#endif
            }
        }
    }

    /// Polls `AppDelegate.shared?.tabManager` until it's been configured by
    /// the app boot path, then mounts the bridge so workspace lifecycle
    /// changes get fanned out to subscribed peers.
    private static func attachWorkspaceEventBridge(coordinator: FleetCoordinator) async {
        guard let broadcaster = await coordinator.eventBroadcaster() else { return }
        for _ in 0..<60 {
            if Task.isCancelled { return }
            let attached = await MainActor.run { () -> Bool in
                guard AppDelegate.shared?.fleetWorkspaceEventBridge == nil,
                      let tm = AppDelegate.shared?.tabManager else { return false }
                let bridge = FleetWorkspaceEventBridge(broadcaster: broadcaster, tabManager: tm)
                bridge.start()
                AppDelegate.shared?.fleetWorkspaceEventBridge = bridge
#if DEBUG
                cmuxDebugLog("fleet.eventBridge.started workspaces=\(tm.tabs.count)")
#endif
                return true
            }
            if attached { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
#if DEBUG
        cmuxDebugLog("fleet.eventBridge.timeout no tabManager after 60s")
#endif
    }
}
