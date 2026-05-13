import Foundation

/// Event emitted by a `FleetAttachSession` as the server-side state of an
/// attach connection changes. `outputReceived` is the hot path during
/// normal use; the others are lifecycle markers.
public enum FleetAttachEvent: Sendable, Equatable {
    /// Server confirmed it owns the workspace and the channel is live.
    case helloReceived(workspaceId: String)
    /// One chunk of PTY output, already base64-decoded.
    case outputReceived(Data)
    /// Server doesn't have this workspace. The session will close immediately
    /// after emitting this event.
    case notFound(workspaceId: String)
}

public enum FleetAttachClientError: Error, Sendable, Equatable {
    case invalidURL(host: String, port: UInt16, workspaceId: String)
    case alreadyClosed
}

/// Connects to a peer's `/v1/workspaces/{id}/attach` WebSocket, decodes
/// the JSON envelope protocol, and exposes the byte stream as an
/// `AsyncThrowingStream<FleetAttachEvent, Error>`. Callers ship input and
/// resize events back through `sendInput` / `sendResize`. The session
/// holds the underlying socket until `close()` is called or the iteration
/// ends.
public protocol FleetAttachClient: Sendable {
    func attach(
        host: String,
        port: UInt16,
        workspaceId: String
    ) throws -> FleetAttachSession
}

public final class FleetAttachSession: @unchecked Sendable {
    public let workspaceId: String
    public let events: AsyncThrowingStream<FleetAttachEvent, Error>
    private let sendTextHandler: @Sendable (String) async throws -> Void
    private let closeHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var didClose = false

    /// Generic init used by both URLSession-based and NWConnection-based
    /// clients. The transport-specific bits collapse into two closures so
    /// `FleetAttachSession` doesn't know whether it's running on
    /// `URLSessionWebSocketTask` or a raw `NWConnection`.
    init(
        workspaceId: String,
        events: AsyncThrowingStream<FleetAttachEvent, Error>,
        sendText: @escaping @Sendable (String) async throws -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.workspaceId = workspaceId
        self.events = events
        self.sendTextHandler = sendText
        self.closeHandler = close
    }

    /// Forward typing from the local UI to the host's PTY. Bytes are
    /// base64-encoded into the wire envelope; binary opcode would skip
    /// the encode but the server side currently only decodes text frames.
    public func sendInput(_ bytes: Data) async throws {
        try checkOpen()
        let payload: [String: Any] = [
            "type": "in",
            "data": bytes.base64EncodedString(),
        ]
        try await sendJSON(payload)
    }

    /// Forward a grid resize. Server clamps cols/rows above 0; values <=0
    /// are dropped before reaching the PTY.
    public func sendResize(cols: UInt16, rows: UInt16) async throws {
        try checkOpen()
        let payload: [String: Any] = [
            "type": "resize",
            "cols": Int(cols),
            "rows": Int(rows),
        ]
        try await sendJSON(payload)
    }

    public func close() {
        lock.lock()
        let already = didClose
        didClose = true
        lock.unlock()
        if already { return }
        closeHandler()
    }

    deinit { close() }

    private func checkOpen() throws {
        lock.lock(); defer { lock.unlock() }
        if didClose { throw FleetAttachClientError.alreadyClosed }
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await sendTextHandler(text)
    }
}

public struct URLSessionFleetAttachClient: FleetAttachClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func attach(
        host: String,
        port: UInt16,
        workspaceId: String
    ) throws -> FleetAttachSession {
        guard let url = URL(string: "ws://\(host):\(port)/v1/workspaces/\(workspaceId)/attach") else {
            throw FleetAttachClientError.invalidURL(host: host, port: port, workspaceId: workspaceId)
        }
        let task = session.webSocketTask(with: url)
        task.resume()

        var continuationRef: AsyncThrowingStream<FleetAttachEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<FleetAttachEvent, Error> { cont in
            continuationRef = cont
        }
        guard let continuation = continuationRef else {
            task.cancel()
            throw FleetAttachClientError.invalidURL(host: host, port: port, workspaceId: workspaceId)
        }

        let consumer = Task {
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let payload: Data
                    switch message {
                    case .string(let text):
                        payload = Data(text.utf8)
                    case .data(let data):
                        payload = data
                    @unknown default:
                        continue
                    }
                    Self.dispatchHostFrame(payload, continuation: continuation)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            consumer.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }

        return FleetAttachSession(
            workspaceId: workspaceId,
            events: stream,
            sendText: { @Sendable text in
                try await task.send(.string(text))
            },
            close: { @Sendable in
                consumer.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        )
    }

    private static func dispatchHostFrame(
        _ payload: Data,
        continuation: AsyncThrowingStream<FleetAttachEvent, Error>.Continuation
    ) {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload),
            let dict = object as? [String: Any],
            let type = dict["type"] as? String
        else { return }
        switch type {
        case "attach_hello":
            let workspaceId = (dict["workspaceId"] as? String) ?? ""
            continuation.yield(.helloReceived(workspaceId: workspaceId))
        case "out":
            guard let b64 = dict["data"] as? String,
                  let bytes = Data(base64Encoded: b64)
            else { return }
            continuation.yield(.outputReceived(bytes))
        case "not_found":
            let workspaceId = (dict["workspaceId"] as? String) ?? ""
            continuation.yield(.notFound(workspaceId: workspaceId))
            continuation.finish()
        default:
            break
        }
    }
}
