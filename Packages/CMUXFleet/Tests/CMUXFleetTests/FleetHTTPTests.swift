import XCTest
@testable import CMUXFleet

final class FleetHTTPParserTests: XCTestCase {
    func testParsesSimpleGet() throws {
        let raw = Data("GET /v1/hello HTTP/1.1\r\nHost: 100.0.0.1:9000\r\nUser-Agent: cmux/1\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(try FleetHTTPParser.tryParse(raw))
        XCTAssertEqual(parsed.request.method, "GET")
        XCTAssertEqual(parsed.request.path, "/v1/hello")
        XCTAssertEqual(parsed.request.httpVersion, "HTTP/1.1")
        XCTAssertEqual(parsed.request.headers["host"], "100.0.0.1:9000")
        XCTAssertEqual(parsed.request.headers["user-agent"], "cmux/1")
        XCTAssertEqual(parsed.request.body.count, 0)
        XCTAssertEqual(parsed.consumed, raw.count)
    }

    func testParsesPostWithBody() throws {
        let bodyText = "{\"name\":\"foo\"}"
        let raw = Data("POST /v1/workspaces HTTP/1.1\r\nContent-Length: \(bodyText.utf8.count)\r\nContent-Type: application/json\r\n\r\n\(bodyText)".utf8)
        let parsed = try XCTUnwrap(try FleetHTTPParser.tryParse(raw))
        XCTAssertEqual(parsed.request.method, "POST")
        XCTAssertEqual(String(data: parsed.request.body, encoding: .utf8), bodyText)
    }

    func testReturnsNilWhenHeadersIncomplete() throws {
        let raw = Data("GET /v1/hello HTTP/1.1\r\nHost: 100.0.0.1\r\n".utf8)
        XCTAssertNil(try FleetHTTPParser.tryParse(raw))
    }

    func testReturnsNilWhenBodyIncomplete() throws {
        let raw = Data("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort".utf8)
        XCTAssertNil(try FleetHTTPParser.tryParse(raw))
    }

    func testMalformedRequestLineThrows() {
        let raw = Data("ONLYONEPART\r\n\r\n".utf8)
        XCTAssertThrowsError(try FleetHTTPParser.tryParse(raw))
    }

    func testSerializeIncludesContentLength() {
        let resp = FleetHTTPResponse.json(200, "OK", ["a": 1])
        let data = FleetHTTPParser.serialize(resp)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length:"))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("\r\n\r\n{\"a\":1}"))
    }
}
