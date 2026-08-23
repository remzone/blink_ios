import XCTest
@testable import Blink

final class VPNProfileTests: XCTestCase {
    func testProfileRoundTripDoesNotContainSecrets() throws {
        let profile = VPNProfile(name: "Work", server: "vpn.example.com")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VPNProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("privateKey"))
        XCTAssertFalse(json.contains("obfuscationKey"))
    }

    func testDefaultsRouteAllIPv4Traffic() {
        XCTAssertEqual(WireGuardConfiguration().allowedIPs, ["0.0.0.0/0"])
        XCTAssertEqual(FreeTurnConfiguration().obfProfile, "rtpopus")
    }

    func testFreeTurnConfigurationUsesLocalUDPListener() throws {
        var profile = VPNProfile(name: "VPN", server: "203.0.113.10", port: 56_000)
        profile.freeTurn.vkLink = "https://vk.ru/call/join/example"
        let json = try FreeTurnConfigBuilder.json(profile: profile, obfuscationKey: "secret-value")
        XCTAssertTrue(json.contains("127.0.0.1:9000"))
        XCTAssertTrue(json.contains("203.0.113.10:56000"))
        XCTAssertTrue(json.contains("secret-value"))
    }
}
