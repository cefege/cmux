import Foundation

/// Client-side `/v1/events` subscriber. Hides `URLSessionWebSocketTask` and
/// JSON decoding behind an `AsyncThrowingStream<FleetEventEnvelope, Error>`
/// so callers can `for try await env in stream { … }`.
public protocol FleetEventsClient: Sendable {
    func subscribe(host: String, port: UInt16) -> AsyncThrowingStream<FleetEventEnvelope, Error>
}

public struct URLSessionFleetEventsClient: FleetEventsClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func subscribe(host: String, port: UInt16) -> AsyncThrowingStream<FleetEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            guard let url = URL(string: "ws://\(host):\(port)/v1/events") else {
                continuation.finish(throwing: FleetClientError.network("invalid url"))
                return
            }
            let task = session.webSocketTask(with: url)
            task.resume()

            let consumer = Task {
                let decoder = JSONDecoder()
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let env = try? decoder.decode(FleetEventEnvelope.self, from: data)
                            {
                                continuation.yield(env)
                            }
                        case .data(let data):
                            if let env = try? decoder.decode(FleetEventEnvelope.self, from: data) {
                                continuation.yield(env)
                            }
                        @unknown default:
                            break
                        }
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
        }
    }
}
