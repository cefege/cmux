import Foundation

public struct CmuxPTYSpawn: Sendable, Hashable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var initialWinsize: Winsize

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialWinsize: Winsize = .fallback
    ) {
        self.executablePath = executablePath
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
