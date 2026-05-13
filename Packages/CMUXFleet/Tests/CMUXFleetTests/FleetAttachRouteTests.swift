import Foundation
import XCTest
@testable import CMUXFleet

final class FleetAttachRouteTests: XCTestCase {
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
            .appendingPathComponent("FleetAttachRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("id.json"))
        return (storage, tempDir)
    }

    private func makeCoordinator(
        storage: FleetIdentityFileStorage,
        attachProvider: WorkspaceAttachProvider = NoopWorkspaceAttachProvider()
    ) -> FleetCoordinator {
        let probe = stubProbe()
        return FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            attachProvider: attachProvider,
            preferredPorts: [0]
        )
    }

    func testAttachUnknownWorkspaceReplyNotFound() async throws {
        let hostUuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try storage.save(FleetIdentity(hostId: hostUuid, displayName: "host", createdAtUnix: 0))

        let coordinator = makeCoordinator(storage: storage)
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let workspaceId = "ws_does_not_exist"
        let url = URL(string: "ws://\(binding.ip):\(binding.port)/v1/workspaces/\(workspaceId)/attach")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()

        let message = try await task.receive()
        guard case .string(let text) = message else {
            XCTFail("expected text frame, got \(message)")
            return
        }
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "not_found")
        XCTAssertEqual(payload["workspaceId"] as? String, workspaceId)

        task.cancel(with: .normalClosure, reason: nil)
    }

    func testAttachKnownWorkspaceForwardsOutput() async throws {
        let hostUuid = UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try storage.save(FleetIdentity(hostId: hostUuid, displayName: "host", createdAtUnix: 0))

        let provider = StubWorkspaceAttachProvider(knownWorkspaceId: "ws_live")
        let coordinator = makeCoordinator(storage: storage, attachProvider: provider)
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let url = URL(string: "ws://\(binding.ip):\(binding.port)/v1/workspaces/ws_live/attach")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()

        // First frame should be attach_hello.
        let hello = try await receiveJSONFrame(task: task)
        XCTAssertEqual(hello["type"] as? String, "attach_hello")
        XCTAssertEqual(hello["workspaceId"] as? String, "ws_live")

        // Wait until the host has connected its output sink, then push a
        // payload through it.
        try await provider.waitForActiveSubscription(timeoutSeconds: 2)
        provider.publish(Data("hello-from-host".utf8))

        let out = try await receiveJSONFrame(task: task)
        XCTAssertEqual(out["type"] as? String, "out")
        let b64 = try XCTUnwrap(out["data"] as? String)
        let decoded = Data(base64Encoded: b64)
        XCTAssertEqual(decoded, Data("hello-from-host".utf8))

        // Tear down — confirms the subscription is released cleanly.
        task.cancel(with: .normalClosure, reason: nil)
        try await provider.waitForSubscriptionCleared(timeoutSeconds: 2)
    }

    func testAttachRejectsForeignTailnet() async throws {
        let foreignUserId: Int64 = 99999
        let selfNode = TailscaleNode(
            nodeId: "n-self",
            hostName: "self",
            dnsName: "self.ts.net.",
            tailscaleIPs: ["127.0.0.1"],
            online: true,
            userId: Self.userId,
            lastSeenUnix: nil
        )
        let foreignProbe = StubTailscaleProbe(
            stubbedStatus: TailscaleStatus(
                selfNode: selfNode,
                peers: [],
                users: [Self.userId: TailscaleUser(id: Self.userId, loginName: "me", displayName: nil)]
            ),
            stubbedWhois: TailscaleWhois(
                node: selfNode,
                user: TailscaleUser(id: foreignUserId, loginName: "stranger", displayName: nil)
            )
        )

        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { foreignProbe },
            preferredPorts: [0]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let url = URL(string: "ws://\(binding.ip):\(binding.port)/v1/workspaces/anything/attach")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()

        do {
            _ = try await task.receive()
            XCTFail("expected receive to fail (auth rejected)")
        } catch {
            // Expected — auth rejected before / during upgrade.
        }
        task.cancel()
    }

    // MARK: - Helpers

    private func receiveJSONFrame(task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        guard case .string(let text) = message else {
            throw NSError(domain: "FleetAttachRouteTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected text frame, got \(message)"
            ])
        }
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
}

/// In-test WorkspaceAttachProvider that pretends to host one specific
/// workspace id. Captures the active output handler so tests can drive
/// bytes through and inspect tear-down.
private final class StubWorkspaceAttachProvider: WorkspaceAttachProvider, @unchecked Sendable {
    private let knownWorkspaceId: String
    private let lock = NSLock()
    private var activeHandler: (@Sendable (Data) -> Void)?

    init(knownWorkspaceId: String) {
        self.knownWorkspaceId = knownWorkspaceId
    }

    func subscribe(
        workspaceId: String,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async -> AttachSubscription? {
        guard workspaceId == knownWorkspaceId else { return nil }
        setHandler(onOutput)
        return AttachSubscription { [weak self] in
            self?.setHandler(nil)
        }
    }

    func publish(_ bytes: Data) {
        let handler = currentHandler()
        handler?(bytes)
    }

    var hasActiveSubscription: Bool {
        currentHandler() != nil
    }

    private func setHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock()
        activeHandler = handler
        lock.unlock()
    }

    private func currentHandler() -> (@Sendable (Data) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return activeHandler
    }

    func waitForActiveSubscription(timeoutSeconds: Double) async throws {
        try await waitUntil(timeoutSeconds: timeoutSeconds) { self.hasActiveSubscription }
    }

    func waitForSubscriptionCleared(timeoutSeconds: Double) async throws {
        try await waitUntil(timeoutSeconds: timeoutSeconds) { !self.hasActiveSubscription }
    }

    private func waitUntil(
        timeoutSeconds: Double,
        condition: @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline {
                throw NSError(domain: "FleetAttachRouteTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "condition not met within \(timeoutSeconds)s"
                ])
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
