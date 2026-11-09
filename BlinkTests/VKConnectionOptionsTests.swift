import XCTest
@testable import Blink

final class VKConnectionOptionsTests: XCTestCase {
    func testMigrationAndPersistence() throws {
        let suite = "blink.test.options." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("udp", forKey: "vokop.turnTransport.v2")
        defaults.set("8.8.8.8", forKey: "vokop.bootstrapDNS")
        var options = VKConnectionOptions.load(defaults: defaults)
        XCTAssertEqual(options.transport, "udp"); XCTAssertEqual(options.bootstrapDNS, "8.8.8.8")
        XCTAssertEqual(options.connections, 1)
        options.connections = 1; options.turnServer = "relay.example.org:3478"; options.preset = "balanced"
        options.save(defaults: defaults)
        XCTAssertEqual(VKConnectionOptions.load(defaults: defaults), options)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(options.tuning)) as? [String: Any])
        XCTAssertEqual(json["window"] as? Int, 0); XCTAssertEqual(json["congestion"] as? Bool, false)
        options.turnServer = "https://relay.example.org:443"; options.save(defaults: defaults)
        XCTAssertEqual(VKConnectionOptions.load(defaults: defaults).turnServer, "relay.example.org:3478")
    }
    func testRelayAndDNSValidation() {
        for relay in ["", "relay.example.org:3478", "127.0.0.1:443", "[2001:db8::1]:3478"] { XCTAssertTrue(VKConnectionOptions.validRelay(relay), relay) }
        for relay in ["relay.example.org", "https://relay.example.org:443", "user:secret@relay.example.org:3478", "relay:0", "relay:65536", "relay:3478/path", "relay:3478?key=secret"] { XCTAssertFalse(VKConnectionOptions.validRelay(relay), relay) }
        XCTAssertTrue(VKConnectionOptions.isIP("1.1.1.1")); XCTAssertTrue(VKConnectionOptions.isIP("2001:4860:4860::8888"))
        XCTAssertFalse(VKConnectionOptions.isIP("dns.example.org"))
        var options = VKConnectionOptions(); XCTAssertTrue(options.isValid)
        options.connections = 17; XCTAssertFalse(options.isValid)
        options = VKConnectionOptions(); options.mtu = 1201; XCTAssertFalse(options.isValid)
        options = VKConnectionOptions(); options.preset = "srtp"; XCTAssertFalse(options.isValid)
    }
}
