import Foundation
import XCTest
@testable import CMUXFleet

/// Probe whose status() output can be swapped at runtime, for testing
/// transitions (peer appears, peer disappears).
final class MutableStubProbe: TailscaleProbe, @unchecked Sendable {
    var currentStatus: TailscaleStatus
    var currentWhois: TailscaleWhois?

    init(status: TailscaleStatus, whois: TailscaleWhois?) {
        self.currentStatus = status
        self.currentWhois = whois
    }

    func status() async throws -> TailscaleStatus { currentStatus }
    func whois(host: String, port: UInt16) async throws -> TailscaleWhois {
        guard let whois = currentWhois else {
            throw TailscaleProbeError.commandFailed(exitCode: 1, stderr: "no whois")
        }
        return whois
    }
}

/// Pretends every peer responds with a canned /v1/hello. Lets us test the
/// registry without spinning up multiple FleetService instances.
struct FixedFleetClient: FleetClient {
    let responses: [String: FleetHelloResponse]
    var workspaceResponses: [String: FleetWorkspacesResponse] = [:]

    func hello(host: String, port: UInt16, timeout: TimeInterval) async throws -> FleetHelloResponse {
        if let resp = responses[host] {
            return resp
        }
        throw FleetClientError.timeout
    }

    func workspaces(host: String, port: UInt16, timeout: TimeInterval) async throws -> FleetWorkspacesResponse {
        if let resp = workspaceResponses[host] {
            return resp
        }
        throw FleetClientError.timeout
    }
}

/// Monotonically increasing clock injected into FleetPeerRegistry tests so
/// `lastChangedUnix` checks see distinct values between ticks when state moves.
final class NowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64
    init(start: Int64) { self.current = start }
    @Sendable func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        let value = current
        current += 1
        return Date(timeIntervalSince1970: TimeInterval(value))
    }
}

final class FleetPeerRegistryTests: XCTestCase {
    private static let userId: Int64 = 1234

    private func makeNode(nodeId: String, hostName: String, ip: String, userId: Int64? = userId, online: Bool = true) -> TailscaleNode {
        TailscaleNode(
            nodeId: nodeId,
            hostName: hostName,
            dnsName: "\(hostName).ts.net.",
            tailscaleIPs: [ip],
            online: online,
            userId: userId,
            lastSeenUnix: nil
        )
    }

    private func makeStatus(self selfNode: TailscaleNode, peers: [TailscaleNode]) -> TailscaleStatus {
        TailscaleStatus(
            selfNode: selfNode,
            peers: peers,
            users: [Self.userId: TailscaleUser(id: Self.userId, loginName: "me", displayName: "Me")]
        )
    }

    func testDiscoversOnlinePeerInSameTailnet() async throws {
        let me = makeNode(nodeId: "n-me", hostName: "me", ip: "100.0.0.1")
        let peer = makeNode(nodeId: "n-peer", hostName: "peer", ip: "100.0.0.2")
        let probe = MutableStubProbe(
            status: makeStatus(self: me, peers: [peer]),
            whois: nil
        )
        let client = FixedFleetClient(responses: [
            "100.0.0.1": FleetHelloResponse(
                schemaVersion: 1,
                hostId: UUID(),
                displayName: "me",
                version: "1.0"
            ),
            "100.0.0.2": FleetHelloResponse(
                schemaVersion: 1,
                hostId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                displayName: "peer-display",
                version: "1.0"
            ),
        ])

        let registry = FleetPeerRegistry(
            probe: probe,
            client: client,
            config: FleetPeerRegistryConfig(pollInterval: 60, probeTimeout: 1)
        )
        await registry.tick()
        let snap = await registry.snapshot()

        XCTAssertEqual(snap.count, 2)
        let peerEntry = try XCTUnwrap(snap.first { $0.nodeId == "n-peer" })
        XCTAssertTrue(peerEntry.isOnline)
        XCTAssertFalse(peerEntry.isSelf)
        XCTAssertEqual(peerEntry.displayName, "peer-display")
        XCTAssertEqual(peerEntry.hostId?.uuidString, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")

        let selfEntry = try XCTUnwrap(snap.first { $0.nodeId == "n-me" })
        XCTAssertTrue(selfEntry.isSelf)
        XCTAssertTrue(selfEntry.isOnline)
    }

    func testSkipsPeersFromDifferentTailnet() async throws {
        let me = makeNode(nodeId: "n-me", hostName: "me", ip: "100.0.0.1")
        let foreign = makeNode(nodeId: "n-foreign", hostName: "foreign", ip: "100.0.0.3", userId: 9999)
        let probe = MutableStubProbe(
            status: makeStatus(self: me, peers: [foreign]),
            whois: nil
        )
        let client = FixedFleetClient(responses: [
            "100.0.0.1": FleetHelloResponse(schemaVersion: 1, hostId: UUID(), displayName: "me", version: "1.0"),
        ])

        let registry = FleetPeerRegistry(
            probe: probe,
            client: client,
            config: FleetPeerRegistryConfig(pollInterval: 60, probeTimeout: 1)
        )
        await registry.tick()
        let snap = await registry.snapshot()

        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.nodeId, "n-me")
    }

    func testPeerWithNoHelloResponseMarkedOffline() async throws {
        let me = makeNode(nodeId: "n-me", hostName: "me", ip: "100.0.0.1")
        let unreachable = makeNode(nodeId: "n-down", hostName: "down", ip: "100.0.0.4")
        let probe = MutableStubProbe(
            status: makeStatus(self: me, peers: [unreachable]),
            whois: nil
        )
        let client = FixedFleetClient(responses: [
            "100.0.0.1": FleetHelloResponse(schemaVersion: 1, hostId: UUID(), displayName: "me", version: "1.0"),
            // 100.0.0.4 is intentionally absent → client.hello throws timeout
        ])

        let registry = FleetPeerRegistry(
            probe: probe,
            client: client,
            config: FleetPeerRegistryConfig(pollInterval: 60, probeTimeout: 1)
        )
        await registry.tick()
        let snap = await registry.snapshot()

        let down = try XCTUnwrap(snap.first { $0.nodeId == "n-down" })
        XCTAssertFalse(down.isOnline)
        XCTAssertNil(down.hostId)
        XCTAssertEqual(down.displayName, "down")
    }

    func testPeerThatVanishesBetweenTicksGreysOut() async throws {
        let me = makeNode(nodeId: "n-me", hostName: "me", ip: "100.0.0.1")
        let peer = makeNode(nodeId: "n-peer", hostName: "peer", ip: "100.0.0.2")
        let probe = MutableStubProbe(
            status: makeStatus(self: me, peers: [peer]),
            whois: nil
        )
        let client = FixedFleetClient(responses: [
            "100.0.0.1": FleetHelloResponse(schemaVersion: 1, hostId: UUID(), displayName: "me", version: "1.0"),
            "100.0.0.2": FleetHelloResponse(schemaVersion: 1, hostId: UUID(), displayName: "peer", version: "1.0"),
        ])

        let registry = FleetPeerRegistry(
            probe: probe,
            client: client,
            config: FleetPeerRegistryConfig(pollInterval: 60, probeTimeout: 1)
        )
        await registry.tick()
        let peerEntryBefore = await registry.snapshot().first { $0.nodeId == "n-peer" }
        XCTAssertEqual(peerEntryBefore?.isOnline, true)

        // Peer vanishes from the tailnet entirely.
        probe.currentStatus = makeStatus(self: me, peers: [])
        await registry.tick()
        let after = await registry.snapshot()
        let entry = try XCTUnwrap(after.first { $0.nodeId == "n-peer" })
        XCTAssertFalse(entry.isOnline)
        XCTAssertEqual(entry.displayName, "peer", "display name should be retained for greyed-out peer")
    }

    func testIdenticalTickDoesNotChangeLastChanged() async throws {
        let me = makeNode(nodeId: "n-me", hostName: "me", ip: "100.0.0.1")
        let probe = MutableStubProbe(
            status: makeStatus(self: me, peers: []),
            whois: nil
        )
        let hello = FleetHelloResponse(
            schemaVersion: 1,
            hostId: UUID(),
            displayName: "me",
            version: "1.0"
        )
        let client = FixedFleetClient(responses: ["100.0.0.1": hello])

        let counter = NowCounter(start: 1_700_000_000)
        let registry = FleetPeerRegistry(
            probe: probe,
            client: client,
            config: FleetPeerRegistryConfig(pollInterval: 60, probeTimeout: 1),
            now: counter.next
        )

        await registry.tick()
        let firstSnap = await registry.snapshot()
        let first = try XCTUnwrap(firstSnap.first)
        let firstChanged = first.lastChangedUnix

        await registry.tick()
        let secondSnap = await registry.snapshot()
        let second = try XCTUnwrap(secondSnap.first)

        XCTAssertEqual(second.lastChangedUnix, firstChanged,
                       "lastChangedUnix must not move when state is unchanged")
    }

    func testSubscriberReceivesUpdates() async throws {
        let me = makeNode(nodeId: "n-me", hostName: "me", ip: "100.0.0.1")
        let probe = MutableStubProbe(
            status: makeStatus(self: me, peers: []),
            whois: nil
        )
        let client = FixedFleetClient(responses: [
            "100.0.0.1": FleetHelloResponse(schemaVersion: 1, hostId: UUID(), displayName: "me", version: "1.0"),
        ])

        let registry = FleetPeerRegistry(
            probe: probe,
            client: client,
            config: FleetPeerRegistryConfig(pollInterval: 60, probeTimeout: 1)
        )

        var iterator = await registry.subscribe().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        await registry.tick()
        let updated = await iterator.next()
        XCTAssertEqual(updated?.count, 1)
        XCTAssertEqual(updated?.first?.nodeId, "n-me")
    }
}
