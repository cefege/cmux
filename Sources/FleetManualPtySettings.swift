import Foundation

/// Debug-menu gate for the cmux-owned-PTY surface backend introduced in
/// fleet-phase1 step 5.5. Default off; flipped per-surface at creation time
/// from `TerminalSurface.createSurface`. Lives outside the Ghostty exec path
/// entirely — the toggle is a kill switch in case manual IO regresses typing
/// latency or breaks parity with the EXEC backend during dogfood.
enum FleetManualPtySettings {
    static let enabledKey = "fleetManualPty.enabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}
