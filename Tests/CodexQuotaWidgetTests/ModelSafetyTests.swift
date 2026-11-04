import XCTest

@testable import CodexQuotaWidget

final class ModelSafetyTests: XCTestCase {
    func testPercentExtremesCannotOverflowBeforeClamping() {
        for (used, expected) in [
            (Int.min, 100), (-1, 100), (0, 100), (21, 79), (100, 0), (101, 0), (Int.max, 0),
        ] {
            XCTAssertEqual(
                RateLimitWindow(usedPercent: used, windowDurationMins: 60, resetsAt: nil)
                    .remainingPercent, expected)
        }
    }
    func testAggregateOverflowIsUnavailableRatherThanWrappingOrSaturating() {
        let result = UsageWindowCalculation(
            dayCount: 2, startDate: "2031-01-01", endDate: "2031-01-02",
            buckets: [
                .init(startDate: "2031-01-01", tokens: Int64.max),
                .init(startDate: "2031-01-02", tokens: 1),
            ])
        XCTAssertNil(result.totalTokens)
        XCTAssertEqual(
            UsageWindowCalculation(dayCount: 0, startDate: nil, endDate: nil, buckets: [])
                .totalTokens, 0)
    }
    func testCanonicalDayKeysRejectNormalizationAndTrailingContent() {
        for day in ["2031-02-30", "2031-1-01", "2031-01-01junk", "2031-01-01\u{0}junk", ""] {
            XCTAssertNil(DailyUsageBucket.utcDate(for: day), day)
        }
        XCTAssertNotNil(DailyUsageBucket.utcDate(for: "2032-02-29"))
    }
    func testMainQuotaUsesTheSameCodexBucketAsTheDashboard() {
        let response = RateLimitsResponse(
            rateLimits: bucket("model-only", used: 1),
            rateLimitsByLimitId: [
                "codex": bucket("codex", used: 30), "model-only": bucket("model-only", used: 1),
            ], rateLimitResetCredits: nil)
        XCTAssertEqual(response.orderedBuckets.first?.id, "codex")
        XCTAssertEqual(response.primaryDisplayBuckets.map(\.id), ["codex"])
        XCTAssertEqual(response.primaryRemainingPercent, 70)
    }
    func testUnknownExplicitBucketDoesNotMasqueradeAsGlobalQuota() {
        let response = RateLimitsResponse(
            rateLimits: bucket("model-only", used: 10), rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil)
        XCTAssertTrue(response.primaryDisplayBuckets.isEmpty)
        XCTAssertNil(response.primaryRemainingPercent)
        let legacy = RateLimitsResponse(
            rateLimits: bucket(nil, used: 10), rateLimitsByLimitId: nil, rateLimitResetCredits: nil)
        XCTAssertEqual(legacy.primaryRemainingPercent, 90)
    }
    func testEmptyBucketMapPreservesTheLegacyDefault() {
        let response = RateLimitsResponse(
            rateLimits: bucket("codex", used: 20), rateLimitsByLimitId: [:],
            rateLimitResetCredits: nil)
        XCTAssertEqual(response.orderedBuckets.map(\.id), ["codex"])
        XCTAssertEqual(response.primaryRemainingPercent, 80)
    }
    func testMissingCreditDataIsNotPresentedAsZeroOrNoCredits() {
        XCTAssertEqual(ResetCreditsPresentation.countText(nil), "可用次数未知")
        XCTAssertEqual(ResetCreditsPresentation.emptyDetailsText(nil), "服务端未提供重置券信息")
        for details: [ResetCredit]? in [nil, []] {
            let summary = ResetCreditsSummary(availableCount: 3, credits: details)
            XCTAssertEqual(ResetCreditsPresentation.countText(summary), "可用 3 次")
            XCTAssertTrue(ResetCreditsPresentation.emptyDetailsText(summary).contains("明细暂未提供"))
        }
        XCTAssertEqual(
            ResetCreditsPresentation.emptyDetailsText(.init(availableCount: 0, credits: [])),
            "当前没有可用重置券")
        XCTAssertEqual(
            ResetCreditsPresentation.countText(.init(availableCount: -1, credits: [])), "可用次数未知")
    }
    func testAutumnDSTWindowHasExactUTCBoundaries() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let dates = [
            "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01",
            "2026-11-02", "2026-11-03",
        ]
        let result = UsageRollingWindow.calculate(
            days: 7, from: dates.map { .init(startDate: $0, tokens: 1) })
        XCTAssertEqual(result.startDate, "2026-10-28")
        XCTAssertEqual(result.endDate, "2026-11-03")
        XCTAssertEqual(result.buckets.count, 7)
        XCTAssertEqual(result.totalTokens, 7)
    }
    func testValidBucketEncodingKeepsExistingWireFields() throws {
        let bucket = DailyUsageBucket(startDate: "2031-01-01", tokens: 123)
        let data = try JSONEncoder().encode(bucket)
        XCTAssertEqual(try JSONDecoder().decode(DailyUsageBucket.self, from: data), bucket)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["startDate", "tokens"]))
    }
    private func bucket(_ id: String?, used: Int) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: id, limitName: nil,
            primary: .init(usedPercent: used, windowDurationMins: 60, resetsAt: nil),
            secondary: nil, credits: nil, planType: nil, rateLimitReachedType: nil)
    }
}
