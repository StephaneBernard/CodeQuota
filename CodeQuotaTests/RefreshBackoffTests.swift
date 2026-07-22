import XCTest
@testable import CodeQuota

final class RefreshBackoffTests: XCTestCase {

    private func makeBackoff() -> RefreshBackoff {
        RefreshBackoff(base: 60, max: 900)
    }

    func testStartsAtBaseInterval() {
        XCTAssertEqual(makeBackoff().interval, 60)
    }

    func testIncreaseDoublesInterval() {
        var backoff = makeBackoff()
        backoff.increase()
        XCTAssertEqual(backoff.interval, 120)
        backoff.increase()
        XCTAssertEqual(backoff.interval, 240)
    }

    func testIncreaseIsCappedAtMax() {
        var backoff = makeBackoff()
        for _ in 0..<10 { backoff.increase() }
        XCTAssertEqual(backoff.interval, 900)
    }

    func testResetReturnsToBase() {
        var backoff = makeBackoff()
        backoff.increase()
        backoff.increase()
        backoff.reset()
        XCTAssertEqual(backoff.interval, 60)
    }

    func testApplyRetryAfterUsesHeaderValue() {
        var backoff = makeBackoff()
        backoff.apply(retryAfter: 300)
        XCTAssertEqual(backoff.interval, 300)
    }

    func testApplyRetryAfterClampsBelowBase() {
        var backoff = makeBackoff()
        backoff.apply(retryAfter: 5)
        XCTAssertEqual(backoff.interval, 60)
    }

    func testApplyRetryAfterClampsAboveMax() {
        var backoff = makeBackoff()
        backoff.apply(retryAfter: 5000)
        XCTAssertEqual(backoff.interval, 900)
    }

    func testApplyWithoutRetryAfterFallsBackToDoubling() {
        var backoff = makeBackoff()
        backoff.apply(retryAfter: nil)
        XCTAssertEqual(backoff.interval, 120)
    }
}
