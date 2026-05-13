import Foundation
import XCTest
@testable import CMUXFleet

final class FleetAttachClientTests: XCTestCase {
    private static let userId: Int64 = 4242

    private func stubProbe() -> StubTailscaleProbe {
        let node = TailscaleNode(
            nodeId: "n",
            hostName: "host",
            dnsName: "host.ts.net.",
            tailscaleIPs: ["127.0.0.1"],
            online: true,
            userId: Self.userId,
            lastSeenUnix: nil
        )
        return StubTailscaleProbe(
            stubbedStatus: TailscaleStatus(
                selfNode: node,
                peers: [],
                users: [Self.userId: TailscaleUser(id: Self.userId, loginName: "u", displayName: nil)]
            ),
            stubbedWhois: TailscaleWhois(
                node: node,
                user: TailscaleUser(id: Self.userId, loginName: "u", displayName: nil)
            )
        )
    }

    private func makeStorage() throws -> (FleetIdentityFileStorage, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetAttachClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("id.json"))
        return (storage, tempDir)
    }

    func testClientRoundTripsHelloOutputInputResize() async throws {
        let hostUuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try storage.save(FleetIdentity(hostId: hostUuid, displayName: "host", createdAtUnix: 0))

        let provider = LoopbackProvider(knownWorkspaceId: "ws_loop")
        let probe = stubProbe()
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            attachProvider: provider,
            preferredPorts: [0]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let client = URLSessionFleetAttachClient(session: URLSession(configuration: .ephemeral))
        let session = try client.attach(
            host: binding.ip,
            port: binding.port,
            workspaceId: "ws_loop"
        )
        defer { session.close() }

        var iterator = session.events.makeAsyncIterator()

        // Hello.
        let hello = try await XCTUnwrapAsync(iterator.next())
        XCTAssertEqual(hello, .helloReceived(workspaceId: "ws_loop"))

        // Drive output from the host side.
        try await provider.waitForActiveSubscription(timeoutSeconds: 2)
        provider.publish(Data("output-bytes".utf8))
        let event = try await XCTUnwrapAsync(iterator.next())
        XCTAssertEqual(event, .outputReceived(Data("output-bytes".utf8)))

        // Ship input + resize back through the client.
        try await session.sendInput(Data("hi-host".utf8))
        try await session.sendResize(cols: 110, rows: 36)

        try await waitForCondition(timeoutSeconds: 2) {
            !provider.capturedInputs.isEmpty && !provider.capturedResizes.isEmpty
        }
        XCTAssertEqual(provider.capturedInputs, [Data("hi-host".utf8)])
        XCTAssertEqual(provider.capturedResizes.first?.0, 110)
        XCTAssertEqual(provider.capturedResizes.first?.1, 36)
    }

    func testClientReceivesNotFoundForUnknownWorkspace() async throws {
        let hostUuid = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try storage.save(FleetIdentity(hostId: hostUuid, displayName: "host", createdAtUnix: 0))

        let probe = stubProbe()
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            attachProvider: NoopWorkspaceAttachProvider(),
            preferredPorts: [0]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let client = URLSessionFleetAttachClient(session: URLSession(configuration: .ephemeral))
        let session = try client.attach(
            host: binding.ip,
            port: binding.port,
            workspaceId: "missing"
        )
        defer { session.close() }

        var iterator = session.events.makeAsyncIterator()
        let event = try await XCTUnwrapAsync(iterator.next())
        XCTAssertEqual(event, .notFound(workspaceId: "missing"))
    }

    // MARK: - Helpers

    private func XCTUnwrapAsync<T>(_ value: T?, _ message: @autoclosure () -> String = "") async throws -> T {
        guard let value = value else {
            throw NSError(domain: "FleetAttachClientTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message().isEmpty ? "value was nil" : message()
            ])
        }
        return value
    }

    private func waitForCondition(
        timeoutSeconds: Double,
        condition: @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline {
                throw NSError(domain: "FleetAttachClientTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "condition not met within \(timeoutSeconds)s"
                ])
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

/// Same shape as the test-private stub in FleetAttachRouteTests but
/// internally visible — this file lives next to it in the same target,
/// so any duplication would conflict at link time. Kept self-contained
/// here so the client-side tests don't depend on test ordering.
private final class LoopbackProvider: WorkspaceAttachProvider, @unchecked Sendable {
    private let knownWorkspaceId: String
    private let lock = NSLock()
    private var activeHandler: (@Sendable (Data) -> Void)?
    private var inputs: [Data] = []
    private var resizes: [(UInt16, UInt16)] = []

    init(knownWorkspaceId: String) {
        self.knownWorkspaceId = knownWorkspaceId
    }

    func subscribe(
        workspaceId: String,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async -> AttachSubscription? {
        guard workspaceId == knownWorkspaceId else { return nil }
        setHandler(onOutput)
        return AttachSubscription(
            unsubscribe: { [weak self] in self?.setHandler(nil) },
            inputSink: { [weak self] data in self?.recordInput(data) },
            resizeSink: { [weak self] cols, rows in self?.recordResize(cols: cols, rows: rows) }
        )
    }

    func publish(_ bytes: Data) {
        let handler = currentHandler()
        handler?(bytes)
    }

    var hasActiveSubscription: Bool { currentHandler() != nil }

    var capturedInputs: [Data] {
        lock.lock(); defer { lock.unlock() }
        return inputs
    }

    var capturedResizes: [(UInt16, UInt16)] {
        lock.lock(); defer { lock.unlock() }
        return resizes
    }

    func waitForActiveSubscription(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !hasActiveSubscription {
            if Date() >= deadline {
                throw NSError(domain: "FleetAttachClientTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "no subscription within \(timeoutSeconds)s"
                ])
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func setHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock(); activeHandler = handler; lock.unlock()
    }
    private func currentHandler() -> (@Sendable (Data) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return activeHandler
    }
    private func recordInput(_ data: Data) {
        lock.lock(); inputs.append(data); lock.unlock()
    }
    private func recordResize(cols: UInt16, rows: UInt16) {
        lock.lock(); resizes.append((cols, rows)); lock.unlock()
    }
}
