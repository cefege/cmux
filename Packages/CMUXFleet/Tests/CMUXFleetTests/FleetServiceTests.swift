import Foundation
import XCTest
@testable import CMUXFleet

/// Returns a pre-configured whois result regardless of input. Lets us drive
/// the service from a loopback test client without needing real Tailscale.
struct StubTailscaleProbe: TailscaleProbe {
    let stubbedStatus: TailscaleStatus
    let stubbedWhois: TailscaleWhois?

    func status() async throws -> TailscaleStatus { stubbedStatus }

    func whois(host: String, port: UInt16) async throws -> TailscaleWhois {
        if let whois = stubbedWhois { return whois }
        throw TailscaleProbeError.commandFailed(exitCode: 1, stderr: "stub: no whois")
    }
}

final class FleetServiceIntegrationTests: XCTestCase {
    private static let testUserId: Int64 = 1234567890
    private static let otherUserId: Int64 = 9999999999

    private func makeProbe(peerUserId: Int64?) -> StubTailscaleProbe {
        let selfNode = TailscaleNode(
            nodeId: "n-self",
            hostName: "self-mac",
            dnsName: "self-mac.tailnet.ts.net.",
            tailscaleIPs: ["127.0.0.1"],
            online: true,
            userId: Self.testUserId,
            lastSeenUnix: nil
        )
        let status = TailscaleStatus(
            selfNode: selfNode,
            peers: [],
            users: [
                Self.testUserId: TailscaleUser(id: Self.testUserId, loginName: "me@example.com", displayName: "Me"),
            ]
        )
        let peerNode = TailscaleNode(
            nodeId: "n-peer",
            hostName: "peer",
            dnsName: "peer.tailnet.ts.net.",
            tailscaleIPs: ["127.0.0.1"],
            online: true,
            userId: peerUserId,
            lastSeenUnix: nil
        )
        let whois: TailscaleWhois? = peerUserId.flatMap { uid in
            TailscaleWhois(
                node: peerNode,
                user: TailscaleUser(id: uid, loginName: "peer@x.com", displayName: nil)
            )
        }
        return StubTailscaleProbe(stubbedStatus: status, stubbedWhois: whois)
    }

    private func startService(
        probe: StubTailscaleProbe,
        handler: @escaping FleetRequestHandler
    ) throws -> FleetService {
        let service = FleetService(
            config: FleetServiceConfig(boundIP: "127.0.0.1", port: 0, version: "test"),
            probe: probe,
            selfUserId: Self.testUserId,
            handler: handler
        )
        _ = try service.start()
        return service
    }

    private func fetch(host: String, port: UInt16, path: String) async throws -> (status: Int, body: Data, headers: [AnyHashable: Any]) {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    func testReturnsHandlerResponseWhenWhoisMatches() async throws {
        let probe = makeProbe(peerUserId: Self.testUserId)
        let service = try startService(probe: probe) { _, _ in
            .json(200, "OK", ["greeting": "hello"])
        }
        defer { service.stop() }

        let (status, body, _) = try await fetch(host: "127.0.0.1", port: service.port, path: "/anything")
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json?["greeting"], "hello")
    }

    func testRejectsPeerWithDifferentUserId() async throws {
        let probe = makeProbe(peerUserId: Self.otherUserId)
        let service = try startService(probe: probe) { _, _ in
            XCTFail("handler should not be invoked for foreign user")
            return .plainText(200, "OK", "unexpected")
        }
        defer { service.stop() }

        let (status, _, _) = try await fetch(host: "127.0.0.1", port: service.port, path: "/v1/hello")
        XCTAssertEqual(status, 403)
    }

    func testRejectsWhenWhoisFails() async throws {
        let probe = makeProbe(peerUserId: nil)
        let service = try startService(probe: probe) { _, _ in
            XCTFail("handler should not be invoked when whois fails")
            return .plainText(200, "OK", "unexpected")
        }
        defer { service.stop() }

        let (status, _, _) = try await fetch(host: "127.0.0.1", port: service.port, path: "/v1/hello")
        XCTAssertEqual(status, 403)
    }
}

final class FleetCoordinatorPortFallbackTests: XCTestCase {
    private static let userId: Int64 = 4242

    private func makeProbe() -> StubTailscaleProbe {
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
                users: [Self.userId: TailscaleUser(id: Self.userId, loginName: "x", displayName: nil)]
            ),
            stubbedWhois: TailscaleWhois(
                node: node,
                user: TailscaleUser(id: Self.userId, loginName: "x", displayName: nil)
            )
        )
    }

    func testFallsBackToNextPortWhenFirstIsTaken() async throws {
        let probe = makeProbe()
        // Take an ephemeral port first so we know one specific port is in use.
        let blocker = FleetService(
            config: FleetServiceConfig(boundIP: "127.0.0.1", port: 0, version: "test"),
            probe: probe,
            selfUserId: Self.userId,
            handler: { _, _ in .plainText(200, "OK", "") }
        )
        let blockedPort = try blocker.start()
        defer { blocker.stop() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetCoordinatorPortFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storage = FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("id.json"))

        // First preferred port is the one we just blocked; second is ephemeral.
        let coordinator = FleetCoordinator(
            version: "test",
            identityStorage: storage,
            probeFactory: { probe },
            preferredPorts: [blockedPort]
        )
        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        XCTAssertNotEqual(binding.port, blockedPort, "coordinator should have skipped the blocked port")
        XCTAssertGreaterThan(binding.port, 0)
    }
}

final class FleetCoordinatorDefaultRoutesTests: XCTestCase {
    func testHelloEndpointReturnsIdentity() async throws {
        let testUserId: Int64 = 42
        let selfNode = TailscaleNode(
            nodeId: "n-self",
            hostName: "test-host",
            dnsName: "test.ts.net.",
            tailscaleIPs: ["127.0.0.1"],
            online: true,
            userId: testUserId,
            lastSeenUnix: nil
        )
        let status = TailscaleStatus(
            selfNode: selfNode,
            peers: [],
            users: [testUserId: TailscaleUser(id: testUserId, loginName: "me@x.com", displayName: "Me")]
        )
        let whois = TailscaleWhois(
            node: selfNode,
            user: TailscaleUser(id: testUserId, loginName: "me@x.com", displayName: "Me")
        )
        let probe = StubTailscaleProbe(stubbedStatus: status, stubbedWhois: whois)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMUXFleetCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("identity.json"))
        let coordinator = FleetCoordinator(
            version: "test-1.0",
            identityStorage: storage,
            probeFactory: { probe },
            preferredPorts: [0]
        )

        let binding = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        var request = URLRequest(url: URL(string: "http://\(binding.ip):\(binding.port)/v1/hello")!)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["displayName"] as? String, "test-host")
        XCTAssertEqual(json?["version"] as? String, "test-1.0")
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(json?["hostId"] as? String)
    }
}
