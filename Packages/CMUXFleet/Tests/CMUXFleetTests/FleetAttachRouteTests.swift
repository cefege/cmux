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

    func testAttachWebSocketUpgradesAndEchoesWorkspaceId() async throws {
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

        let workspaceId = "ws_target_123"
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
        XCTAssertEqual(payload["type"] as? String, "attach_hello")
        XCTAssertEqual(payload["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(payload["status"] as? String, "stub")

        task.cancel(with: .normalClosure, reason: nil)
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
}
