import Darwin
import XCTest
@testable import CMUXPty

final class CmuxPTYSkeletonTests: XCTestCase {
    func testWinsizeFallback() {
        let ws = Winsize.fallback
        XCTAssertEqual(ws.columns, 80)
        XCTAssertEqual(ws.rows, 24)
    }

    func testSpawnRejectsEmptyExecutablePath() {
        let config = CmuxPTYSpawn(executablePath: "")
        XCTAssertThrowsError(try CmuxPTY.spawn(config)) { error in
            XCTAssertEqual(error as? CmuxPTYError, .commandEmpty)
        }
    }

    func testSpawnThrowsExecFailedForMissingCommand() {
        let config = CmuxPTYSpawn(
            executablePath: "/no/such/program/here",
            arguments: []
        )
        XCTAssertThrowsError(try CmuxPTY.spawn(config)) { error in
            guard let err = error as? CmuxPTYError,
                  case .execFailed(let code) = err else {
                XCTFail("expected .execFailed, got \(error)")
                return
            }
            XCTAssertEqual(code, ENOENT)
        }
    }

    func testSpawnSucceedsForShellSleep() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 30"]
            )
        )
        defer {
            pty.terminate()
            var status: Int32 = 0
            _ = Darwin.waitpid(pty.childPID, &status, 0)
            _ = Darwin.close(pty.masterFD)
        }

        XCTAssertGreaterThan(pty.masterFD, 0)
        XCTAssertGreaterThan(pty.childPID, 0)

        // Master fd should be non-blocking + close-on-exec.
        let flags = fcntl(pty.masterFD, F_GETFL, 0)
        XCTAssertNotEqual(flags, -1)
        XCTAssertEqual(flags & O_NONBLOCK, O_NONBLOCK, "master fd should be non-blocking")

        let fdflags = fcntl(pty.masterFD, F_GETFD, 0)
        XCTAssertNotEqual(fdflags, -1)
        XCTAssertEqual(fdflags & FD_CLOEXEC, FD_CLOEXEC, "master fd should be close-on-exec")
    }
}
