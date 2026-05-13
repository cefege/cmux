import Darwin
import Foundation
import XCTest
@testable import CMUXPty

final class CmuxPTYIOTests: XCTestCase {
    func testEchoRoundTripThroughCat() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "cat"]
            )
        )
        defer { reap(pty) }

        let collector = PTYOutputCollector()
        pty.setOutputHandler { collector.append($0) }

        let payload = "ping-from-test\n"
        try payload.withCString { cstr in
            let count = strlen(cstr)
            try cstr.withMemoryRebound(to: UInt8.self, capacity: count) { ptr in
                let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr), count: count)
                try pty.write(raw)
            }
        }

        let arrival = collector.expect("payload echoes back") { data in
            data.containsBytes(of: "ping-from-test")
        }
        wait(for: [arrival], timeout: 2.0)
    }

    func testExitHandlerFiresWithExitCode() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 7"]
            )
        )
        defer { pty.close() }

        let exited = XCTestExpectation(description: "exit handler fires")
        let captured = OSAllocatedUnfairLockBox<CmuxPTYExitStatus?>(value: nil)
        pty.setExitHandler { status in
            captured.set(status)
            exited.fulfill()
        }
        wait(for: [exited], timeout: 3.0)

        guard let status = captured.get() else {
            XCTFail("no exit status captured")
            return
        }
        XCTAssertEqual(status.reason, .exited(code: 7))
    }

    func testTerminateDeliversSIGHUP() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 30"]
            )
        )
        defer { pty.close() }

        let exited = XCTestExpectation(description: "exit fires after SIGHUP")
        let captured = OSAllocatedUnfairLockBox<CmuxPTYExitStatus?>(value: nil)
        pty.setExitHandler { status in
            captured.set(status)
            exited.fulfill()
        }
        pty.terminate()
        wait(for: [exited], timeout: 3.0)

        guard let status = captured.get() else {
            XCTFail("no exit status captured")
            return
        }
        // SIGHUP may be observed either as a signal kill or as a normal exit if
        // the shell traps it. Both are valid for our purposes.
        switch status.reason {
        case .signaled(let sig):
            XCTAssertEqual(sig, SIGHUP)
        case .exited:
            // Shell trapped SIGHUP and exited normally. OK.
            break
        default:
            XCTFail("unexpected exit reason \(status.reason)")
        }
    }
}

/// Tiny lock-protected box for capturing values across closures in tests.
final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(value: Value) { self.value = value }
    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
