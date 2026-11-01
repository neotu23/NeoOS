import XCTest
@testable import HermesIOSCore

/// The mode switch is a compatibility surface: an existing install must never wake up in a different
/// transport because a new key appeared (or is missing).
final class ConnectionModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "ConnectionModeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testMissingKeyDefaultsToDirect() {
        XCTAssertEqual(ConnectionModeStore.load(defaults), .direct,
                       "an install that predates this key keeps its direct connection")
    }

    func testUnknownValueDefaultsToDirect() {
        defaults.set("carrier-pigeon", forKey: "connectionMode")
        XCTAssertEqual(ConnectionModeStore.load(defaults), .direct,
                       "a value from a newer build must not put an old build into an unknown mode")
    }

    func testRoundTrip() {
        ConnectionModeStore.save(.cloud, defaults)
        XCTAssertEqual(ConnectionModeStore.load(defaults), .cloud)
        ConnectionModeStore.save(.direct, defaults)
        XCTAssertEqual(ConnectionModeStore.load(defaults), .direct)
    }

    func testEveryModeHasItsOwnCopy() {
        for mode in ConnectionMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty)
        }
        XCTAssertEqual(Set(ConnectionMode.allCases.map(\.label)).count, ConnectionMode.allCases.count)
    }
}
