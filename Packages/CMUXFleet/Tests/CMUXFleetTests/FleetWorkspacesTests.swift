import Foundation
import XCTest
@testable import CMUXFleet

final class FleetWorkspacesEndpointTests: XCTestCase {
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
            .appendingPathComponent("FleetWorkspacesEndpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("id.json"))
        return (storage, tempDir)
    }

    func testReturnsProviderWorkspacesAndHostId() async throws {
        let hostUuid = UUID(uuidString: "55555555-4444-3333-2222-111111111111")!
        let ws = RemoteWorkspace(
            id: "ws_1",
            name: "blog-redesign",
            cwd: "/Users/me/code/blog",
            color: "#4c71f2",
            lastActiveAtUnix: 1_700_000_500,
            isAttachedLocally: true
        )

        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Pre-seed identity so the route returns a known hostId.
        try storage.save(FleetIdentity(hostId: hostUuid, displayName: "host", createdAtUnix: 0))

        let probe = stubProbe()
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            workspaceProvider: StaticFleetWorkspaceProvider([ws]),
            preferredPorts: [0]
        )

        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let client = URLSessionFleetClient()
        let response = try await client.workspaces(host: binding.ip, port: binding.port, timeout: 5)

        XCTAssertEqual(response.schemaVersion, 1)
        XCTAssertEqual(response.hostId, hostUuid)
        XCTAssertEqual(response.workspaces.count, 1)
        let first = response.workspaces[0]
        XCTAssertEqual(first.id, "ws_1")
        XCTAssertEqual(first.name, "blog-redesign")
        XCTAssertEqual(first.cwd, "/Users/me/code/blog")
        XCTAssertEqual(first.color, "#4c71f2")
        XCTAssertEqual(first.lastActiveAtUnix, 1_700_000_500)
        XCTAssertTrue(first.isAttachedLocally)
    }

    func testEmptyProviderReturnsEmptyList() async throws {
        let (storage, tempDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let probe = stubProbe()
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            preferredPorts: [0]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let response = try await URLSessionFleetClient().workspaces(host: binding.ip, port: binding.port, timeout: 5)
        XCTAssertEqual(response.workspaces.count, 0)
    }

    func testForeignTailnetIsRejected() async throws {
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
        // whois returns a peer from a different tailnet user.
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
            workspaceProvider: StaticFleetWorkspaceProvider([
                RemoteWorkspace(id: "leaky", name: "should-not-be-readable",
                                cwd: nil, color: nil, lastActiveAtUnix: nil, isAttachedLocally: false)
            ]),
            preferredPorts: [0]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let url = URL(string: "http://\(binding.ip):\(binding.port)/v1/workspaces")!
        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 403)
    }
}
