import Foundation
import XCTest
@testable import CMUXFleet

final class FleetClientLoopbackTests: XCTestCase {
    private static let userId: Int64 = 42

    private func stubProbe() -> StubTailscaleProbe {
        let node = TailscaleNode(
            nodeId: "n-self",
            hostName: "loopback",
            dnsName: "loopback.ts.net.",
            tailscaleIPs: ["127.0.0.1"],
            online: true,
            userId: Self.userId,
            lastSeenUnix: nil
        )
        return StubTailscaleProbe(
            stubbedStatus: TailscaleStatus(selfNode: node, peers: [], users: [:]),
            stubbedWhois: TailscaleWhois(node: node, user: TailscaleUser(id: Self.userId, loginName: "x", displayName: nil))
        )
    }

    func testHelloDecodesResponse() async throws {
        let probe = stubProbe()
        let identity = FleetIdentity(
            hostId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "test-host",
            createdAtUnix: 0
        )
        let router = FleetRouter()
        await router.register(method: "GET", path: "/v1/hello") { _, _ in
            .json(200, "OK", [
                "schemaVersion": 1,
                "hostId": identity.hostId.uuidString,
                "displayName": identity.displayName,
                "version": "test-2.0",
            ])
        }
        let service = FleetService(
            config: FleetServiceConfig(boundIP: "127.0.0.1", port: 0, version: "test"),
            probe: probe,
            selfUserId: Self.userId,
            handler: await router.makeHandler()
        )
        let port = try service.start()
        defer { service.stop() }

        let client = URLSessionFleetClient()
        let hello = try await client.hello(host: "127.0.0.1", port: port, timeout: 5)

        XCTAssertEqual(hello.schemaVersion, 1)
        XCTAssertEqual(hello.hostId.uuidString, identity.hostId.uuidString)
        XCTAssertEqual(hello.displayName, "test-host")
        XCTAssertEqual(hello.version, "test-2.0")
    }

    func testHelloThrowsOnHTTPError() async throws {
        let probe = stubProbe()
        let router = FleetRouter()
        await router.register(method: "GET", path: "/v1/hello") { _, _ in
            .plainText(500, "Internal Server Error", "boom")
        }
        let service = FleetService(
            config: FleetServiceConfig(boundIP: "127.0.0.1", port: 0, version: "test"),
            probe: probe,
            selfUserId: Self.userId,
            handler: await router.makeHandler()
        )
        let port = try service.start()
        defer { service.stop() }

        let client = URLSessionFleetClient()
        do {
            _ = try await client.hello(host: "127.0.0.1", port: port, timeout: 5)
            XCTFail("expected error")
        } catch FleetClientError.httpStatus(let code) {
            XCTAssertEqual(code, 500)
        }
    }

    func testHelloThrowsOnUnreachable() async {
        let client = URLSessionFleetClient()
        do {
            // Bogus address that nothing listens on.
            _ = try await client.hello(host: "127.0.0.1", port: 1, timeout: 1)
            XCTFail("expected error")
        } catch is FleetClientError {
            // expected
        } catch {
            XCTFail("expected FleetClientError, got \(error)")
        }
    }
}
