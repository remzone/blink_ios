import XCTest
@testable import Blink

final class XrayProfileTests: XCTestCase {
    private let base = "vless://00000000-0000-4000-8000-000000000001@vpn.example.org:443"
    func testXHTTPParametersPreserved() throws {
        let p = try XrayProfile.parse(base + "?type=xhttp&security=tls&sni=tls.example.org&host=http.example.org&path=%2Fup&mode=stream-up")
        XCTAssertEqual(p.network, "xhttp"); XCTAssertEqual(p.path, "/up")
        XCTAssertEqual(p.serverName, "tls.example.org"); XCTAssertEqual(p.host, "http.example.org")
        XCTAssertEqual(p.mode, "stream-up")
    }
    func testIPv6EndpointHasNoURLBrackets() throws {
        let p = try XrayProfile.parse(base.replacingOccurrences(of: "vpn.example.org", with: "[2001:db8::1]"))
        XCTAssertEqual(p.address, "2001:db8::1")
    }
    func testRealityParametersPreserved() throws {
        let p = try XrayProfile.parse(base + "?security=reality&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd&fp=chrome&flow=xtls-rprx-vision")
        XCTAssertEqual(p.publicKey, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"); XCTAssertEqual(p.shortId, "abcd")
        XCTAssertEqual(p.flow, "xtls-rprx-vision")
    }
    func testRejectsLossyOrInsecureImports() {
        for suffix in ["?type=ws", "?type=xhttp&extra=%7B%7D", "?security=tls&allowInsecure=1", "?type=tcp&type=xhttp", "?encryption=unknown", "?security=reality", "?security=tls&sni=", "?type=xhttp&mode=bogus", "?type=xhttp&path=relative", "?security=none&pbk=ignored", "?type=tcp&path=%2Fignored"] {
            XCTAssertThrowsError(try XrayProfile.parse(base + suffix))
        }
    }
}
