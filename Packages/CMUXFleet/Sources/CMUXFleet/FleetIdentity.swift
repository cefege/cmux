import Foundation

public struct FleetIdentity: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public let hostId: UUID
    public var displayName: String
    public var createdAtUnix: Int64

    public init(
        schemaVersion: Int = 1,
        hostId: UUID,
        displayName: String,
        createdAtUnix: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.hostId = hostId
        self.displayName = displayName
        self.createdAtUnix = createdAtUnix
    }
}

public protocol FleetIdentityStorage: Sendable {
    func load() throws -> FleetIdentity?
    func save(_ identity: FleetIdentity) throws
}

public final class FleetIdentityFileStorage: FleetIdentityStorage {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init() {
        let appSupport = URL.applicationSupportDirectory.appendingPathComponent("cmux", isDirectory: true)
        self.init(fileURL: appSupport.appendingPathComponent("fleet-identity.json"))
    }

    public func load() throws -> FleetIdentity? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        return try JSONDecoder().decode(FleetIdentity.self, from: data)
    }

    public func save(_ identity: FleetIdentity) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(identity)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum FleetIdentityProvider {
    /// `defaultDisplayName` is consulted only on first call (when the
    /// persisted identity does not yet exist).
    public static func loadOrCreate(
        storage: FleetIdentityStorage,
        defaultDisplayName: @autoclosure () -> String = Host.current().localizedName ?? "Unknown Mac",
        now: () -> Date = Date.init
    ) throws -> FleetIdentity {
        if let existing = try storage.load() {
            return existing
        }
        let fresh = FleetIdentity(
            hostId: UUID(),
            displayName: defaultDisplayName(),
            createdAtUnix: Int64(now().timeIntervalSince1970)
        )
        try storage.save(fresh)
        return fresh
    }
}
