import XCTest
@testable import Blink

final class VokopSubscriptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_300_100)
    private let fixture = #"{"schema":"vokop.subscription.v1","revision":1,"issued_at":1793300000,"expires_at":1793303600,"profiles":[{"id":"first","name":"Contract fixture (not live)","vless":{"uuid":"00000000-0000-4000-8000-000000000001"},"turn":{"peer_host":"vpn.example.org","peer_port":56000,"vk_call_url":"https://vk.com/call/join/DEMO_TOKEN","streams":2}}]}"#
    private func decode(_ value: String) throws -> VokopSubscription {
        try JSONDecoder().decode(VokopSubscription.self, from: Data(value.utf8))
    }
    func testPanelFixture() throws {
        let subscription = try decode(fixture)
        try subscription.validate(now: now)
        XCTAssertEqual(subscription.profiles[0].turn.peer_port, 56000)
    }
    func testExpiredAndRollbackFail() throws {
        XCTAssertThrowsError(try decode(fixture).validate(now: Date(timeIntervalSince1970: 1_793_303_600)))
        XCTAssertThrowsError(try decode(fixture).validate(now: now, minimumRevision: 2))
    }
    func testMalformedProfilesFail() throws {
        for (original, replacement) in [("vpn.example.org", "127.0.0.1"), ("56000", "65536"),
                                         ("https://vk.com", "http://vk.com"), ("vokop.subscription.v1", "other.v1")] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: original, with: replacement)).validate(now: now))
        }
    }
    func testFeedURLRequiresExactSecureTokenPath() throws {
        let token = String(repeating: "a", count: 43)
        let good = "https://panel.example/base/api/vokop/v1/subscriptions/\(token)"
        XCTAssertNoThrow(try VokopSubscriptionClient.validatedURL(good))
        for value in [good.replacingOccurrences(of: "https:", with: "http:"), good + "?token=secret", good + "/extra",
                      good.replacingOccurrences(of: "panel.example", with: "user:password@panel.example"), good + "#secret"] {
            XCTAssertThrowsError(try VokopSubscriptionClient.validatedURL(value))
        }
        XCTAssertFalse(SubscriptionError.requestFailed.localizedDescription.contains(token))
    }
}
