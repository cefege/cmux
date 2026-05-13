import Darwin
import Foundation
import XCTest
@testable import CMUXPty

final class CmuxPTYEnvironmentTests: XCTestCase {
    func testEnvironmentPassesThrough() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf '%s' \"$CMUX_TEST_PROBE\"; exit 0"],
                environment: ["CMUX_TEST_PROBE": "value-7f3a2"]
            )
        )
        defer { reap(pty) }

        let collector = PTYOutputCollector()
        pty.setOutputHandler { collector.append($0) }

        let arrived = collector.expect("env value printed") { data in
            data.containsBytes(of: "value-7f3a2")
        }
        wait(for: [arrived], timeout: 2.0)
    }

    func testWorkingDirectoryPassesThrough() throws {
        let tempDir = NSTemporaryDirectory()
        // Resolve symlinks (/tmp → /private/tmp on macOS) so equality works.
        let resolved = URL(fileURLWithPath: tempDir).resolvingSymlinksInPath().path

        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "pwd; exit 0"],
                workingDirectory: tempDir
            )
        )
        defer { reap(pty) }

        let collector = PTYOutputCollector()
        pty.setOutputHandler { collector.append($0) }

        let arrived = collector.expect("pwd matches working directory") { data in
            data.containsBytes(of: resolved)
        }
        wait(for: [arrived], timeout: 2.0)
    }
}
