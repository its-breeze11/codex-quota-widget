import SQLite3
import XCTest

@testable import CodexQuotaWidget

final class BoundaryRegressionTests: XCTestCase {
    func testUTCWindowDoesNotLoseFirstDayAcrossDST() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        for zone in ["America/New_York", "Europe/Berlin", "Asia/Shanghai", "UTC"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let history = [
                "2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07", "2026-03-08",
                "2026-03-09",
            ]
            .map { DailyUsageBucket(startDate: $0, tokens: 10) }
            let result = UsageRollingWindow.calculate(days: 7, from: history)
            XCTAssertEqual(result.startDate, "2026-03-03", zone)
            XCTAssertEqual(result.buckets.count, 7, zone)
            XCTAssertEqual(result.totalTokens, 70, zone)
        }
    }

    func testInvalidDailyBucketsDoNotDecodeAsValidHistory() {
        for body in [
            #"{"startDate":"not-a-day","tokens":1}"#,
            #"{"startDate":"2026-02-30","tokens":1}"#,
            #"{"startDate":"2026-03-03","tokens":-1}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(DailyUsageBucket.self, from: Data(body.utf8)))
        }
    }

    func testNegativeAggregateIsUnavailable() {
        let calculation = UsageWindowCalculation(
            dayCount: 7, startDate: "2026-03-03", endDate: "2026-03-03",
            buckets: [DailyUsageBucket(startDate: "2026-03-03", tokens: -1)])
        XCTAssertNil(calculation.totalTokens)
    }

    func testMergeFailureRollsBackEarlierChangesInTheSameBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.sqlite3")
        let store = try UsageStore(databaseURL: url)
        try await store.merge([DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
        try sql(
            url,
            "CREATE TRIGGER injected_failure BEFORE INSERT ON daily_usage WHEN NEW.date = '2031-01-02' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;"
        )
        do {
            try await store.merge([
                DailyUsageBucket(startDate: "2031-01-01", tokens: 99),
                DailyUsageBucket(startDate: "2031-01-02", tokens: 20),
            ])
            XCTFail("merge must report the injected failure")
        } catch {}
        let actual = try await store.loadAll()
        XCTAssertEqual(actual, [DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
    }

    func testFailedSQLReadIsNotReportedAsAnEmptyArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.sqlite3")
        let store = try UsageStore(databaseURL: url)
        try sql(
            url,
            "DROP TABLE daily_usage; CREATE VIEW daily_usage AS SELECT '2031-01-01' AS date, json_extract('not-json', '$.x') AS tokens;"
        )
        // Establish that the injected error is raised at sqlite3_step, not prepare.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database, "SELECT date,tokens FROM daily_usage ORDER BY date ASC", -1, &statement,
                nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ERROR)
        sqlite3_finalize(statement)
        do {
            _ = try await store.loadAll()
            XCTFail("failed read must throw, not return []")
        } catch {}
    }

    private func sql(_ url: URL, _ text: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw NSError(domain: "SyntheticSQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "SyntheticSQLite", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }
}
