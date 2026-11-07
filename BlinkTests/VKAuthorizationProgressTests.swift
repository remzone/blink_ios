import XCTest
@testable import Blink

final class VKAuthorizationProgressTests: XCTestCase {
    func testSubmittedChallengeIsNotPresentedAgainWhileNativeWorkerCatchesUp() {
        var progress = VKAuthorizationProgress()
        XCTAssertTrue(progress.shouldPresent("first"))
        progress.submitted("first")
        XCTAssertFalse(progress.shouldPresent("first"))
        XCTAssertFalse(progress.shouldPresent(""))
        XCTAssertTrue(progress.shouldPresent("second"))
    }

    func testNoTransportDeadlineUntilHumanSubmitsAnswer() {
        let progress = VKAuthorizationProgress()
        XCTAssertFalse(progress.responseTimedOut(now: .distantFuture))
    }

    func testPostAnswerWaitIsBoundedAndNewAnswerGetsANewDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = VKAuthorizationProgress()
        progress.submitted("first", now: start)
        XCTAssertFalse(progress.responseTimedOut(now: start.addingTimeInterval(59)))
        XCTAssertTrue(progress.responseTimedOut(now: start.addingTimeInterval(60)))
        progress.submitted("second", now: start.addingTimeInterval(50))
        XCTAssertFalse(progress.responseTimedOut(now: start.addingTimeInterval(60)))
        XCTAssertTrue(progress.responseTimedOut(now: start.addingTimeInterval(110)))
    }
}
