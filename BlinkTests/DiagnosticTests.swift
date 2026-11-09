import XCTest
@testable import Blink

final class DiagnosticTests: XCTestCase {
    func testSharedWireFixtureUsesNumericEvidence() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "diagnostics.v1", withExtension: "json"))
        let events = try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: url))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first?.fields["footprintBytes"], 42000000)
        XCTAssertFalse(events.contains { $0.fields.keys.contains("token") })
    }
    func testDestinationsKeepTokensOutOfUploadURL() throws {
        for (url, kind) in [
            ("https://panel.example/base/api/vokop/v1/subscriptions/fixture_token_012345678901234567890123", "vokop"),
            ("https://panel.example/base/sub/fixture_token_012345678901234567890123", "standard"),
            ("https://panel.example/base/api/vokop/v1/diagnostics/enroll/fixture_token_012345678901234567890123", "grant")
        ] {
            let value = try XCTUnwrap(DiagnosticCredential.destination(url))
            XCTAssertEqual(value.kind, kind)
            XCTAssertEqual(value.endpoint, "https://panel.example/base/api/vokop/v1/diagnostics/sessions")
            XCTAssertFalse(value.endpoint.contains("fixture_token"))
        }
        for url in ["http://panel.example/sub/fixture_token_01234567890", "https://user:pass@panel.example/sub/fixture_token_01234567890", "https://panel.example/sub/bad/token", "https://panel.example/sub/a"] {
            XCTAssertNil(DiagnosticCredential.destination(url))
        }
    }
    func testJournalSurvivesRecorderRecreationWithoutCredentials() throws {
        let id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at: DiagnosticStore.directory(id)) }
        let recorder = DiagnosticRecorder(sessionID: id)
        recorder.record("connection.begin", fields: ["mode": 1], critical: true)
        let resumed = DiagnosticRecorder(sessionID: id, source: "extension")
        resumed.record("extension.heartbeat", fields: ["footprintBytes": 42000000], critical: true)
        let events = DiagnosticStore.pending(id)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map { $0.1.source }), ["app", "extension"])
        XCTAssertEqual(resumed.session.id, recorder.session.id)
    }
    func testInvalidatedRecorderCannotRepopulateClearedJournal() throws {
        let id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at: DiagnosticStore.directory(id)) }
        let recorder = DiagnosticRecorder(sessionID: id)
        recorder.record("app.launch", critical: true)
        recorder.invalidateAndDrain()
        try FileManager.default.removeItem(at: DiagnosticStore.directory(id))
        recorder.record("app.foreground", critical: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiagnosticStore.directory(id).path))
    }
    func testBoundedHTTPResponseParserHandlesChunkingAndRejectsTruncation() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertEqual(try DiagnosticHTTPParser.parse(plain).get().data, Data("{}".utf8))
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n1\r\n}\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(try DiagnosticHTTPParser.parse(chunked).get().data, Data("{}".utf8))
        for raw in ["HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}xx0\r\n\r\n", "invalid"] {
            XCTAssertThrowsError(try DiagnosticHTTPParser.parse(Data(raw.utf8)).get())
        }
    }
}
