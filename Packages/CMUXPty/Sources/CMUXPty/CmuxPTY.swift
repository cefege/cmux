import Darwin
import Dispatch
import Foundation

public final class CmuxPTY: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (UnsafeRawBufferPointer) -> Void
    public typealias ExitHandler = @Sendable (CmuxPTYExitStatus) -> Void

    public let masterFD: Int32
    public let childPID: pid_t
    /// Wall-clock time of the successful forkpty() that produced this PTY.
    /// Used by callers to compute the child's runtime when reporting exit
    /// back into renderers that distinguish abnormal (early) exits.
    public let spawnedAt: Date

    private let stateQueue = DispatchQueue(label: "com.cmux.pty.state", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var outputHandler: OutputHandler?
    private var exitHandler: ExitHandler?
    private var isClosed = false

    /// Write-side backpressure. The Ghostty IO thread calls `write` and must
    /// never block: if the kernel buffer is full (EAGAIN) the remainder of
    /// the write goes into `writeBuffer` and a DispatchSource.makeWriteSource
    /// on the masterFD drains the queue when the kernel reports writability.
    /// `writeBuffer` is bounded; overflow drops the newest bytes and bumps
    /// `writeBufferDroppedBytes` so a caller can surface a regression in the
    /// debug log without spinning on backpressure.
    private let writeLock = NSLock()
    private var writeBuffer = Data()
    private var writeSource: DispatchSourceWrite?
    private var writeSourceSuspended = true
    private static let writeBufferLimit = 1 << 20  // 1 MiB
    private var droppedWriteBytes: UInt64 = 0
    /// Cumulative bytes dropped to backpressure overflow since spawn. Useful
    /// for dogfood diagnostics; under normal terminal interaction this stays 0.
    public var writeBufferDroppedBytes: UInt64 {
        writeLock.lock()
        defer { writeLock.unlock() }
        return droppedWriteBytes
    }

    // MARK: - Write stats aggregator (5.5D burn-in)

    /// Single-write timing samples roll up here. The trampoline reports each
    /// call's duration and byte count; every `writeStatsFlushInterval` writes
    /// the trampoline pulls `flushWriteStats()` to emit an aggregate
    /// `fleet.manualPty.write_stats` log record. The aggregator is kept
    /// in-process to avoid logging on every write — for typical typing
    /// (hundreds of writes/sec during a paste) per-write logs are noise.
    public struct WriteStats: Sendable {
        public var sampleCount: UInt64 = 0
        public var totalBytes: UInt64 = 0
        public var maxDurationUs: UInt64 = 0
        public var droppedBytes: UInt64 = 0
        /// Counts in buckets aligned with `bucketUpperBoundsUs`. The last
        /// bucket captures everything above the final threshold.
        public var bucketCounts: [UInt64] = Array(repeating: 0, count: bucketUpperBoundsUs.count + 1)
        public static let bucketUpperBoundsUs: [UInt64] = [100, 500, 1_000, 5_000, 10_000]

        /// Estimate the duration at percentile `p` (0…1) by scanning the
        /// bucket histogram. The returned value is the upper bound of the
        /// bucket containing the requested rank; coarse, but enough to
        /// answer "is p99 over a frame?" without storing per-sample data.
        public func percentileUs(_ p: Double) -> UInt64 {
            guard sampleCount > 0 else { return 0 }
            let target = UInt64((Double(sampleCount) * p).rounded(.up))
            var running: UInt64 = 0
            for (idx, count) in bucketCounts.enumerated() {
                running &+= count
                if running >= target {
                    if idx < Self.bucketUpperBoundsUs.count {
                        return Self.bucketUpperBoundsUs[idx]
                    }
                    return maxDurationUs
                }
            }
            return maxDurationUs
        }
    }

    private var writeStats = WriteStats()
    public var writeStatsFlushInterval: UInt64 = 1_000

    /// Append a timing sample. Called by the trampoline after every
    /// `write` invocation. Cheap: hashmap-free, lock taken briefly.
    public func recordWriteSample(durationUs: UInt64, bytes: Int) {
        writeLock.lock()
        defer { writeLock.unlock() }
        writeStats.sampleCount &+= 1
        writeStats.totalBytes &+= UInt64(max(0, bytes))
        if durationUs > writeStats.maxDurationUs {
            writeStats.maxDurationUs = durationUs
        }
        var placed = false
        for (idx, threshold) in WriteStats.bucketUpperBoundsUs.enumerated() where !placed {
            if durationUs <= threshold {
                writeStats.bucketCounts[idx] &+= 1
                placed = true
            }
        }
        if !placed {
            writeStats.bucketCounts[WriteStats.bucketUpperBoundsUs.count] &+= 1
        }
    }

    /// True when the trampoline should pull a rollup after the latest
    /// sample. Returns the snapshot atomically with the reset so two
    /// rollups can't double-count or drop a sample.
    public func consumeWriteStatsIfReady() -> WriteStats? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard writeStats.sampleCount >= writeStatsFlushInterval else { return nil }
        var snapshot = writeStats
        snapshot.droppedBytes = droppedWriteBytes
        writeStats = WriteStats()
        return snapshot
    }

    private init(masterFD: Int32, childPID: pid_t, spawnedAt: Date) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.spawnedAt = spawnedAt
    }

    /// Open a new pseudo-terminal master, fork+execve the configured command,
    /// and return a live CmuxPTY.
    ///
    /// Implementation outline:
    ///   1. Allocate argv/envp/cwd C buffers in the parent (no allocations in the
    ///      child between fork and exec — fork-safety).
    ///   2. Open an error pipe with FD_CLOEXEC on both ends so the parent sees
    ///      EOF on a successful execve and bytes back on a failed one.
    ///   3. forkpty(3) — child inherits a new session and controlling slave tty.
    ///   4. Child: chdir if requested, execve. On any failure, write errno to the
    ///      error pipe and `_exit(127)`.
    ///   5. Parent: read errno (or EOF). EOF = success; bytes = collect status and
    ///      throw `.execFailed`.
    public static func spawn(_ config: CmuxPTYSpawn) throws -> CmuxPTY {
        if config.executablePath.isEmpty {
            throw CmuxPTYError.commandEmpty
        }

        let cstrings = CmuxPTYCStringBundle(spawn: config)
        defer { cstrings.free() }

        var pipeFDs: [Int32] = [0, 0]
        if pipeFDs.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress) }) != 0 {
            throw CmuxPTYError.fcntlFailed(errno: errno)
        }
        let errPipe = (read: pipeFDs[0], write: pipeFDs[1])

        // FD_CLOEXEC on both ends — write end vanishes on successful execve,
        // signalling success via EOF in the parent's read.
        if fcntl(errPipe.read, F_SETFD, FD_CLOEXEC) == -1 {
            let saved = errno
            _ = Darwin.close(errPipe.read)
            _ = Darwin.close(errPipe.write)
            throw CmuxPTYError.fcntlFailed(errno: saved)
        }
        if fcntl(errPipe.write, F_SETFD, FD_CLOEXEC) == -1 {
            let saved = errno
            _ = Darwin.close(errPipe.read)
            _ = Darwin.close(errPipe.write)
            throw CmuxPTYError.fcntlFailed(errno: saved)
        }

        var winsize = winsizeFromConfig(config.initialWinsize)
        var masterFD: Int32 = -1
        let pid = withUnsafeMutablePointer(to: &winsize) { winPtr -> pid_t in
            forkpty(&masterFD, nil, nil, winPtr)
        }

        if pid < 0 {
            let saved = errno
            _ = Darwin.close(errPipe.read)
            _ = Darwin.close(errPipe.write)
            throw CmuxPTYError.forkFailed(errno: saved)
        }

        if pid == 0 {
            // ─── Child ─────────────────────────────────────────────────────
            // No Swift runtime, no malloc, no Foundation. Only async-signal-safe
            // calls until execve completes.
            _ = Darwin.close(errPipe.read)

            if let cwdPtr = cstrings.cwd {
                if Darwin.chdir(cwdPtr) != 0 {
                    reportChildError(errPipe.write, code: errno)
                    Darwin._exit(127)
                }
            }

            // Reset signals to defaults so the child doesn't inherit our handlers.
            for sig in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD] {
                _ = Darwin.signal(sig, SIG_DFL)
            }
            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            _ = pthread_sigmask(SIG_SETMASK, &emptyMask, nil)

            _ = Darwin.execve(cstrings.executablePath, cstrings.argv, cstrings.envp)

            // execve only returns on failure.
            reportChildError(errPipe.write, code: errno)
            Darwin._exit(127)
        }

        // ─── Parent ───────────────────────────────────────────────────────
        _ = Darwin.close(errPipe.write)

        // Set master non-blocking + close-on-exec.
        let existing = fcntl(masterFD, F_GETFL, 0)
        if existing == -1 || fcntl(masterFD, F_SETFL, existing | O_NONBLOCK) == -1 {
            let saved = errno
            _ = Darwin.close(errPipe.read)
            _ = Darwin.close(masterFD)
            _ = waitForChildSilently(pid: pid)
            throw CmuxPTYError.fcntlFailed(errno: saved)
        }
        if fcntl(masterFD, F_SETFD, FD_CLOEXEC) == -1 {
            let saved = errno
            _ = Darwin.close(errPipe.read)
            _ = Darwin.close(masterFD)
            _ = waitForChildSilently(pid: pid)
            throw CmuxPTYError.fcntlFailed(errno: saved)
        }

        // Block on the err pipe. Bytes back = exec failed; EOF = success.
        var childErrno: Int32 = 0
        let readResult = withUnsafeMutableBytes(of: &childErrno) { buf -> ssize_t in
            var totalRead = 0
            while totalRead < buf.count {
                let n = Darwin.read(
                    errPipe.read,
                    buf.baseAddress!.advanced(by: totalRead),
                    buf.count - totalRead
                )
                if n > 0 {
                    totalRead += n
                    continue
                }
                if n == 0 { break }
                if errno == EINTR { continue }
                return -1
            }
            return ssize_t(totalRead)
        }
        _ = Darwin.close(errPipe.read)

        if readResult > 0 {
            _ = Darwin.close(masterFD)
            _ = waitForChildSilently(pid: pid)
            throw CmuxPTYError.execFailed(errno: childErrno)
        }

        return CmuxPTY(masterFD: masterFD, childPID: pid, spawnedAt: Date())
    }

    /// Install a closure to be invoked with each chunk read from the master fd.
    /// The buffer pointer is only valid for the duration of the call — copy if
    /// you need to retain. Output that arrives between spawn and handler install
    /// is held in the kernel's PTY buffer (typically 4-8 KB on macOS) and
    /// delivered to the handler once installed.
    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        stateQueue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.outputHandler = handler
            if self.readSource == nil {
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: self.masterFD,
                    queue: self.stateQueue
                )
                source.setEventHandler { [weak self] in
                    self?.drainReadable()
                }
                self.readSource = source
                source.resume()
            }
        }
    }

    /// Install a closure to be invoked when the child process exits. Fires once
    /// per CmuxPTY instance; if the child has already exited and not been
    /// reaped, the handler fires immediately on installation.
    public func setExitHandler(_ handler: @escaping ExitHandler) {
        stateQueue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.exitHandler = handler
            if self.exitSource == nil {
                let source = DispatchSource.makeProcessSource(
                    identifier: self.childPID,
                    eventMask: .exit,
                    queue: self.stateQueue
                )
                source.setEventHandler { [weak self] in
                    self?.collectExit()
                }
                self.exitSource = source
                source.resume()
            }
        }
    }

    /// Write `bytes` to the master fd without blocking the caller. Tries an
    /// inline non-blocking `write(2)` first; any remainder (EAGAIN, partial
    /// completion) is enqueued into `writeBuffer` and drained by a
    /// DispatchSource.makeWriteSource on subsequent writability events.
    /// Returns immediately. Only throws for unrecoverable write errors
    /// (EIO, EBADF, etc.) — EAGAIN never escapes.
    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }

        // Preserve byte order: if anything is already queued, the new bytes
        // must wait their turn behind it.
        if writeBuffer.isEmpty {
            var written = 0
            while written < bytes.count {
                let n = Darwin.write(masterFD, base.advanced(by: written), bytes.count - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n == -1 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    throw CmuxPTYError.writeFailed(errno: errno)
                }
                break
            }
            if written < bytes.count {
                let start = base.advanced(by: written)
                let remaining = bytes.count - written
                enqueueLocked(UnsafeRawBufferPointer(start: start, count: remaining))
                ensureWriteSourceLocked()
            }
        } else {
            enqueueLocked(bytes)
            ensureWriteSourceLocked()
        }
    }

    private func enqueueLocked(_ bytes: UnsafeRawBufferPointer) {
        let available = Self.writeBufferLimit - writeBuffer.count
        let toAccept = max(0, min(bytes.count, available))
        if toAccept > 0, let base = bytes.baseAddress {
            writeBuffer.append(base.assumingMemoryBound(to: UInt8.self), count: toAccept)
        }
        let dropped = bytes.count - toAccept
        if dropped > 0 {
            droppedWriteBytes &+= UInt64(dropped)
        }
    }

    private func ensureWriteSourceLocked() {
        if isClosed { return }
        if writeSource == nil {
            let src = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: stateQueue)
            src.setEventHandler { [weak self] in self?.drainWriteBuffer() }
            writeSource = src
        }
        if writeSourceSuspended {
            writeSourceSuspended = false
            writeSource?.resume()
        }
    }

    private func drainWriteBuffer() {
        writeLock.lock()
        defer { writeLock.unlock() }
        while !writeBuffer.isEmpty {
            let n = writeBuffer.withUnsafeBytes { buf -> ssize_t in
                guard let base = buf.baseAddress else { return 0 }
                return Darwin.write(masterFD, base, buf.count)
            }
            if n > 0 {
                writeBuffer.removeSubrange(0..<Int(n))
                continue
            }
            if n == -1 && errno == EINTR { continue }
            break
        }
        if writeBuffer.isEmpty, let src = writeSource, !writeSourceSuspended {
            writeSourceSuspended = true
            src.suspend()
        }
    }

    /// Resize the slave terminal so the child sees the new grid dimensions.
    public func resize(_ size: Winsize) throws {
        var ws = winsizeFromConfig(size)
        let result = withUnsafeMutablePointer(to: &ws) { ptr in
            Darwin.ioctl(masterFD, UInt(TIOCSWINSZ), ptr)
        }
        if result != 0 {
            throw CmuxPTYError.ioctlFailed(errno: errno)
        }
    }

    /// Send SIGHUP to the child. Fire and forget — the exit handler (if set)
    /// observes the death asynchronously. Source state and the master fd stay
    /// alive so the exit notification can still fire; call `close()` after the
    /// child is reaped to release everything.
    public func terminate() {
        _ = Darwin.kill(childPID, SIGHUP)
    }

    /// Cancel the read / exit sources, drop handler references, and close the
    /// master fd. Idempotent. Safe to call without prior `terminate()`. Must
    /// happen before the master fd is otherwise closed — DispatchSource has
    /// undefined behaviour if its fd is closed out from under it.
    public func close() {
        let group = DispatchGroup()
        group.enter()
        stateQueue.async { [weak self] in
            defer { group.leave() }
            guard let self = self, !self.isClosed else { return }
            self.isClosed = true
            self.readSource?.cancel()
            self.readSource = nil
            self.exitSource?.cancel()
            self.exitSource = nil
            self.outputHandler = nil
            self.exitHandler = nil

            // DispatchSourceWrite must be resumed before cancel; cancelling a
            // suspended source leaks (per Apple docs). Take the writeLock so
            // we don't race with an in-flight enqueue / drain.
            self.writeLock.lock()
            if let src = self.writeSource {
                if self.writeSourceSuspended {
                    self.writeSourceSuspended = false
                    src.resume()
                }
                src.cancel()
                self.writeSource = nil
            }
            self.writeBuffer.removeAll(keepingCapacity: false)
            self.writeLock.unlock()
        }
        _ = group.wait(timeout: .now() + 1.0)
        _ = Darwin.close(masterFD)
    }

    // MARK: - Source handlers (stateQueue)

    private func drainReadable() {
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let n = Darwin.read(masterFD, buffer, bufferSize)
            if n > 0 {
                let chunk = UnsafeRawBufferPointer(start: buffer, count: n)
                outputHandler?(chunk)
                continue
            }
            if n == 0 { break }                          // EOF on master
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            break
        }
    }

    private func collectExit() {
        var status: Int32 = 0
        let r = Darwin.waitpid(childPID, &status, WNOHANG)
        if r <= 0 { return }
        let exit = CmuxPTYExitStatus(reason: exitReason(rawStatus: status), rawStatus: status)
        let handler = exitHandler
        exitHandler = nil
        exitSource?.cancel()
        exitSource = nil
        handler?(exit)
    }
}

// MARK: - Internal helpers

private func winsizeFromConfig(_ ws: Winsize) -> winsize {
    var out = winsize()
    out.ws_col = ws.columns
    out.ws_row = ws.rows
    out.ws_xpixel = ws.widthPixels
    out.ws_ypixel = ws.heightPixels
    return out
}

private func waitForChildSilently(pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while true {
        let r = Darwin.waitpid(pid, &status, 0)
        if r == -1 && errno == EINTR { continue }
        break
    }
    return status
}

/// Write `code` (the raw errno) to `fd`. Called only from the child process
/// between fork and exec, so this must be async-signal-safe. `write(2)` is.
private func reportChildError(_ fd: Int32, code: Int32) {
    var buf = code
    let size = MemoryLayout<Int32>.size
    withUnsafePointer(to: &buf) { ptr in
        let raw = UnsafeRawPointer(ptr)
        var written = 0
        while written < size {
            let n = Darwin.write(fd, raw.advanced(by: written), size - written)
            if n > 0 { written += n; continue }
            if n == -1 && errno == EINTR { continue }
            return
        }
    }
}

/// POSIX status decoding without C macros.
private func exitReason(rawStatus: Int32) -> CmuxPTYExitStatus.Reason {
    let termSignal = rawStatus & 0x7F
    if termSignal == 0 {
        return .exited(code: (rawStatus >> 8) & 0xFF)
    }
    if termSignal != 0x7F {
        return .signaled(signal: termSignal)
    }
    return .unknown
}

// MARK: - C-string lifetime bundle

private final class CmuxPTYCStringBundle {
    let executablePath: UnsafePointer<CChar>
    let argv: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let envp: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let cwd: UnsafePointer<CChar>?

    private let owned: [UnsafeMutablePointer<CChar>]
    private let argvBuffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let argvCapacity: Int
    private let envpBuffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let envpCapacity: Int
    private let cwdOwned: UnsafeMutablePointer<CChar>?

    init(spawn: CmuxPTYSpawn) {
        var owned: [UnsafeMutablePointer<CChar>] = []

        let execPtr = CmuxPTYCStringBundle.duplicate(spawn.executablePath)
        owned.append(execPtr)

        let argv0Ptr: UnsafeMutablePointer<CChar>
        if let argv0 = spawn.argv0 {
            let dup = CmuxPTYCStringBundle.duplicate(argv0)
            owned.append(dup)
            argv0Ptr = dup
        } else {
            argv0Ptr = execPtr
        }

        var argvOwned: [UnsafeMutablePointer<CChar>] = [argv0Ptr]
        for argument in spawn.arguments {
            let dup = CmuxPTYCStringBundle.duplicate(argument)
            argvOwned.append(dup)
            owned.append(dup)
        }
        let argvBuffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: argvOwned.count + 1)
        for (i, ptr) in argvOwned.enumerated() {
            argvBuffer[i] = ptr
        }
        argvBuffer[argvOwned.count] = nil

        let envEntries = spawn.environment.map { "\($0.key)=\($0.value)" }
        var envpOwned: [UnsafeMutablePointer<CChar>] = []
        for entry in envEntries {
            let dup = CmuxPTYCStringBundle.duplicate(entry)
            envpOwned.append(dup)
            owned.append(dup)
        }
        let envpBuffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: envpOwned.count + 1)
        for (i, ptr) in envpOwned.enumerated() {
            envpBuffer[i] = ptr
        }
        envpBuffer[envpOwned.count] = nil

        let cwdOwned: UnsafeMutablePointer<CChar>?
        if let cwd = spawn.workingDirectory, !cwd.isEmpty {
            let dup = CmuxPTYCStringBundle.duplicate(cwd)
            owned.append(dup)
            cwdOwned = dup
        } else {
            cwdOwned = nil
        }

        self.executablePath = UnsafePointer(execPtr)
        self.argv = UnsafePointer(argvBuffer)
        self.envp = UnsafePointer(envpBuffer)
        self.cwd = cwdOwned.map { UnsafePointer($0) }
        self.owned = owned
        self.argvBuffer = argvBuffer
        self.argvCapacity = argvOwned.count + 1
        self.envpBuffer = envpBuffer
        self.envpCapacity = envpOwned.count + 1
        self.cwdOwned = cwdOwned
    }

    func free() {
        for ptr in owned { ptr.deallocate() }
        argvBuffer.deallocate()
        envpBuffer.deallocate()
    }

    private static func duplicate(_ string: String) -> UnsafeMutablePointer<CChar> {
        return string.withCString { src in
            let length = strlen(src) + 1
            let dst = UnsafeMutablePointer<CChar>.allocate(capacity: length)
            memcpy(dst, src, length)
            return dst
        }
    }
}
