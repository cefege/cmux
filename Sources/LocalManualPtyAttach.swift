import CMUXFleet
import CMUXPty
import Foundation

/// Per-surface fan-out for a manual-IO `CmuxPTY`'s output. CmuxPTY exposes a
/// single `setOutputHandler` slot which the local renderer needs to feed
/// Ghostty's `ghostty_surface_process_output`. To also forward bytes to
/// remote attach viewers, `TerminalSurface` installs this broadcast's
/// `dispatch(_:)` as the PTY output handler and registers the renderer
/// closure as the *primary* handler. Peer attach subscribers add and
/// remove themselves with `addSubscriber` / `removeSubscriber`.
///
/// Dispatch runs on CmuxPTY's private stateQueue (the read source's
/// queue). The primary is invoked synchronously to keep typing latency
/// inline; subscriber closures get a `Data` copy because their work
/// (base64-encode + WebSocket send) is async.
final class ManualPtyOutputBroadcast: @unchecked Sendable {
    typealias PrimaryHandler = @Sendable (UnsafeRawBufferPointer) -> Void
    typealias Subscriber = @Sendable (Data) -> Void
    typealias InputSink = @Sendable (Data) -> Void
    typealias ResizeSink = @Sendable (UInt16, UInt16) -> Void

    /// Sinks the attach provider can forward peer-driven input and
    /// resize events through. Set by `TerminalSurface.createSurface`
    /// when wiring the broadcast to the live CmuxPTY; the broadcast
    /// itself doesn't know about CmuxPTY (avoids the cross-package
    /// import). Either or both can be nil for surfaces that don't yet
    /// support peer input.
    private let lock = NSLock()
    private var primary: PrimaryHandler?
    private var subscribers: [UUID: Subscriber] = [:]
    private var inputSink: InputSink?
    private var resizeSink: ResizeSink?

    func setPrimary(_ handler: @escaping PrimaryHandler) {
        lock.lock()
        primary = handler
        lock.unlock()
    }

    func setInputSink(_ handler: @escaping InputSink) {
        lock.lock()
        inputSink = handler
        lock.unlock()
    }

    func setResizeSink(_ handler: @escaping ResizeSink) {
        lock.lock()
        resizeSink = handler
        lock.unlock()
    }

    func currentInputSink() -> InputSink? {
        lock.lock(); defer { lock.unlock() }
        return inputSink
    }

    func currentResizeSink() -> ResizeSink? {
        lock.lock(); defer { lock.unlock() }
        return resizeSink
    }

    @discardableResult
    func addSubscriber(_ handler: @escaping Subscriber) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = handler
        lock.unlock()
        return id
    }

    func removeSubscriber(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }

    /// Forwarded by `TerminalSurface` from CmuxPTY's output handler.
    func dispatch(_ chunk: UnsafeRawBufferPointer) {
        lock.lock()
        let primary = self.primary
        let subs = subscribers
        lock.unlock()
        primary?(chunk)
        guard !subs.isEmpty else { return }
        let copy = Data(chunk)
        for handler in subs.values {
            handler(copy)
        }
    }
}

/// Workspace-id keyed registry of broadcasts. Manual-IO surfaces
/// register on spawn and unregister on teardown so the fleet attach
/// route can look up "give me the local PTY for workspace X" without
/// reaching into UI state.
///
/// When a workspace owns multiple manual-PTY surfaces (split panes),
/// the most recent register wins. Unregister is identity-checked so a
/// stale teardown can't evict a freshly-spawned broadcast that took
/// the slot.
actor LocalManualPtyRegistry {
    static let shared = LocalManualPtyRegistry()

    private var byWorkspace: [UUID: ManualPtyOutputBroadcast] = [:]

    func register(workspaceId: UUID, broadcast: ManualPtyOutputBroadcast) {
        byWorkspace[workspaceId] = broadcast
    }

    func unregister(workspaceId: UUID, broadcast: ManualPtyOutputBroadcast) {
        if let existing = byWorkspace[workspaceId], existing === broadcast {
            byWorkspace.removeValue(forKey: workspaceId)
        }
    }

    func lookup(workspaceId: String) -> ManualPtyOutputBroadcast? {
        guard let uuid = UUID(uuidString: workspaceId) else { return nil }
        return byWorkspace[uuid]
    }

    /// Test-only: number of currently-registered workspaces.
    func registeredCount() -> Int { byWorkspace.count }
}

/// `WorkspaceAttachProvider` that resolves attach requests against the
/// shared `LocalManualPtyRegistry`. Each `subscribe` adds a Data-handler
/// to the matched broadcast and returns an `AttachSubscription` that
/// removes it on close.
struct LocalManualPtyAttachProvider: WorkspaceAttachProvider {
    func subscribe(
        workspaceId: String,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async -> AttachSubscription? {
        guard let broadcast = await LocalManualPtyRegistry.shared.lookup(workspaceId: workspaceId) else {
            return nil
        }
        let id = broadcast.addSubscriber(onOutput)
        let inputSink = broadcast.currentInputSink()
        let resizeSink = broadcast.currentResizeSink()
        return AttachSubscription(
            unsubscribe: { [weak broadcast] in
                broadcast?.removeSubscriber(id)
            },
            inputSink: inputSink,
            resizeSink: resizeSink
        )
    }
}
