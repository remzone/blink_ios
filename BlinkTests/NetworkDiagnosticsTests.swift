import XCTest
@testable import Blink

final class NetworkDiagnosticsTests: XCTestCase {
    func testIPResponsesRejectHTMLAndMalformedValues() {
        XCTAssertEqual(SystemNetworkProbe.validatedIP(" 203.0.113.7\n"), "203.0.113.7")
        XCTAssertEqual(SystemNetworkProbe.validatedIP("2001:db8::1\n"), "2001:db8::1")
        for value in ["", "<html>blocked</html>", "999.1.1.1", "203.0.113.7 injected", "ip=203.0.113.7", "2001:db8::zzz"] {
            XCTAssertNil(SystemNetworkProbe.validatedIP(value))
        }
    }

    func testNetworkErrorsNeverExposeUnderlyingTokenURLs() {
        let secret = "fixture-private-token"
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .cannotFindHost, .serverCertificateUntrusted, .cannotConnectToHost] {
            let error = URLError(code, userInfo: [NSLocalizedDescriptionKey: "https://panel.example/sub/\(secret)", NSURLErrorFailingURLStringErrorKey: "https://panel.example/sub/\(secret)"])
            let description = NetworkRequestError.sanitized(error).localizedDescription
            XCTAssertFalse(description.contains(secret))
            XCTAssertFalse(description.contains("https://"))
        }
        XCTAssertTrue(NetworkRequestError.sanitized(URLError(.cannotFindHost)).localizedDescription.contains("DNS"))
        XCTAssertTrue(NetworkRequestError.sanitized(URLError(.serverCertificateUntrusted)).localizedDescription.contains("TLS"))
    }

    func testMissingTimingsDoNotAppearAsZeroMeasurements() {
        let result = DiagnosticResult(kind: "ip", direct: true, ip: "203.0.113.7", dnsMs: nil, tcpMs: nil, tlsMs: nil, responseMs: nil, totalMs: 10, checkedAt: 0)
        XCTAssertTrue(result.summary.contains("203.0.113.7"))
        XCTAssertFalse(result.summary.contains("DNS"))
    }
}
