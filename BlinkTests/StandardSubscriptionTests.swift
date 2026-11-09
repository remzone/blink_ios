import XCTest
@testable import Blink

final class StandardSubscriptionTests: XCTestCase {
    private func fixture(_ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "standard-subscription", withExtension: ext))
        return try Data(contentsOf: url)
    }
    func testPlainAndBase64HaveIdenticalPerNodeResults() throws {
        let plain = try StandardSubscription.parse(fixture("txt"))
        let encoded = try StandardSubscription.parse(fixture("base64"))
        struct Expected: Decodable { let total: Int; let supported: Int; let rejected: Int; let networks: [String?] }
        let expected = try JSONDecoder().decode(Expected.self, from: fixture("expected.json"))
        XCTAssertEqual(plain.count, expected.total); XCTAssertEqual(encoded.count, expected.total)
        XCTAssertEqual(plain.filter { $0.profile != nil }.count, expected.supported)
        XCTAssertEqual(plain.filter { $0.rejection != nil }.count, expected.rejected)
        XCTAssertEqual(plain.map(\.profile?.network), expected.networks)
        XCTAssertEqual(plain.map(\.profile?.network), encoded.map(\.profile?.network))
        XCTAssertEqual(plain[0].name, "TCP fixture")
        XCTAssertEqual(plain[1].profile?.path, "/up")
        XCTAssertEqual(plain[1].profile?.host, "http.example.org")
        XCTAssertNotNil(plain[2].rejection); XCTAssertNotNil(plain[3].rejection)
        XCTAssertFalse(plain[2].rejection?.contains("not-a-real-password") ?? true)
    }
    func testUnpaddedBase64URL() throws {
        let raw = try fixture("txt")
        let encoded = raw.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try StandardSubscription.parse(Data(encoded.utf8)).count, 4)
    }
    func testBoundsAndMalformedEncoding() throws {
        XCTAssertThrowsError(try StandardSubscription.parse(Data(repeating: 0, count: StandardSubscription.maximumBytes + 1)))
        for input in ["", "%%%", "A", "not a subscription"] {
            XCTAssertThrowsError(try StandardSubscription.parse(Data(input.utf8)))
        }
        let line = "vless://00000000-0000-4000-8000-000000000001@vpn.example.org:443\n"
        XCTAssertThrowsError(try StandardSubscription.parse(Data(String(repeating: line, count: 257).utf8)))
        let mixed = line + "unknown://bad\n"
        let nodes = try StandardSubscription.parse(Data(mixed.utf8))
        XCTAssertEqual(nodes.count, 2); XCTAssertNotNil(nodes[1].rejection)
    }
    func testHTTPSURLWithScopedQueryAllowedButCredentialsRejected() {
        XCTAssertNoThrow(try SecureSubscriptionHTTP.validatedURL("https://panel.example/sub/user?token=fixture-only"))
        for url in ["http://panel.example/sub/user", "https://user:password@panel.example/sub", "https://panel.example/sub#fragment"] {
            XCTAssertThrowsError(try SecureSubscriptionHTTP.validatedURL(url))
        }
    }
    func testRedirectsStayOnOriginalHTTPSOriginAndHaveABoundedCount() throws {
        let original = try XCTUnwrap(URL(string: "https://panel.example/sub/fixture"))
        for target in ["https://panel.example/sub/fixture/", "https://PANEL.example:443/next?token=fixture"] {
            XCTAssertTrue(SecureSubscriptionHTTP.allowsRedirect(from: original, to: try XCTUnwrap(URL(string: target)), count: 1))
        }
        for target in ["http://panel.example/next", "https://other.example/next", "https://panel.example:8443/next", "https://user:password@panel.example/next", "https://panel.example/next#fragment"] {
            XCTAssertFalse(SecureSubscriptionHTTP.allowsRedirect(from: original, to: try XCTUnwrap(URL(string: target)), count: 1))
        }
        XCTAssertTrue(SecureSubscriptionHTTP.allowsRedirect(from: original, to: original, count: 5))
        XCTAssertFalse(SecureSubscriptionHTTP.allowsRedirect(from: original, to: original, count: 6))
    }

    func testReissuedFeedHasActionableErrorInPlainAndEncodedForms() {
        let notice = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:1?type=tcp&security=none&encryption=none&x-durev-reissue=true#Renew"
        let encoded = Data(notice.utf8).base64EncodedString()
        let urlEncoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for source in [notice, notice.replacingOccurrences(of: "#Renew", with: "#🔴 Ключ перевыпущен — возьмите новую ссылку в боте"), "\u{feff}" + notice, encoded, urlEncoded] {
            XCTAssertThrowsError(try SubscriptionFeedNotice.validate(source)) { error in
                guard let subscriptionError = error as? SubscriptionError, case .reissued = subscriptionError else {
                    return XCTFail("Expected reissued subscription error")
                }
            }
            XCTAssertThrowsError(try StandardSubscription.parse(Data(source.utf8)))
        }
        // A marker on an actual endpoint, or one node within a full feed, cannot invalidate the feed.
        XCTAssertNoThrow(try SubscriptionFeedNotice.validate(notice.replacingOccurrences(of: "127.0.0.1:1", with: "vpn.example.org:443")))
        XCTAssertNoThrow(try SubscriptionFeedNotice.validate(notice + "\n" + notice))
        XCTAssertNoThrow(try SubscriptionFeedNotice.validate("not base64"))
    }

}
