import XCTest
@testable import CodexQuotaWidget

final class ModelTests: XCTestCase {
    func testRateLimitDecodingAndRemainingPercent() throws {
        let data = #"""
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": null,
            "primary": {
              "usedPercent": 21,
              "windowDurationMins": 10080,
              "resetsAt": 1784512349
            },
            "secondary": null,
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" },
            "individualLimit": null,
            "planType": "prolite",
            "rateLimitReachedType": null
          },
          "rateLimitsByLimitId": null,
          "rateLimitResetCredits": {
            "availableCount": 3,
            "credits": []
          }
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        XCTAssertEqual(response.rateLimits.primary?.remainingPercent, 79)
        XCTAssertEqual(response.rateLimitResetCredits?.availableCount, 3)
        XCTAssertEqual(response.orderedBuckets.map(\.id), ["codex"])
        XCTAssertEqual(response.primaryDisplayBuckets.map(\.id), ["codex"])
    }

    func testTokenUsageDecoding() throws {
        let data = #"""
        {
          "summary": {
            "lifetimeTokens": 1000,
            "peakDailyTokens": 500,
            "longestRunningTurnSec": 100,
            "currentStreakDays": 4,
            "longestStreakDays": 9
          },
          "dailyUsageBuckets": [
            { "startDate": "2026-07-12", "tokens": 4083954 }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenUsageResponse.self, from: data)
        XCTAssertEqual(response.dailyUsageBuckets?.first?.tokens, 4_083_954)
        XCTAssertEqual(response.summary.currentStreakDays, 4)
        XCTAssertEqual(Int64(4_083_954).millionTokenCount, "4.08M")
        XCTAssertEqual(Int64(3_321_751_708).millionTokenCount, "3322M")
    }

    func testDailyUsageUsesUTCDayKeys() {
        XCTAssertEqual(
            DailyUsageBucket.utcDayKey(for: Date(timeIntervalSince1970: 0)),
            "1970-01-01"
        )
    }

    func testResetCountdownFormatterUsesMinuteGranularityWithSpaces() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            ResetCountdownFormatter.string(
                resetDate: now.addingTimeInterval(2 * 86_400 + 3 * 3_600 + 14 * 60),
                now: now
            ),
            "2 天 3 时 14 分后重置"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(
                resetDate: now.addingTimeInterval(3 * 3_600 + 14 * 60),
                now: now
            ),
            "3 时 14 分后重置"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(resetDate: now.addingTimeInterval(14 * 60), now: now),
            "14 分后重置"
        )
        // 不足 1 分钟按 1 分钟显示，已到/超过重置时间显示"重置中"。
        XCTAssertEqual(
            ResetCountdownFormatter.string(resetDate: now.addingTimeInterval(30), now: now),
            "1 分后重置"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(resetDate: now, now: now),
            "重置中"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(resetDate: now.addingTimeInterval(-100), now: now),
            "重置中"
        )
    }

    func testRollingUsageWindowsUseTheSameDatesAndTotalsAsTheDashboard() {
        let history = [
            DailyUsageBucket(startDate: "2026-06-17", tokens: 17),
            DailyUsageBucket(startDate: "2026-07-09", tokens: 9),
            DailyUsageBucket(startDate: "2026-07-10", tokens: 10),
            DailyUsageBucket(startDate: "2026-07-11", tokens: 11),
            DailyUsageBucket(startDate: "2026-07-13", tokens: 13),
            DailyUsageBucket(startDate: "2026-07-16", tokens: 16)
        ]

        let sevenDay = UsageRollingWindow.calculate(days: 7, from: history)
        XCTAssertEqual(sevenDay.startDate, "2026-07-10")
        XCTAssertEqual(sevenDay.endDate, "2026-07-16")
        XCTAssertEqual(sevenDay.buckets.map(\.startDate), ["2026-07-10", "2026-07-11", "2026-07-13", "2026-07-16"])
        XCTAssertEqual(sevenDay.totalTokens, 50)

        let thirtyDay = UsageRollingWindow.calculate(days: 30, from: history)
        XCTAssertEqual(thirtyDay.startDate, "2026-06-17")
        XCTAssertEqual(thirtyDay.endDate, "2026-07-16")
        XCTAssertEqual(thirtyDay.buckets.map(\.startDate), history.map(\.startDate))
        XCTAssertEqual(thirtyDay.totalTokens, 76)
    }

    func testArchivePolicyUsesOnlyLiveCurrentDayAndFindsRepairs() {
        let archive = [
            DailyUsageBucket(startDate: "2026-07-11", tokens: 10),
            DailyUsageBucket(startDate: "2026-07-13", tokens: 999)
        ]
        let codexHistory = [
            DailyUsageBucket(startDate: "2026-07-11", tokens: 11),
            DailyUsageBucket(startDate: "2026-07-12", tokens: 12),
            DailyUsageBucket(startDate: "2026-07-13", tokens: 13)
        ]

        XCTAssertEqual(
            UsageArchivePolicy.repairBuckets(
                archive: archive,
                codexHistory: codexHistory,
                currentDay: "2026-07-13"
            ).map(\.startDate),
            ["2026-07-11", "2026-07-12"]
        )
        XCTAssertEqual(
            UsageArchivePolicy.displayedHistory(
                archive: archive,
                codexHistory: codexHistory,
                currentDay: "2026-07-13"
            ),
            [
                DailyUsageBucket(startDate: "2026-07-11", tokens: 10),
                DailyUsageBucket(startDate: "2026-07-13", tokens: 13)
            ]
        )
    }

    @MainActor
    func testPanelStartsCollapsedSoExpandingTheBallHidesTheChart() {
        let presentation = PanelPresentation()

        // 初始为悬浮球，且图表默认收起。
        XCTAssertEqual(presentation.mode, .ball)
        XCTAssertFalse(presentation.isChartVisible)
        XCTAssertFalse(presentation.isExpanded)

        // 悬浮球展开后进入面板态，图表仍保持折叠，">>" 才会展开图表。
        presentation.mode = .panel
        XCTAssertTrue(presentation.isExpanded)
        XCTAssertFalse(presentation.isChartVisible)
    }

    func testArchivePolicyLimitsAutomaticRepairToSevenCompletedDays() {
        let codexHistory = (12...19).map {
            DailyUsageBucket(startDate: "2026-07-\($0)", tokens: Int64($0))
        }
        let archive = codexHistory.map { bucket in
            DailyUsageBucket(startDate: bucket.startDate, tokens: bucket.tokens + 1)
        }

        XCTAssertEqual(
            UsageArchivePolicy.completedBuckets(
                from: codexHistory,
                currentDay: "2026-07-20",
                recentDays: 7
            ).map(\.startDate),
            ["2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17", "2026-07-18", "2026-07-19"]
        )
        XCTAssertEqual(
            UsageArchivePolicy.repairBuckets(
                archive: archive,
                codexHistory: codexHistory,
                currentDay: "2026-07-20",
                recentDays: 7
            ).map(\.startDate),
            ["2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17", "2026-07-18", "2026-07-19"]
        )
    }
}
