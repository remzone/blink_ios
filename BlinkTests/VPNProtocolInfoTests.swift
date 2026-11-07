import XCTest
@testable import Blink

final class VPNProtocolInfoTests: XCTestCase {
    func testRouteComesFromProviderModeRatherThanProtocolName() {
        XCTAssertEqual(ConnectionRoute.fromProviderMode("vkturn"), .vk)
        for mode in ["direct", "universal", "vless", "wireguard"] {
            XCTAssertEqual(ConnectionRoute.fromProviderMode(mode), .direct)
        }
    }
    func testNativeXrayKindUsesSchemeForHumanProtocolName() {
        for (scheme, name) in [("vless", "VLESS"), ("vmess", "VMess"), ("trojan", "Trojan"), ("ss", "Shadowsocks"), ("hy2", "Hysteria 2")] {
            let info = VPNProtocolInfo.describe(kind: "xray", source: "\(scheme)://fixture-secret@example.org:443#private-name")
            XCTAssertEqual(info.title, name)
            XCTAssertFalse(info.summary.contains("fixture-secret"))
            XCTAssertFalse(info.summary.contains("example.org"))
        }
    }
    func testJSONAndWireguardMetadataTakePrecedenceOverEmbeddedURIs() {
        XCTAssertEqual(VPNProtocolInfo.describe(kind: "xray-json", source: "{\"remark\":\"vless://fixture-secret\"}").title, "Xray JSON")
        XCTAssertEqual(VPNProtocolInfo.describe(kind: "wireguard", source: "[Interface]\nPrivateKey = fixture-secret").title, "WireGuard")
        XCTAssertEqual(VPNProtocolInfo.describe(kind: "amneziawg", source: "vpn://fixture-secret").title, "AmneziaWG")
    }
    func testUnknownProtocolDoesNotExposeSourceOrInventDetails() {
        let info = VPNProtocolInfo.describe(kind: "unknown", source: "unsupported://fixture-secret")
        XCTAssertEqual(info.title, "VPN-профиль")
        XCTAssertFalse(info.summary.contains("fixture-secret"))
    }
}
