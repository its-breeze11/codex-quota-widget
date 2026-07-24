import Foundation

struct CreditsSnapshot: Codable, Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitWindow: Codable, Equatable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int {
        min(100, max(0, 100 - usedPercent))
    }

    var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

struct RateLimitSnapshot: Codable, Equatable, Identifiable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
    let rateLimitReachedType: String?

    var id: String { limitId ?? limitName ?? "default" }

    var displayName: String {
        if let limitName, !limitName.isEmpty { return limitName }
        if limitId == "codex" { return "Codex" }
        return limitId ?? "Codex"
    }
}

struct ResetCredit: Codable, Equatable, Identifiable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?

    var expirationDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

struct ResetCreditsSummary: Codable, Equatable {
    let availableCount: Int
    let credits: [ResetCredit]?
}

struct RateLimitsResponse: Codable, Equatable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: ResetCreditsSummary?

    var orderedBuckets: [RateLimitSnapshot] {
        let values: [RateLimitSnapshot]
        if let rateLimitsByLimitId {
            values = Array(rateLimitsByLimitId.values)
        } else {
            values = [rateLimits]
        }
        return values.sorted {
            if $0.limitId == "codex" { return true }
            if $1.limitId == "codex" { return false }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var primaryDisplayBuckets: [RateLimitSnapshot] {
        let primaryBuckets = orderedBuckets.filter { $0.limitId == "codex" }
        return primaryBuckets.isEmpty ? [rateLimits] : primaryBuckets
    }
}

struct AccountTokenUsageSummary: Codable, Equatable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct DailyUsageBucket: Codable, Equatable, Identifiable {
    let startDate: String
    let tokens: Int64

    var id: String { startDate }

    var date: Date? {
        Self.dateFormatter.date(from: startDate)
    }

    static func utcDayKey(for date: Date = .now) -> String {
        dateFormatter.string(from: date)
    }

    static func utcDate(for dayKey: String) -> Date? {
        dateFormatter.date(from: dayKey)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct UsageWindowCalculation: Equatable {
    let dayCount: Int
    let startDate: String?
    let endDate: String?
    let buckets: [DailyUsageBucket]

    var totalTokens: Int64 {
        buckets.reduce(into: Int64.zero) { $0 += $1.tokens }
    }
}

enum UsageRollingWindow {
    static func calculate(days: Int, from history: [DailyUsageBucket]) -> UsageWindowCalculation {
        guard
            days > 0,
            let latestDate = history.compactMap(\.date).max(),
            let lowerBound = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -(days - 1),
                to: latestDate
            )
        else {
            return UsageWindowCalculation(
                dayCount: days,
                startDate: nil,
                endDate: nil,
                buckets: []
            )
        }

        let buckets = history
            .filter { bucket in
                guard let date = bucket.date else { return false }
                return date >= lowerBound && date <= latestDate
            }
            .sorted { $0.startDate < $1.startDate }

        return UsageWindowCalculation(
            dayCount: days,
            startDate: DailyUsageBucket.utcDayKey(for: lowerBound),
            endDate: DailyUsageBucket.utcDayKey(for: latestDate),
            buckets: buckets
        )
    }
}

enum UsageArchivePolicy {
    static func completedBuckets(
        from codexHistory: [DailyUsageBucket],
        currentDay: String,
        recentDays: Int? = nil
    ) -> [DailyUsageBucket] {
        let completed = codexHistory.filter { $0.startDate < currentDay }
        guard
            let recentDays,
            recentDays > 0,
            let currentDate = DailyUsageBucket.utcDate(for: currentDay)
        else {
            return completed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let lowerBound = calendar.date(
                byAdding: .day,
                value: -recentDays,
                to: currentDate
        ) else {
            return completed
        }

        return completed.filter { bucket in
            guard let date = bucket.date else { return false }
            return date >= lowerBound
        }
    }

    static func displayedHistory(
        archive: [DailyUsageBucket],
        codexHistory: [DailyUsageBucket],
        currentDay: String
    ) -> [DailyUsageBucket] {
        let archivedDays = archive.filter { $0.startDate < currentDay }
        let liveCurrentDay = codexHistory.filter { $0.startDate == currentDay }
        return (archivedDays + liveCurrentDay).sorted { $0.startDate < $1.startDate }
    }

    static func repairBuckets(
        archive: [DailyUsageBucket],
        codexHistory: [DailyUsageBucket],
        currentDay: String,
        recentDays: Int? = nil
    ) -> [DailyUsageBucket] {
        let archivedTokens = archive.reduce(into: [String: Int64]()) { values, bucket in
            values[bucket.startDate] = bucket.tokens
        }
        return completedBuckets(
            from: codexHistory,
            currentDay: currentDay,
            recentDays: recentDays
        ).filter {
            archivedTokens[$0.startDate] != $0.tokens
        }
    }
}

enum ArchiveVerificationStatus: Equatable {
    case idle
    case verifying
    case completed(checkedDays: Int, repairedDays: Int)
    case failed(String)
}

struct TokenUsageResponse: Codable, Equatable {
    let summary: AccountTokenUsageSummary
    let dailyUsageBuckets: [DailyUsageBucket]?
}

struct DashboardSnapshot: Equatable {
    let rateLimits: RateLimitsResponse
    let usage: TokenUsageResponse
    let fetchedAt: Date
}

extension Int64 {
    var millionTokenCount: String {
        let millions = Double(self) / 1_000_000
        let magnitude = abs(millions)
        if magnitude >= 100 {
            return String(format: "%.0fM", millions)
        }
        if magnitude >= 10 {
            return String(format: "%.1fM", millions)
        }
        return String(format: "%.2fM", millions)
    }
}

extension Date {
    var yyyyMMddDashed: String {
        Self.yyyyMMddDashedFormatter.string(from: self)
    }

    private static let yyyyMMddDashedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
