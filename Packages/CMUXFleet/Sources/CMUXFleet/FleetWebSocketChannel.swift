import Foundation
import Network

/// Connection-side WebSocket plumbing for the fleet `/v1/events` route.
///
/// Wraps the post-handshake `NWConnection`, owns the receive buffer / framing,
/// auto-responds to pings, and surfaces only application frames (text/binary)
/// to the handler. A single instance is created per upgraded connection in
/// `FleetService.performUpgrade`.
public final class FleetWebSocketChannel: @unchecked Sendable {
    public typealias OnClose = @Sendable () -> Void

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer: Data
    private var continuation: AsyncThrowingStream<FleetWebSocketFrame, Error>.Continuation?
    private var isClosed = false
    private let onClose: OnClose

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        initialBuffer: Data = Data(),
        onClose: @escaping OnClose = {}
    ) {
        self.connection = connection
        self.queue = queue
        self.buffer = initialBuffer
        self.onClose = onClose
    }

    /// Begins the receive pump and returns an application-frame stream.
    /// Pings are auto-pong'd; close frames terminate the stream cleanly.
    public func start() -> AsyncThrowingStream<FleetWebSocketFrame, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            // Drain any bytes that already arrived alongside the handshake.
            drainBufferedFrames()
            scheduleReceive()
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.finish(throwing: nil, sendCloseFrame: false)
            }
        }
    }

    public func sendText(_ text: String) {
        send(FleetWebSocket.encodeText(text))
    }

    public func close(code: UInt16 = 1000, reason: String = "") {
        finish(throwing: nil, sendCloseFrame: true, closeCode: code, closeReason: reason)
    }

    private func send(_ data: Data) {
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.finish(throwing: error, sendCloseFrame: false)
                return
            }
            if let data = data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                self.lock.unlock()
                self.drainBufferedFrames()
            }
            if isComplete {
                self.finish(throwing: nil, sendCloseFrame: false)
                return
            }
            self.lock.lock()
            let closed = self.isClosed
            self.lock.unlock()
            if !closed {
                self.scheduleReceive()
            }
        }
    }

    private func drainBufferedFrames() {
        while true {
            lock.lock()
            let snapshot = buffer
            lock.unlock()
            do {
                guard let result = try FleetWebSocket.tryDecode(snapshot) else {
                    return
                }
                lock.lock()
                buffer.removeFirst(result.consumed)
                lock.unlock()
                dispatch(result.frame)
            } catch {
                finish(throwing: error, sendCloseFrame: true, closeCode: 1002, closeReason: "frame error")
                return
            }
        }
    }

    private func dispatch(_ frame: FleetWebSocketFrame) {
        switch frame.opcode {
        case .ping:
            send(FleetWebSocket.encodePong(payload: frame.payload))
        case .pong:
            break
        case .close:
            finish(throwing: nil, sendCloseFrame: true, closeCode: 1000, closeReason: "")
        case .text, .binary, .continuation:
            lock.lock()
            let cont = continuation
            lock.unlock()
            cont?.yield(frame)
        }
    }

    private func finish(
        throwing error: Error?,
        sendCloseFrame: Bool,
        closeCode: UInt16 = 1000,
        closeReason: String = ""
    ) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let cont = continuation
        continuation = nil
        lock.unlock()

        if sendCloseFrame {
            connection.send(
                content: FleetWebSocket.encodeClose(code: closeCode, reason: closeReason),
                completion: .contentProcessed { [connection] _ in
                    connection.cancel()
                }
            )
        } else {
            connection.cancel()
        }

        if let error = error {
            cont?.finish(throwing: error)
        } else {
            cont?.finish()
        }
        onClose()
    }
}
