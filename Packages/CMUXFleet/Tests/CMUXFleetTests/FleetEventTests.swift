import Foundation
import XCTest
@testable import CMUXFleet

final class FleetEventTests: XCTestCase {
    private func sampleWorkspace(id: String = "ws_1", name: String = "blog") -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: name,
            cwd: "/Users/me/code/blog",
            color: "#4c71f2",
            lastActiveAtUnix: 1_700_000_500,
            isAttachedLocally: true
        )
    }

    func testEnvelopeRoundTripWorkspaceAdded() throws {
        let envelope = FleetEventEnvelope(
            hostId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            seq: 42,
            unixMillis: 1_700_000_500_000,
            event: .workspaceAdded(sampleWorkspace())
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(FleetEventEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeRoundTripWorkspaceRemoved() throws {
        let envelope = FleetEventEnvelope(
            hostId: UUID(),
            seq: 1,
            unixMillis: 0,
            event: .workspaceRemoved(workspaceId: "ws_gone")
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(FleetEventEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeRoundTripWorkspaceUpdated() throws {
        let envelope = FleetEventEnvelope(
            hostId: UUID(),
            seq: 7,
            unixMillis: 100,
            event: .workspaceUpdated(sampleWorkspace(id: "ws_2", name: "renamed"))
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(FleetEventEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testEventTypeDiscriminator() throws {
        let added = try JSONEncoder().encode(FleetEvent.workspaceAdded(sampleWorkspace()))
        let removed = try JSONEncoder().encode(FleetEvent.workspaceRemoved(workspaceId: "x"))
        let updated = try JSONEncoder().encode(FleetEvent.workspaceUpdated(sampleWorkspace()))
        XCTAssertTrue(String(data: added, encoding: .utf8)!.contains("\"workspace.added\""))
        XCTAssertTrue(String(data: removed, encoding: .utf8)!.contains("\"workspace.removed\""))
        XCTAssertTrue(String(data: updated, encoding: .utf8)!.contains("\"workspace.updated\""))
    }

    func testRejectsUnknownEventType() {
        let json = #"{"type":"workspace.surprise"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(FleetEvent.self, from: json))
    }
}

final class FleetEventBroadcasterTests: XCTestCase {
    private func sampleWorkspace() -> RemoteWorkspace {
        RemoteWorkspace(
            id: "ws_1",
            name: "test",
            cwd: nil,
            color: nil,
            lastActiveAtUnix: nil,
            isAttachedLocally: false
        )
    }

    func testPublishAssignsMonotonicSequenceNumbers() async {
        let hostId = UUID()
        let broadcaster = FleetEventBroadcaster(hostId: hostId)
        let first = await broadcaster.publish(.workspaceAdded(sampleWorkspace()))
        let second = await broadcaster.publish(.workspaceRemoved(workspaceId: "x"))
        let third = await broadcaster.publish(.workspaceUpdated(sampleWorkspace()))
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(third.seq, 3)
        XCTAssertEqual(first.hostId, hostId)
    }

    func testPublishFansOutToActiveSubscribers() async {
        let broadcaster = FleetEventBroadcaster(hostId: UUID())
        let streamA = await broadcaster.subscribe()
        let streamB = await broadcaster.subscribe()

        // Allow the AsyncStreams to register.
        let count = await broadcaster.subscriberCount()
        XCTAssertEqual(count, 2)

        let collectA = Task<[FleetEventEnvelope], Never> {
            var out: [FleetEventEnvelope] = []
            for await env in streamA {
                out.append(env)
                if out.count == 2 { break }
            }
            return out
        }
        let collectB = Task<[FleetEventEnvelope], Never> {
            var out: [FleetEventEnvelope] = []
            for await env in streamB {
                out.append(env)
                if out.count == 2 { break }
            }
            return out
        }

        await broadcaster.publish(.workspaceAdded(sampleWorkspace()))
        await broadcaster.publish(.workspaceRemoved(workspaceId: "x"))

        let resultA = await collectA.value
        let resultB = await collectB.value
        XCTAssertEqual(resultA.map(\.seq), [1, 2])
        XCTAssertEqual(resultB.map(\.seq), [1, 2])
    }

    func testEnvelopeUsesInjectedClock() async {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000.5)
        let broadcaster = FleetEventBroadcaster(hostId: UUID(), now: { fixed })
        let env = await broadcaster.publish(.workspaceRemoved(workspaceId: "x"))
        XCTAssertEqual(env.unixMillis, 1_700_000_000_500)
    }

    func testShutdownEndsActiveSubscriberStreams() async {
        let broadcaster = FleetEventBroadcaster(hostId: UUID())
        let stream = await broadcaster.subscribe()
        let drain = Task<Int, Never> {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }
        // Give the subscribe() registration a moment to take effect.
        for _ in 0..<10 {
            if await broadcaster.subscriberCount() == 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await broadcaster.shutdown()
        let total = await drain.value
        XCTAssertEqual(total, 0)
        let remaining = await broadcaster.subscriberCount()
        XCTAssertEqual(remaining, 0)
    }
}
