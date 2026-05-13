import Darwin
import Foundation
import XCTest
@testable import CMUXPty

/// Best-effort cleanup for tests: SIGHUP, reap any unreaped child, then
/// release sources + close fd. Safe to call even after the child has already
/// exited and/or been reaped by an exit handler.
func reap(_ pty: CmuxPTY) {
    pty.terminate()
    Thread.sleep(forTimeInterval: 0.05)
    var status: Int32 = 0
    _ = Darwin.waitpid(pty.childPID, &status, 0)
    pty.close()
}

/// Thread-safe sink for read chunks; tests block on `wait(for:timeout:)`.
final class PTYOutputCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.cmux.pty.collector")
    private var buffer = Data()
    private var waiters: [(predicate: (Data) -> Bool, fulfill: () -> Void)] = []

    func append(_ chunk: UnsafeRawBufferPointer) {
        let copy = Data(chunk)
        queue.sync {
            buffer.append(copy)
            waiters = waiters.filter { entry in
                if entry.predicate(buffer) {
                    entry.fulfill()
                    return false
                }
                return true
            }
        }
    }

    func snapshot() -> Data {
        queue.sync { buffer }
    }

    func expect(_ description: String, predicate: @escaping (Data) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        queue.sync {
            if predicate(buffer) {
                expectation.fulfill()
            } else {
                waiters.append((predicate, expectation.fulfill))
            }
        }
        return expectation
    }
}

extension Data {
    func containsBytes(of string: String) -> Bool {
        guard let needle = string.data(using: .utf8) else { return false }
        return range(of: needle) != nil
    }
}
