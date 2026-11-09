import XCTest
@testable import Blink

final class VokopSubscriptionTests: XCTestCase {
    func testCustomerPaymentWarningStartsAtExactly72Hours() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func account(_ remaining: Int64, active: Bool = true) throws -> SubscriptionAccount {
            let raw: [String: Any] = ["schema": "vokop.account.v1", "active": active, "suspended": false, "paid_until": Int64(now.timeIntervalSince1970) + remaining, "remaining_seconds": max(0, remaining), "checked_at": Int64(now.timeIntervalSince1970)]
            return try JSONDecoder().decode(SubscriptionAccount.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        XCTAssertFalse(try account(259201).urgent(at: now))
        XCTAssertTrue(try account(259200).urgent(at: now))
        XCTAssertTrue(try account(-1, active: false).urgent(at: now))
        XCTAssertTrue(try account(500000, active: false).urgent(at: now))
    }

    private let now = Date(timeIntervalSince1970: 1_793_300_100)
    private let fixture = #"{"schema":"vokop.subscription.v1","revision":1,"issued_at":1793300000,"expires_at":1793303600,"profiles":[{"id":"first","name":"Contract fixture (not live)","vless":{"uuid":"00000000-0000-4000-8000-000000000001"},"turn":{"peer_host":"vpn.example.org","peer_port":56000,"vk_call_url":"https://vk.com/call/join/DEMO_TOKEN","streams":2}}]}"#
    private func decode(_ value: String) throws -> VokopSubscription {
        try JSONDecoder().decode(VokopSubscription.self, from: Data(value.utf8))
    }
    func testWireGuardRequiresV2AndCompatibleWrapper() throws {
        var document = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        var profiles = document["profiles"] as! [[String: Any]]
        profiles[0]["backend"] = "wireguard"
        profiles[0]["wireguard"] = "[Interface]\nPrivateKey = fixture\n"
        var turn = profiles[0]["turn"] as! [String: Any]
        turn["protocol"] = "srtp"; profiles[0]["turn"] = turn; document["profiles"] = profiles
        func value() throws -> VokopSubscription { try JSONDecoder().decode(VokopSubscription.self, from: JSONSerialization.data(withJSONObject: document)) }
        XCTAssertThrowsError(try value().validate(now: now))
        document["schema"] = "vokop.subscription.v2"
        XCTAssertNoThrow(try value().validate(now: now))
        XCTAssertEqual(try value().profiles[0].backendTitle, "WireGuard · SRTP")
        turn["protocol"] = "wrap"; profiles[0]["turn"] = turn; document["profiles"] = profiles
        XCTAssertThrowsError(try value().validate(now: now))
        turn["wrap_key"] = String(repeating: "a", count: 64); profiles[0]["turn"] = turn; document["profiles"] = profiles
        XCTAssertNoThrow(try value().validate(now: now))
        turn["protocol"] = "kcp"; profiles[0]["turn"] = turn; document["profiles"] = profiles
        XCTAssertThrowsError(try value().validate(now: now))
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
    func testBothOfficialVKCallDomainsAreAccepted() throws {
        for host in ["vk.com", "www.vk.com", "vk.ru", "www.vk.ru"] {
            let document = fixture.replacingOccurrences(of: "https://vk.com", with: "https://\(host)")
            XCTAssertNoThrow(try decode(document).validate(now: now), host)
        }
    }
    func testDeceptiveAndMalformedVKCallURLsAreRejected() throws {
        let original = "https://vk.com/call/join/DEMO_TOKEN"
        for value in ["https://vk.ru.evil.example/call/join/DEMO_TOKEN",
                      "https://vk.com.evil.example/call/join/DEMO_TOKEN",
                      "https://evilvk.ru/call/join/DEMO_TOKEN",
                      "http://vk.ru/call/join/DEMO_TOKEN",
                      "https://vk.ru:443/call/join/DEMO_TOKEN",
                      "https://user@vk.ru/call/join/DEMO_TOKEN",
                      "https://vk.ru/call/join/DEMO_TOKEN?extra=1",
                      "https://vk.ru/call/join/DEMO_TOKEN#fragment",
                      "https://vk.ru/call/join/DEMO%2FTOKEN",
                      "https://vk.ru/call/join/DEMO_TOKEN/extra"] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: original, with: value)).validate(now: now)) { error in
                guard case SubscriptionError.invalidCallURL = error else {
                    return XCTFail("Expected a specific VK call URL error")
                }
            }
        }
    }
    func testExpiryClockAndRollbackHaveSpecificMessages() throws {
        XCTAssertThrowsError(try decode(fixture).validate(now: Date(timeIntervalSince1970: 1_793_303_600))) { error in
            guard case SubscriptionError.expired = error else { return XCTFail("Expected expiry error") }
        }
        XCTAssertThrowsError(try decode(fixture).validate(now: Date(timeIntervalSince1970: 1_793_299_000))) { error in
            guard case SubscriptionError.futureDocument = error else { return XCTFail("Expected clock error") }
        }
        XCTAssertThrowsError(try decode(fixture).validate(now: now, minimumRevision: 2)) { error in
            guard case SubscriptionError.outdatedRevision = error else { return XCTFail("Expected rollback error") }
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
