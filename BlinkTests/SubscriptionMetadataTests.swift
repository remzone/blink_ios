import XCTest
@testable import Blink

final class SubscriptionMetadataTests: XCTestCase {
    func testFlagsAndJoinedEmojiSurvivePresentation() {
        let country = ProfilePresentation(name: "🇩🇪 Германия • Основной")
        XCTAssertEqual(country.emoji, "🇩🇪"); XCTAssertEqual(country.countryCode, "DE")
        XCTAssertEqual(country.title, "Германия • Основной")
        XCTAssertEqual(ProfilePresentation(name: "👩‍💻 Для работы").emoji, "👩‍💻")
        XCTAssertEqual(ProfilePresentation(name: "✈️ Поездки").emoji, "✈️")
        XCTAssertNil(ProfilePresentation(name: "1. Сервер").emoji)
        XCTAssertNil(ProfilePresentation(name: "🌐 Авто").countryCode)
        XCTAssertEqual(ProfilePresentation(name: "Сервер 🇯🇵").countryCode, "JP")
        XCTAssertEqual(ProfilePresentation(name: "Сервер 🇯🇵").title, "Сервер 🇯🇵")
        XCTAssertEqual(ProfilePresentation.clean("🇫🇷\nParis\u{202E}", limit: 100), "🇫🇷Paris")
    }
    func testHeaderMetadataPrecedesBodyAndParsesTraffic() {
        let title = "⚡ Провайдер"
        let body = Data("#profile-title: Other\n#announce: Обновление серверов\nvless://fixture".utf8)
        let metadata = SubscriptionMetadata.parse(headers: [
            "Profile-Title": "base64:" + Data(title.utf8).base64EncodedString(),
            "Subscription-Userinfo": "upload=1024; download=2048; total=4096; expire=1794222000"
        ], body: body)
        XCTAssertEqual(metadata.title, title); XCTAssertEqual(metadata.used, 3072)
        XCTAssertEqual(metadata.total, 4096); XCTAssertEqual(metadata.expiresAt, 1794222000)
        XCTAssertEqual(metadata.fractionUsed, 0.75); XCTAssertNotNil(metadata.trafficSummary)
        XCTAssertEqual(metadata.announcement, "Обновление серверов")
    }
    func testBase64BodyDirectivesAndInvalidOptionalMetadata() {
        let text = "#profile-title: 🇳🇱 Мой VPN\n#announce: Ready\nvless://fixture"
        let encoded = Data(Data(text.utf8).base64EncodedString().utf8)
        XCTAssertEqual(SubscriptionMetadata.parse(headers: [:], body: encoded).title, "🇳🇱 Мой VPN")
        let invalid = SubscriptionMetadata.parse(headers: ["profile-title": "base64:!", "subscription-userinfo": "upload=-1;download=invalid;total=0;expire=999999999999999"], body: Data())
        XCTAssertNil(invalid.title); XCTAssertNil(invalid.used); XCTAssertNil(invalid.fractionUsed); XCTAssertNil(invalid.expiresAt)
        let overflow = SubscriptionMetadata.parse(headers: ["subscription-userinfo": "upload=9223372036854775807;download=1"], body: Data())
        XCTAssertNil(overflow.used)
        let bounded = SubscriptionMetadata.parse(headers: ["profile-title": String(repeating: "👩‍💻", count: 500)], body: Data())
        XCTAssertLessThanOrEqual(bounded.title?.count ?? 0, 120)
    }
    func testOldSavedProfilesDecodeWithoutMetadata() throws {
        let raw = #"{"id":"00000000-0000-4000-8000-000000000001","name":"🇱🇻 Test","kind":"xray","source":"vless://fixture","subscriptionURL":"https://example.org/sub/fixture"}"#
        var profile = try JSONDecoder().decode(UniversalProfile.self, from: Data(raw.utf8))
        XCTAssertNil(profile.subscriptionMetadata); XCTAssertEqual(profile.presentation.countryCode, "LV")
        profile.subscriptionMetadata = .parse(headers: ["profile-title": "My provider"], body: Data())
        let reopened = try JSONDecoder().decode(UniversalProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(reopened.providerTitle, "My provider")
    }
}
