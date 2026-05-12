import Foundation

public struct TailscaleUser: Codable, Sendable, Equatable {
    public let id: Int64
    public let loginName: String
    public let displayName: String?

    public init(id: Int64, loginName: String, displayName: String?) {
        self.id = id
        self.loginName = loginName
        self.displayName = displayName
    }
}

public struct TailscaleNode: Codable, Sendable, Equatable {
    public let nodeId: String
    public let hostName: String
    public let dnsName: String
    public let tailscaleIPs: [String]
    public let online: Bool
    public let userId: Int64?
    public let lastSeenUnix: Int64?

    public init(
        nodeId: String,
        hostName: String,
        dnsName: String,
        tailscaleIPs: [String],
        online: Bool,
        userId: Int64?,
        lastSeenUnix: Int64?
    ) {
        self.nodeId = nodeId
        self.hostName = hostName
        self.dnsName = dnsName
        self.tailscaleIPs = tailscaleIPs
        self.online = online
        self.userId = userId
        self.lastSeenUnix = lastSeenUnix
    }
}

public struct TailscaleStatus: Sendable, Equatable {
    public let selfNode: TailscaleNode
    public let peers: [TailscaleNode]
    public let users: [Int64: TailscaleUser]

    public init(selfNode: TailscaleNode, peers: [TailscaleNode], users: [Int64: TailscaleUser]) {
        self.selfNode = selfNode
        self.peers = peers
        self.users = users
    }
}

public struct TailscaleWhois: Sendable, Equatable {
    public let node: TailscaleNode
    public let user: TailscaleUser?

    public init(node: TailscaleNode, user: TailscaleUser?) {
        self.node = node
        self.user = user
    }
}

public enum TailscaleProbeError: Error, CustomStringConvertible {
    case binaryNotFound
    case commandFailed(exitCode: Int32, stderr: String)
    case malformedOutput(String)

    public var description: String {
        switch self {
        case .binaryNotFound:
            return "Tailscale CLI not found. Install Tailscale.app or `brew install tailscale`."
        case .commandFailed(let code, let stderr):
            return "tailscale exited \(code): \(stderr)"
        case .malformedOutput(let detail):
            return "Could not parse tailscale output: \(detail)"
        }
    }
}

public protocol TailscaleProbe: Sendable {
    func status() async throws -> TailscaleStatus
    func whois(host: String, port: UInt16) async throws -> TailscaleWhois
}

public enum TailscaleCLILocator {
    public static let candidatePaths: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
    ]

    public static func resolve(fileManager: FileManager = .default) -> String? {
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

public final class TailscaleCLIProbe: TailscaleProbe {
    public let executablePath: String

    public init?(executablePath: String? = nil) {
        if let path = executablePath {
            self.executablePath = path
        } else if let path = TailscaleCLILocator.resolve() {
            self.executablePath = path
        } else {
            return nil
        }
    }

    public func status() async throws -> TailscaleStatus {
        let data = try await runCapturingStdout(arguments: ["status", "--json"])
        return try TailscaleStatusParser.parse(jsonData: data)
    }

    public func whois(host: String, port: UInt16) async throws -> TailscaleWhois {
        let target = "\(host):\(port)"
        let data = try await runCapturingStdout(arguments: ["whois", "--json", target])
        return try TailscaleWhoisParser.parse(jsonData: data)
    }

    private func runCapturingStdout(arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let stdoutData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: stdoutData)
                } else {
                    let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                    cont.resume(throwing: TailscaleProbeError.commandFailed(
                        exitCode: proc.terminationStatus,
                        stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// JSON shape produced by `tailscale status --json`. Only the fields we need.
enum TailscaleStatusParser {
    static func parse(jsonData: Data) throws -> TailscaleStatus {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TailscaleProbeError.malformedOutput("status root is not an object")
        }

        guard let selfDict = root["Self"] as? [String: Any] else {
            throw TailscaleProbeError.malformedOutput("status missing Self")
        }
        let selfNode = try parseNode(selfDict)

        var peers: [TailscaleNode] = []
        if let peersDict = root["Peer"] as? [String: [String: Any]] {
            for (_, peerDict) in peersDict {
                if let parsed = try? parseNode(peerDict) {
                    peers.append(parsed)
                }
            }
        }

        var users: [Int64: TailscaleUser] = [:]
        if let usersDict = root["User"] as? [String: [String: Any]] {
            for (key, userDict) in usersDict {
                guard let userId = Int64(key) else { continue }
                let loginName = userDict["LoginName"] as? String ?? ""
                let displayName = userDict["DisplayName"] as? String
                users[userId] = TailscaleUser(
                    id: userId,
                    loginName: loginName,
                    displayName: displayName
                )
            }
        }

        return TailscaleStatus(selfNode: selfNode, peers: peers, users: users)
    }

    private static func parseNode(_ dict: [String: Any]) throws -> TailscaleNode {
        guard let nodeId = (dict["ID"] as? String) ?? (dict["PublicKey"] as? String) else {
            throw TailscaleProbeError.malformedOutput("node missing ID")
        }
        let hostName = dict["HostName"] as? String ?? ""
        let dnsName = dict["DNSName"] as? String ?? ""
        let ips = dict["TailscaleIPs"] as? [String] ?? []
        let online = dict["Online"] as? Bool ?? false
        let userId = (dict["UserID"] as? NSNumber)?.int64Value
        let lastSeen = parseRFC3339Unix(dict["LastSeen"] as? String)

        return TailscaleNode(
            nodeId: nodeId,
            hostName: hostName,
            dnsName: dnsName,
            tailscaleIPs: ips,
            online: online,
            userId: userId,
            lastSeenUnix: lastSeen
        )
    }

    private static func parseRFC3339Unix(_ s: String?) -> Int64? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) {
            return Int64(date.timeIntervalSince1970)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: s) {
            return Int64(date.timeIntervalSince1970)
        }
        return nil
    }
}

enum TailscaleWhoisParser {
    static func parse(jsonData: Data) throws -> TailscaleWhois {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TailscaleProbeError.malformedOutput("whois root is not an object")
        }

        guard let nodeDict = root["Node"] as? [String: Any] else {
            throw TailscaleProbeError.malformedOutput("whois missing Node")
        }
        let node = try TailscaleNodeParser.parseFromWhois(nodeDict)

        var user: TailscaleUser? = nil
        if let userDict = root["UserProfile"] as? [String: Any],
           let userId = (userDict["ID"] as? NSNumber)?.int64Value {
            let loginName = userDict["LoginName"] as? String ?? ""
            let displayName = userDict["DisplayName"] as? String
            user = TailscaleUser(id: userId, loginName: loginName, displayName: displayName)
        }

        return TailscaleWhois(node: node, user: user)
    }
}

enum TailscaleNodeParser {
    static func parseFromWhois(_ dict: [String: Any]) throws -> TailscaleNode {
        let nodeId = (dict["ID"] as? String) ?? (dict["StableID"] as? String) ?? (dict["PublicKey"] as? String) ?? ""
        if nodeId.isEmpty {
            throw TailscaleProbeError.malformedOutput("whois node missing ID")
        }
        let hostName = dict["HostName"] as? String ?? (dict["ComputedName"] as? String ?? "")
        let dnsName = dict["Name"] as? String ?? (dict["DNSName"] as? String ?? "")
        let ips = (dict["Addresses"] as? [String])?.map { String($0.split(separator: "/").first ?? "") }
            ?? (dict["TailscaleIPs"] as? [String])
            ?? []
        let userId = (dict["User"] as? NSNumber)?.int64Value ?? (dict["UserID"] as? NSNumber)?.int64Value

        return TailscaleNode(
            nodeId: nodeId,
            hostName: hostName,
            dnsName: dnsName,
            tailscaleIPs: ips.filter { !$0.isEmpty },
            online: true,
            userId: userId,
            lastSeenUnix: nil
        )
    }
}
