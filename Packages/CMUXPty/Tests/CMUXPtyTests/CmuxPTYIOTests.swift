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

    func testWriteEAGAINDoesNotEscape() throws {
        // Verifies the 5.5C/D ring-buffer change: even when the kernel master
        // buffer is full, `write` enqueues the remainder instead of throwing
        // EAGAIN at the caller. We force the kernel buffer to fill by spawning
        // a shell that never reads stdin (`sleep 1` and exit). The slave-side
        // kernel buffer is small (a few KiB on macOS); pushing 64 KiB at it
        // is enough to hit at least one EAGAIN inside `write`.
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 1"]
            )
        )
        defer { reap(pty) }

        // Drain echoed output so the master->slave write path isn't blocked
        // by a full slave->master buffer.
        pty.setOutputHandler { _ in }

        let payload = Data(repeating: 0x41, count: 64 * 1024)
        XCTAssertNoThrow(try payload.withUnsafeBytes { try pty.write($0) })
        // The whole 64 KiB should fit in the 1 MiB ring (kernel buffer +
        // ring combined). Nothing should be dropped.
        XCTAssertEqual(pty.writeBufferDroppedBytes, 0)
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
