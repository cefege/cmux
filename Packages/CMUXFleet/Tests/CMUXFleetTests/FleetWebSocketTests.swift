import Foundation
import XCTest
@testable import CMUXFleet

final class FleetWebSocketTests: XCTestCase {
    // Known RFC 6455 §1.3 vector: client key + magic GUID → SHA1 → base64.
    func testAcceptKeyKnownVector() {
        let accept = FleetWebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testHandshakeResponseHasSwitchingProtocols() throws {
        let response = try FleetWebSocket.handshakeResponse(forRequestHeaders: [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Version": "13",
            "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
        ])
        XCTAssertEqual(response.status, 101)
        XCTAssertEqual(response.statusText, "Switching Protocols")
        XCTAssertEqual(response.headers["Upgrade"], "websocket")
        XCTAssertEqual(response.headers["Connection"], "Upgrade")
        XCTAssertEqual(response.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testHandshakeRejectsMissingUpgrade() {
        XCTAssertThrowsError(
            try FleetWebSocket.handshakeResponse(forRequestHeaders: [
                "Connection": "keep-alive",
                "Sec-WebSocket-Version": "13",
                "Sec-WebSocket-Key": "abc",
            ])
        ) { err in
            XCTAssertEqual(err as? FleetWebSocketError, .notAnUpgrade)
        }
    }

    func testHandshakeRejectsWrongVersion() {
        XCTAssertThrowsError(
            try FleetWebSocket.handshakeResponse(forRequestHeaders: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Version": "8",
                "Sec-WebSocket-Key": "abc",
            ])
        ) { err in
            XCTAssertEqual(err as? FleetWebSocketError, .unsupportedVersion("8"))
        }
    }

    func testHandshakeAcceptsLowercaseHeaders() throws {
        // FleetHTTPParser stores headers in lowercase. Make sure the helper
        // handles both casings (clients in the wild send mixed cases).
        let response = try FleetWebSocket.handshakeResponse(forRequestHeaders: [
            "upgrade": "WebSocket",
            "connection": "Upgrade",
            "sec-websocket-version": "13",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        ])
        XCTAssertEqual(response.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    // MARK: - Frame encoding

    func testEncodeShortTextFrame() {
        let data = FleetWebSocket.encodeText("Hello")
        // 0x81 = FIN + text opcode, then length=5, then payload.
        XCTAssertEqual([UInt8](data), [0x81, 0x05] + Array("Hello".utf8))
    }

    func testEncodeMediumLengthFrameUses16BitExtended() {
        let payload = Data(repeating: 0xAA, count: 200)
        let frame = FleetWebSocket.encode(FleetWebSocketFrame(
            isFinal: true, opcode: .text, payload: payload
        ))
        XCTAssertEqual(frame[0], 0x81)
        XCTAssertEqual(frame[1], 126)
        XCTAssertEqual(frame[2], 0x00)
        XCTAssertEqual(frame[3], 0xC8) // 200
        XCTAssertEqual(frame.count, 4 + 200)
    }

    func testEncodeCloseFrame() {
        let data = FleetWebSocket.encodeClose(code: 1000, reason: "bye")
        XCTAssertEqual(data[0], 0x88)
        XCTAssertEqual(data[1], UInt8(2 + 3))
        XCTAssertEqual(data[2], 0x03) // (1000 >> 8) & 0xFF
        XCTAssertEqual(data[3], 0xE8) // 1000 & 0xFF
        XCTAssertEqual(Array(data[4...]), Array("bye".utf8))
    }

    // MARK: - Frame decoding

    func testDecodeUnmaskedShortTextFrame() throws {
        let data = FleetWebSocket.encodeText("Hello")
        let result = try FleetWebSocket.tryDecode(data)
        XCTAssertEqual(result?.consumed, data.count)
        XCTAssertEqual(result?.frame.opcode, .text)
        XCTAssertTrue(result?.frame.isFinal ?? false)
        XCTAssertEqual(String(data: result?.frame.payload ?? Data(), encoding: .utf8), "Hello")
    }

    func testDecodeMaskedClientFrame() throws {
        // Construct a masked text frame like a real client would send.
        let payload = "Hello".data(using: .utf8)!
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        var frame = Data([0x81, 0x80 | UInt8(payload.count)] + mask)
        for (i, b) in payload.enumerated() {
            frame.append(b ^ mask[i % 4])
        }
        let result = try FleetWebSocket.tryDecode(frame)
        XCTAssertEqual(String(data: result?.frame.payload ?? Data(), encoding: .utf8), "Hello")
        XCTAssertEqual(result?.consumed, frame.count)
    }

    func testDecodeIncompletePayloadReturnsNil() throws {
        let full = FleetWebSocket.encodeText("Hello")
        let truncated = full.prefix(full.count - 1)
        let result = try FleetWebSocket.tryDecode(Data(truncated))
        XCTAssertNil(result)
    }

    func testDecodeUnknownOpcodeThrows() {
        // Opcode 0x3 is reserved — no parser should accept it.
        let frame = Data([0x83, 0x00])
        XCTAssertThrowsError(try FleetWebSocket.tryDecode(frame)) { err in
            if case .unknownOpcode(let raw) = err as? FleetWebSocketError {
                XCTAssertEqual(raw, 0x3)
            } else {
                XCTFail("expected unknownOpcode, got \(err)")
            }
        }
    }

    func testDecodeRejectsHugeAdvertisedLength() {
        // 127 marker followed by 1 GiB advertised — must reject.
        var frame = Data([0x81, 127])
        frame.append(contentsOf: [0, 0, 0, 0, 0x40, 0, 0, 0])
        XCTAssertThrowsError(try FleetWebSocket.tryDecode(frame)) { err in
            XCTAssertEqual(err as? FleetWebSocketError, .payloadTooLarge)
        }
    }

    func testRoundTripFinAndOpcodePreserved() throws {
        let payloads: [(FleetWebSocketOpcode, Data)] = [
            (.text, Data("event".utf8)),
            (.ping, Data([0x01, 0x02])),
            (.pong, Data([0x03, 0x04])),
            (.close, FleetWebSocket.encodeClose(code: 1011, reason: "internal").suffix(from: 2)),
        ]
        for (opcode, payload) in payloads {
            let encoded = FleetWebSocket.encode(FleetWebSocketFrame(
                isFinal: true, opcode: opcode, payload: payload
            ))
            let decoded = try FleetWebSocket.tryDecode(encoded)
            XCTAssertEqual(decoded?.frame.opcode, opcode)
            XCTAssertTrue(decoded?.frame.isFinal ?? false)
            XCTAssertEqual(decoded?.frame.payload, payload)
        }
    }
}
