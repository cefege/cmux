import Foundation

public struct CmuxPTYSpawn: Sendable, Hashable {
    public var executablePath: String
    /// Override for argv[0]. When nil, argv[0] defaults to `executablePath`,
    /// which is what most callers want. Set this to make a login shell (POSIX
    /// convention: argv[0] begins with `-`) or to spoof argv[0] for symlinked
    /// multicall binaries.
    public var argv0: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var initialWinsize: Winsize

    public init(
        executablePath: String,
        argv0: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialWinsize: Winsize = .fallback
    ) {
        self.executablePath = executablePath
        self.argv0 = argv0
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.initialWinsize = initialWinsize
    }
}

public struct CmuxPTYExitStatus: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case exited(code: Int32)
        case signaled(signal: Int32)
        case unknown
    }

    public var reason: Reason
    public var rawStatus: Int32

    public init(reason: Reason, rawStatus: Int32) {
        self.reason = reason
        self.rawStatus = rawStatus
    }
}
