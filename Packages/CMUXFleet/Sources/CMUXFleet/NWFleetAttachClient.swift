import Foundation
import Network

/// `FleetAttachClient` that talks to peers over a raw `NWConnection` instead
/// of `URLSession`. macOS ATS rejects ws:// URLs on Tailscale CGNAT IPs
/// even with NSExceptionDomains entries, so URLSession is a non-starter
/// for cross-host attach. NWConnection has no ATS layer.
///
/// Performs the RFC 6455 upgrade by hand, then frames bytes using the
/// helpers in `FleetWebSocket`. Output handlers are dispatched on a
/// private serial queue; the `events` stream is delivered on the same
/// queue so consumers don't see out-of-order frames.
public final class NWFleetAttachClient: FleetAttachClient, @unchecked Sendable {
    public init() {}

    public func attach(
        host: String,
        port: UInt16,
        workspaceId: String
    ) throws -> FleetAttachSession {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWs = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedWs.isEmpty, port > 0 else {
            throw FleetAttachClientError.invalidURL(host: host, port: port, workspaceId: workspaceId)
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw FleetAttachClientError.invalidURL(host: host, port: port, workspaceId: workspaceId)
        }
        let endpointHost = NWEndpoint.Host(trimmedHost)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(host: endpointHost, port: endpointPort, using: params)

        var continuationRef: AsyncThrowingStream<FleetAttachEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<FleetAttachEvent, Error> { cont in
            continuationRef = cont
        }
        guard let continuation = continuationRef else {
            throw FleetAttachClientError.invalidURL(host: host, port: port, workspaceId: workspaceId)
        }

        let queue = DispatchQueue(label: "cmux.fleet.attachClient.\(UUID().uuidString.prefix(8))")
        let runtime = NWAttachRuntime(
            connection: connection,
            queue: queue,
            host: trimmedHost,
            port: port,
            workspaceId: trimmedWs,
            continuation: continuation
        )
        continuation.onTermination = { [weak runtime] _ in
            runtime?.stop()
        }
        runtime.start()
        // The session must hold the runtime *strongly* — otherwise ARC
        // reclaims it the moment `attach` returns, the NWConnection's
        // stateUpdateHandler hits `[weak self] = nil`, and the
        // connection silently drops before reaching .ready. Caught
        // during cross-host dogfood: every connect logged `[connecting]`
        // then immediately `[disconnected]` with no error frame.
        let strongRuntime = runtime
        return FleetAttachSession(
            workspaceId: trimmedWs,
            events: stream,
            sendText: { @Sendable text in
                let bytes = FleetWebSocket.encodeMaskedText(text)
                strongRuntime.sendFrameSync(bytes)
            },
            close: { @Sendable in
                strongRuntime.stop()
            }
        )
    }
}

/// Internal state machine for a single NWConnection-backed attach.
/// Lifecycle: `start()` → wait for connection ready → write the HTTP
/// upgrade request → parse the 101 response → enter the frame loop.
/// Any unrecoverable error finishes the continuation with the error.
final class NWAttachRuntime: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let host: String
    let port: UInt16
    let workspaceId: String

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<FleetAttachEvent, Error>.Continuation?
    private var stopped = false
    private var pendingHandshakeBuffer = Data()
    private var streamBuffer = Data()
    private var inFrameLoop = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        host: String,
        port: UInt16,
        workspaceId: String,
        continuation: AsyncThrowingStream<FleetAttachEvent, Error>.Continuation
    ) {
        self.connection = connection
        self.queue = queue
        self.host = host
        self.port = port
        self.workspaceId = workspaceId
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        if already { return }
        connection.cancel()
        cont?.finish()
    }

    func sendFrameSync(_ data: Data) {
        guard !isStopped() else { return }
        let sent = DispatchSemaphore(value: 0)
        let errorBox = SendErrorBox()
        connection.send(content: data, completion: .contentProcessed { error in
            errorBox.set(error)
            sent.signal()
        })
        _ = sent.wait(timeout: .now() + 5)
        if let sendError = errorBox.get() {
            finish(throwing: sendError)
        }
    }

    private func isStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendUpgradeRequest()
            scheduleHandshakeRead()
        case .failed(let error):
            finish(throwing: error)
        case .cancelled:
            finish(throwing: nil)
        default:
            break
        }
    }

    private func sendUpgradeRequest() {
        let clientKey = FleetWebSocket.randomClientKey()
        let hostHeader: String
        if port == 80 {
            hostHeader = host
        } else {
            hostHeader = "\(host):\(port)"
        }
        let path = "/v1/workspaces/\(workspaceId)/attach"
        let request =
            "GET \(path) HTTP/1.1\r\n" +
            "Host: \(hostHeader)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(clientKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "User-Agent: cmux-fleet/1\r\n" +
            "\r\n"
        let bytes = Data(request.utf8)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(throwing: error)
            }
        })
    }

    private func scheduleHandshakeRead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(throwing: error)
                return
            }
            if let data, !data.isEmpty {
                self.pendingHandshakeBuffer.append(data)
                if let separator = self.indexOfHeaderEnd(self.pendingHandshakeBuffer) {
                    let head = self.pendingHandshakeBuffer.subdata(in: 0..<separator)
                    let leftover = separator + 4 <= self.pendingHandshakeBuffer.count
                        ? self.pendingHandshakeBuffer.subdata(in: (separator + 4)..<self.pendingHandshakeBuffer.count)
                        : Data()
                    self.processHandshakeHead(head: head, leftover: leftover)
                    return
                }
            }
            if isComplete {
                self.finish(throwing: FleetAttachClientError.alreadyClosed)
                return
            }
            self.scheduleHandshakeRead()
        }
    }

    private func indexOfHeaderEnd(_ buffer: Data) -> Int? {
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard buffer.count >= needle.count else { return nil }
        return buffer.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let end = buffer.count - needle.count
            for i in 0...end {
                if bytes[i] == needle[0] && bytes[i + 1] == needle[1] && bytes[i + 2] == needle[2] && bytes[i + 3] == needle[3] {
                    return i
                }
            }
            return nil
        }
    }

    private func processHandshakeHead(head: Data, leftover: Data) {
        guard let header = String(data: head, encoding: .utf8) else {
            finish(throwing: FleetAttachClientError.alreadyClosed)
            return
        }
        let firstLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        // Expect "HTTP/1.1 101 Switching Protocols" or similar.
        guard firstLine.contains("101") else {
            let snippet = firstLine.isEmpty ? "(empty)" : firstLine
            finish(throwing: NWFleetAttachClientError.handshakeFailed(snippet))
            return
        }
        streamBuffer = leftover
        beginFrameLoop()
    }

    private func beginFrameLoop() {
        lock.lock()
        inFrameLoop = true
        lock.unlock()
        drainFrames()
        scheduleFrameRead()
    }

    private func scheduleFrameRead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(throwing: error)
                return
            }
            if let data, !data.isEmpty {
                self.streamBuffer.append(data)
                self.drainFrames()
            }
            if isComplete {
                self.finish(throwing: nil)
                return
            }
            if self.isStopped() { return }
            self.scheduleFrameRead()
        }
    }

    private func drainFrames() {
        while true {
            do {
                guard let decoded = try FleetWebSocket.tryDecode(streamBuffer) else { return }
                if decoded.consumed > 0 {
                    streamBuffer.removeSubrange(0..<decoded.consumed)
                }
                handle(frame: decoded.frame)
            } catch {
                finish(throwing: error)
                return
            }
        }
    }

    private func handle(frame: FleetWebSocketFrame) {
        switch frame.opcode {
        case .text, .binary:
            URLSessionFleetAttachClient.dispatchHostFramePublic(
                frame.payload,
                continuation: snapshotContinuation()
            )
        case .ping:
            connection.send(content: FleetWebSocket.encodePong(payload: frame.payload), completion: .idempotent)
        case .close:
            finish(throwing: nil)
        case .pong, .continuation:
            break
        }
    }

    private func snapshotContinuation() -> AsyncThrowingStream<FleetAttachEvent, Error>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        return continuation
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let already = stopped
        stopped = true
        lock.unlock()
        if !already {
            connection.cancel()
        }
        if let error {
            cont?.finish(throwing: error)
        } else {
            cont?.finish()
        }
    }
}

/// Tiny @Sendable box so the NWConnection send-completion closure can stash
/// an error for the synchronous waiter without tripping the
/// SendableClosureCaptures warning.
final class SendErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func set(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        value = error
    }
    func get() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

enum NWFleetAttachClientError: Error, Sendable, CustomStringConvertible {
    case handshakeFailed(String)
    var description: String {
        switch self {
        case .handshakeFailed(let detail):
            return "WebSocket handshake failed: \(detail)"
        }
    }
}

// MARK: - Bridging helpers

extension URLSessionFleetAttachClient {
    /// Re-exposed under a public name so `NWAttachRuntime` (a separate type
    /// in the same module) can reuse the existing JSON-frame dispatcher
    /// instead of duplicating it.
    static func dispatchHostFramePublic(
        _ payload: Data,
        continuation: AsyncThrowingStream<FleetAttachEvent, Error>.Continuation?
    ) {
        guard let continuation else { return }
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

