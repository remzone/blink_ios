import XCTest
@testable import Blink

final class ProfileImportInputTests: XCTestCase {
    private let feed = "https://panel.example/sub/fixture?token=a%2Bb%26c"
    private let node = "vless://00000000-0000-4000-8000-000000000001@example.org:443?path=%2Fvpn%3Fa%3D1&security=tls#Test"

    func testSubscriptionWrappersPreserveEncodedTokens() throws {
        for text in [feed, feed.replacingOccurrences(of: "https:", with: "http:"), "  \(feed)\n", "<\(feed)>", "[Подписка](\(feed))", "hiddify://import/\(feed)#Display"] {
            XCTAssertEqual(try ProfileImportInput.parse(text), .subscription(feed))
        }
        for scheme in ["clash", "clashmeta", "hiddify"] {
            var wrapper = URLComponents()
            wrapper.scheme = scheme; wrapper.host = "install-config"
            wrapper.queryItems = [URLQueryItem(name: "url", value: feed), URLQueryItem(name: "name", value: "Test")]
            XCTAssertEqual(try ProfileImportInput.parse(try XCTUnwrap(wrapper.string)), .subscription(feed))
        }
    }

    func testPanelFeedWrappersAreRecognizedAsTURN() throws {
        let url = "https://panel.example/vokop-panel/api/vokop/v1/subscriptions/" + String(repeating: "A", count: 43)
        for text in [url, "<\(url)>", "[Подписка](\(url))", "hiddify://import/\(url)", url.replacingOccurrences(of: "https:", with: "http:")] {
            guard case .subscription(let value) = try ProfileImportInput.parse(text) else { return XCTFail("Subscription not recognized") }
            XCTAssertEqual(try VokopSubscriptionClient.validatedURL(value).absoluteString, url)
        }
        XCTAssertThrowsError(try VokopSubscriptionClient.validatedURL(url + "/account"))
    }

    func testConfigAndProtocolPayloadsAreNotURLDecoded() throws {
        for text in [node, "hiddify://import/" + node] {
            XCTAssertEqual(try ProfileImportInput.parse(text), .configuration(node))
        }
        let wireguard = "[Interface]\nPrivateKey = fixture=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = peer=\nEndpoint = example.org:51820"
        let json = "{\"outbounds\":[{\"protocol\":\"vless\"}]}"
        let list = node + "\n" + "trojan://p%40ss@example.org:443#Second"
        for config in [wireguard, json, list, Data(list.utf8).base64EncodedString()] {
            XCTAssertEqual(try ProfileImportInput.parse(config), .configuration(config))
        }
    }

    func testInvalidAndRecursiveWrappersAreRejected() {
        for text in ["", "   \n", "clash://install-config", "clash://install-config?url=a&url=b", "hiddify://install-config?url=https%3A%2F%2Fuser%3Apass%40panel.example%2Fsub", String(repeating: "hiddify://import/", count: 5) + feed] {
            XCTAssertThrowsError(try ProfileImportInput.parse(text))
        }
        XCTAssertThrowsError(try ProfileImportInput.parse(String(repeating: "a", count: 1_048_577)))
    }
}
