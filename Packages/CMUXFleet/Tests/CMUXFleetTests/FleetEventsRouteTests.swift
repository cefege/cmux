import Foundation
import XCTest
@testable import CMUXFleet

final class FleetEventsRouteTests: XCTestCase {
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
            .appendingPathComponent("FleetEventsRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("id.json"))
        return (storage, tempDir)
    }

    func testWebSocketDeliversPublishedEvents() async throws {
        let hostUuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try storage.save(FleetIdentity(hostId: hostUuid, displayName: "host", createdAtUnix: 0))

        let probe = stubProbe()
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            preferredPorts: [0]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        guard let broadcaster = await coordinator.eventBroadcaster() else {
            XCTFail("expected broadcaster after start")
            return
        }

        // Connect a real WS client.
        let url = URL(string: "ws://\(binding.ip):\(binding.port)/v1/events")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()

        // Publish a couple of events. Give the listener a moment to upgrade.
        try await Task.sleep(nanoseconds: 200_000_000)
        let workspace = RemoteWorkspace(
            id: "ws_1",
            name: "live",
            cwd: nil,
            color: nil,
            lastActiveAtUnix: nil,
            isAttachedLocally: false
        )
        await broadcaster.publish(.workspaceAdded(workspace))
        await broadcaster.publish(.workspaceRemoved(workspaceId: "ws_1"))

        // Read two frames.
        var received: [FleetEventEnvelope] = []
        for _ in 0..<2 {
            let message = try await task.receive()
            guard case .string(let text) = message else {
                XCTFail("expected text frame, got \(message)")
                return
            }
            let envelope = try JSONDecoder().decode(FleetEventEnvelope.self, from: Data(text.utf8))
            received.append(envelope)
        }
        task.cancel(with: .normalClosure, reason: nil)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].hostId, hostUuid)
        XCTAssertEqual(received[0].seq, 1)
        XCTAssertEqual(received[1].seq, 2)
        if case .workspaceAdded(let w) = received[0].event {
            XCTAssertEqual(w.id, "ws_1")
        } else {
            XCTFail("expected workspaceAdded event")
        }
        if case .workspaceRemoved(let id) = received[1].event {
            XCTAssertEqual(id, "ws_1")
        } else {
            XCTFail("expected workspaceRemoved event")
        }
    }

    func testForeignTailnetCannotUpgrade() async throws {
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

        let url = URL(string: "ws://\(binding.ip):\(binding.port)/v1/events")!
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
}
