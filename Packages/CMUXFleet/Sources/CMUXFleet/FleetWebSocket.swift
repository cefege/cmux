import CryptoKit
import Foundation

/// Minimal RFC 6455 WebSocket framing for the fleet `/v1/events` endpoint.
///
/// Scope is intentionally narrow:
/// - Unfragmented text/close/ping/pong frames only.
/// - Server-side encode writes unmasked frames (per RFC client→server is masked,
///   server→client is unmasked).
/// - Decode accepts both masked and unmasked frames so the same primitive can
///   be reused for any side that needs to parse the wire format.
public enum FleetWebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public struct FleetWebSocketFrame: Sendable, Equatable {
    public let isFinal: Bool
    public let opcode: FleetWebSocketOpcode
    public let payload: Data

    public init(isFinal: Bool, opcode: FleetWebSocketOpcode, payload: Data) {
        self.isFinal = isFinal
        self.opcode = opcode
        self.payload = payload
    }
}

public enum FleetWebSocketError: Error, Equatable {
    case unknownOpcode(UInt8)
    case payloadTooLarge
    case missingClientKey
    case unsupportedVersion(String?)
    case notAnUpgrade
}

public enum FleetWebSocket {
    /// RFC 6455 magic GUID. The accept key is `base64(SHA1(clientKey + magic))`.
    public static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Reserved cap so a malformed frame can't make us allocate a huge buffer.
    /// Workspace events are tiny; a few KB is plenty.
    public static let maxIncomingPayloadBytes = 1 * 1024 * 1024

    public static func acceptKey(for clientKey: String) -> String {
        let combined = clientKey + magicGUID
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(digest).base64EncodedString()
    }

    /// Validates the request headers and computes the 101 Switching Protocols
    /// response. Header names are matched case-insensitively. Caller is
    /// responsible for actually writing the bytes to the connection.
    public static func handshakeResponse(forRequestHeaders headers: [String: String])
        throws -> FleetHTTPResponse
    {
        // FleetHTTPParser lowercases header names — accept both styles for callers.
        let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let connection = (normalized["connection"] ?? "").lowercased()
        let upgrade = (normalized["upgrade"] ?? "").lowercased()
        guard upgrade.contains("websocket"),
              connection.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade")
        else {
            throw FleetWebSocketError.notAnUpgrade
        }
        let version = normalized["sec-websocket-version"]
        guard version == "13" else {
            throw FleetWebSocketError.unsupportedVersion(version)
        }
        guard let key = normalized["sec-websocket-key"], !key.isEmpty else {
            throw FleetWebSocketError.missingClientKey
        }
        let accept = acceptKey(for: key)
        return FleetHTTPResponse(
            status: 101,
            statusText: "Switching Protocols",
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": accept,
            ],
            body: Data()
        )
    }

    /// Encodes an unmasked frame (server → client). The 101 response and these
    /// frames share the same TCP connection.
    public static func encode(_ frame: FleetWebSocketFrame) -> Data {
        var out = Data()
        let finBit: UInt8 = frame.isFinal ? 0x80 : 0x00
        out.append(finBit | (frame.opcode.rawValue & 0x0F))

        let length = frame.payload.count
        if length < 126 {
            out.append(UInt8(length))
        } else if length <= Int(UInt16.max) {
            out.append(126)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(127)
            let wide = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((wide >> shift) & 0xFF))
            }
        }
        out.append(frame.payload)
        return out
    }

    public static func encodeText(_ text: String, isFinal: Bool = true) -> Data {
        encode(FleetWebSocketFrame(
            isFinal: isFinal,
            opcode: .text,
            payload: Data(text.utf8)
        ))
    }

    public static func encodePing(payload: Data = Data()) -> Data {
        encode(FleetWebSocketFrame(isFinal: true, opcode: .ping, payload: payload))
    }

    public static func encodePong(payload: Data) -> Data {
        encode(FleetWebSocketFrame(isFinal: true, opcode: .pong, payload: payload))
    }

    public static func encodeClose(code: UInt16 = 1000, reason: String = "") -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        if !reason.isEmpty {
            payload.append(Data(reason.utf8))
        }
        return encode(FleetWebSocketFrame(isFinal: true, opcode: .close, payload: payload))
    }

    /// Attempts to decode a single frame from the start of `buffer`. Returns
    /// `nil` if more bytes are needed. Handles masked frames (any side) and
    /// unmasked frames (server → client).
    public static func tryDecode(_ buffer: Data)
        throws -> (frame: FleetWebSocketFrame, consumed: Int)?
    {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let b0 = buffer[start]
        let b1 = buffer[start + 1]

        let isFinal = (b0 & 0x80) != 0
        let rawOpcode = b0 & 0x0F
        guard let opcode = FleetWebSocketOpcode(rawValue: rawOpcode) else {
            throw FleetWebSocketError.unknownOpcode(rawOpcode)
        }
        let isMasked = (b1 & 0x80) != 0
        var cursor = 2
        var length = Int(b1 & 0x7F)

        if length == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            let hi = UInt16(buffer[start + cursor])
            let lo = UInt16(buffer[start + cursor + 1])
            length = Int((hi << 8) | lo)
            cursor += 2
        } else if length == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            var wide: UInt64 = 0
            for i in 0..<8 {
                wide = (wide << 8) | UInt64(buffer[start + cursor + i])
            }
            guard wide <= UInt64(maxIncomingPayloadBytes) else {
                throw FleetWebSocketError.payloadTooLarge
            }
            length = Int(wide)
            cursor += 8
        }

        if length > maxIncomingPayloadBytes {
            throw FleetWebSocketError.payloadTooLarge
        }

        var maskKey: [UInt8] = []
        if isMasked {
            guard buffer.count >= cursor + 4 else { return nil }
            maskKey = [
                buffer[start + cursor],
                buffer[start + cursor + 1],
                buffer[start + cursor + 2],
                buffer[start + cursor + 3],
            ]
            cursor += 4
        }

        guard buffer.count >= cursor + length else { return nil }
        var payload = Data(buffer[(start + cursor)..<(start + cursor + length)])
        if isMasked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        let frame = FleetWebSocketFrame(isFinal: isFinal, opcode: opcode, payload: payload)
        return (frame, cursor + length)
    }
}
