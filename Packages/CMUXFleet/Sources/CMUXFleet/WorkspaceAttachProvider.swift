import Foundation

/// Injected by the host app so the fleet attach WS handler can hand off
/// to whatever local subsystem owns the PTY for a given workspace.
///
/// `subscribe` returns an `AttachSubscription` the handler must hold for
/// the lifetime of the upgraded connection — when the handler returns
/// (peer disconnected, frame error, etc.) the subscription is released
/// and the host should stop forwarding bytes.
///
/// Returning `nil` means "I don't have a local manual-IO workspace with
/// that id." The handler will reply with `not_found` and close.
public protocol WorkspaceAttachProvider: Sendable {
    func subscribe(
        workspaceId: String,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async -> AttachSubscription?
}

/// Returned by `WorkspaceAttachProvider.subscribe`. Releasing the
/// subscription (either explicitly via `close()` or by dropping the last
/// reference) tells the host to detach the output sink.
public final class AttachSubscription: @unchecked Sendable {
    private let unsubscribe: @Sendable () -> Void
    private let lock = NSLock()
    private var didClose = false

    public init(unsubscribe: @escaping @Sendable () -> Void) {
        self.unsubscribe = unsubscribe
    }

    public func close() {
        lock.lock()
        let already = didClose
        didClose = true
        lock.unlock()
        if !already { unsubscribe() }
    }

    deinit { close() }
}

/// Default provider used when no host implementation is supplied. Every
/// lookup returns `nil`, so the attach route safely reports `not_found`
/// for all workspace ids.
public struct NoopWorkspaceAttachProvider: WorkspaceAttachProvider {
    public init() {}
    public func subscribe(
        workspaceId: String,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async -> AttachSubscription? {
        nil
    }
}
