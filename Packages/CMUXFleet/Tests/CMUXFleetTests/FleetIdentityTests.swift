import XCTest
@testable import CMUXFleet

final class FleetIdentityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMUXFleetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStorage() -> FleetIdentityFileStorage {
        FleetIdentityFileStorage(fileURL: tempDir.appendingPathComponent("fleet-identity.json"))
    }

    func testFirstCallCreatesAndPersistsIdentity() throws {
        let storage = makeStorage()
        XCTAssertNil(try storage.load())

        let identity = try FleetIdentityProvider.loadOrCreate(
            storage: storage,
            defaultDisplayName: "test-mac",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        XCTAssertEqual(identity.displayName, "test-mac")
        XCTAssertEqual(identity.createdAtUnix, 1_700_000_000)
        XCTAssertEqual(identity.schemaVersion, 1)

        let reloaded = try storage.load()
        XCTAssertEqual(reloaded, identity)
    }

    func testSecondCallReturnsTheSameIdentity() throws {
        let storage = makeStorage()

        let first = try FleetIdentityProvider.loadOrCreate(
            storage: storage,
            defaultDisplayName: "first-name"
        )
        let second = try FleetIdentityProvider.loadOrCreate(
            storage: storage,
            defaultDisplayName: "second-name-should-be-ignored"
        )

        XCTAssertEqual(first.hostId, second.hostId)
        XCTAssertEqual(second.displayName, "first-name")
    }

    func testHostIdsAreUniquePerStorageInstance() throws {
        let storageA = FleetIdentityFileStorage(
            fileURL: tempDir.appendingPathComponent("a.json")
        )
        let storageB = FleetIdentityFileStorage(
            fileURL: tempDir.appendingPathComponent("b.json")
        )

        let a = try FleetIdentityProvider.loadOrCreate(storage: storageA, defaultDisplayName: "a")
        let b = try FleetIdentityProvider.loadOrCreate(storage: storageB, defaultDisplayName: "b")

        XCTAssertNotEqual(a.hostId, b.hostId)
    }

    func testSavedFileIsValidJSON() throws {
        let storage = makeStorage()
        _ = try FleetIdentityProvider.loadOrCreate(storage: storage, defaultDisplayName: "n")

        let url = tempDir.appendingPathComponent("fleet-identity.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["displayName"] as? String, "n")
        XCTAssertNotNil(json?["hostId"] as? String)
    }
}
