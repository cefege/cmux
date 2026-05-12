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
        let coordinator = FleetCoordinator(version: version)
        self.fleetCoordinator = coordinator
        Task.detached(priority: .utility) {
            do {
                let binding = try await coordinator.start()
                fleetLogger.info("Fleet listener ready on \(binding.ip, privacy: .public):\(binding.port, privacy: .public)")
#if DEBUG
                cmuxDebugLog("fleet.start ip=\(binding.ip) port=\(binding.port)")
#endif
            } catch {
                fleetLogger.info("Fleet did not start: \(String(describing: error), privacy: .public)")
#if DEBUG
                cmuxDebugLog("fleet.start.skipped reason=\(String(describing: error))")
#endif
            }
        }
    }
}
