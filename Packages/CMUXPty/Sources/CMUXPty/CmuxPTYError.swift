import Foundation

public enum CmuxPTYError: Error, Sendable, Equatable {
    case openMasterFailed(errno: Int32)
    case grantptFailed(errno: Int32)
    case unlockptFailed(errno: Int32)
    case slavePathFailed(errno: Int32)
    case openSlaveFailed(errno: Int32)
    case forkFailed(errno: Int32)
    case execFailed(errno: Int32)
    case setsidFailed(errno: Int32)
    case tiocsctyFailed(errno: Int32)
    case chdirFailed(errno: Int32)
    case ioctlFailed(errno: Int32)
    case fcntlFailed(errno: Int32)
    case alreadyTerminated
    case notYetSpawned
    case writeFailed(errno: Int32)
    case commandEmpty
}
