import Darwin
import Foundation
import XCTest
@testable import CMUXPty

final class CmuxPTYResizeTests: XCTestCase {
    func testResizeReflectedByStty() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "stty size; exit 0"],
                initialWinsize: Winsize(columns: 137, rows: 41)
            )
        )
        defer { reap(pty) }

        let collector = PTYOutputCollector()
        pty.setOutputHandler { collector.append($0) }

        let arrived = collector.expect("stty reports initial size") { data in
            data.containsBytes(of: "41 137")
        }
        wait(for: [arrived], timeout: 2.0)
    }

    func testResizeAfterSpawnUpdatesChildView() throws {
        let pty = try CmuxPTY.spawn(
            CmuxPTYSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "stty size; sleep 0.4; stty size; exit 0"],
                initialWinsize: Winsize(columns: 80, rows: 24)
            )
        )
        defer { reap(pty) }

        let collector = PTYOutputCollector()
        pty.setOutputHandler { collector.append($0) }

        // Give the shell a moment to print the first stty size before resizing.
        Thread.sleep(forTimeInterval: 0.15)
        try pty.resize(Winsize(columns: 220, rows: 65))

        let arrived = collector.expect("stty reports new size after resize") { data in
            data.containsBytes(of: "65 220")
        }
        wait(for: [arrived], timeout: 2.0)
    }
}
