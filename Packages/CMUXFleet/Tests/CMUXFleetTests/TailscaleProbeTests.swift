import XCTest
@testable import CMUXFleet

final class TailscaleStatusParserTests: XCTestCase {
    func testParsesSelfAndUsers() throws {
        let json = """
        {
          "Self": {
            "ID": "nfuVNutxS311CNTRL",
            "HostName": "macbook-air",
            "DNSName": "macbook-air.tail67850e.ts.net.",
            "TailscaleIPs": ["100.112.84.46", "fd7a:115c:a1e0::4a3a:542e"],
            "Online": true,
            "UserID": 7976023928952900,
            "LastSeen": "0001-01-01T00:00:00Z"
          },
          "Peer": {
            "nodekey:abc": {
              "ID": "n6RoyWgJSp11CNTRL",
              "HostName": "iphone",
              "DNSName": "iphone.tail67850e.ts.net.",
              "TailscaleIPs": ["100.86.11.105"],
              "Online": true,
              "UserID": 7976023928952900,
              "LastSeen": "2026-05-12T19:12:17.1Z"
            }
          },
          "User": {
            "7976023928952900": {
              "ID": 7976023928952900,
              "LoginName": "user@example.com",
              "DisplayName": "Mike"
            }
          }
        }
        """.data(using: .utf8)!

        let status = try TailscaleStatusParser.parse(jsonData: json)

        XCTAssertEqual(status.selfNode.nodeId, "nfuVNutxS311CNTRL")
        XCTAssertEqual(status.selfNode.hostName, "macbook-air")
        XCTAssertEqual(status.selfNode.tailscaleIPs, ["100.112.84.46", "fd7a:115c:a1e0::4a3a:542e"])
        XCTAssertEqual(status.selfNode.userId, 7976023928952900)
        XCTAssertNil(status.selfNode.lastSeenUnix, "0001- prefix should map to nil")
        XCTAssertTrue(status.selfNode.online)

        XCTAssertEqual(status.peers.count, 1)
        let peer = status.peers[0]
        XCTAssertEqual(peer.hostName, "iphone")
        XCTAssertNotNil(peer.lastSeenUnix)

        XCTAssertEqual(status.users[7976023928952900]?.loginName, "user@example.com")
        XCTAssertEqual(status.users[7976023928952900]?.displayName, "Mike")
    }

    func testMissingSelfThrows() {
        let json = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try TailscaleStatusParser.parse(jsonData: json))
    }

    func testEmptyPeersIsOK() throws {
        let json = """
        {
          "Self": {
            "ID": "n1",
            "HostName": "a",
            "DNSName": "a.ts.net.",
            "TailscaleIPs": ["100.0.0.1"],
            "Online": true,
            "UserID": 1
          }
        }
        """.data(using: .utf8)!
        let status = try TailscaleStatusParser.parse(jsonData: json)
        XCTAssertEqual(status.peers.count, 0)
        XCTAssertTrue(status.users.isEmpty)
    }

    func testRejectsNonObjectRoot() {
        let json = "[]".data(using: .utf8)!
        XCTAssertThrowsError(try TailscaleStatusParser.parse(jsonData: json))
    }
}

final class TailscaleWhoisParserTests: XCTestCase {
    func testParsesNodeAndUser() throws {
        let json = """
        {
          "Node": {
            "ID": "n6RoyWgJSp11CNTRL",
            "Name": "iphone.tail67850e.ts.net.",
            "ComputedName": "iphone",
            "Addresses": ["100.86.11.105/32", "fd7a:115c:a1e0::1c3a:b6a/128"],
            "User": 7976023928952900
          },
          "UserProfile": {
            "ID": 7976023928952900,
            "LoginName": "user@example.com",
            "DisplayName": "Mike"
          }
        }
        """.data(using: .utf8)!

        let whois = try TailscaleWhoisParser.parse(jsonData: json)
        XCTAssertEqual(whois.node.nodeId, "n6RoyWgJSp11CNTRL")
        XCTAssertEqual(whois.node.tailscaleIPs, ["100.86.11.105", "fd7a:115c:a1e0::1c3a:b6a"])
        XCTAssertEqual(whois.node.userId, 7976023928952900)
        XCTAssertEqual(whois.user?.loginName, "user@example.com")
    }

    func testMissingNodeThrows() {
        let json = #"{"UserProfile": {"ID": 1, "LoginName": "x"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try TailscaleWhoisParser.parse(jsonData: json))
    }
}

final class TailscaleCLILocatorTests: XCTestCase {
    func testResolveReturnsNilWhenNothingExecutable() {
        // FakeFM: nothing is executable
        final class NoneFM: FileManager, @unchecked Sendable {
            override func isExecutableFile(atPath path: String) -> Bool { false }
        }
        XCTAssertNil(TailscaleCLILocator.resolve(fileManager: NoneFM()))
    }

    func testResolvePicksFirstExecutable() {
        final class OnlyHomebrewFM: FileManager, @unchecked Sendable {
            override func isExecutableFile(atPath path: String) -> Bool {
                path == "/opt/homebrew/bin/tailscale"
            }
        }
        XCTAssertEqual(
            TailscaleCLILocator.resolve(fileManager: OnlyHomebrewFM()),
            "/opt/homebrew/bin/tailscale"
        )
    }
}

/// End-to-end check against the real `tailscale` CLI if one is installed.
/// Skipped when no Tailscale binary is on the system so CI without TS still
/// passes.
final class TailscaleCLIProbeIntegrationTests: XCTestCase {
    func testRealStatusReturnsSelfNode() async throws {
        guard let probe = TailscaleCLIProbe() else {
            throw XCTSkip("Tailscale CLI not installed on this host")
        }
        let status = try await probe.status()
        XCTAssertFalse(status.selfNode.nodeId.isEmpty)
        XCTAssertFalse(status.selfNode.tailscaleIPs.isEmpty)
    }
}
