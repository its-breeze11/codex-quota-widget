import SQLite3
import XCTest

@testable import CodexQuotaWidget

final class UsageStoreTests: XCTestCase {
    private func withDatabase(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.appendingPathComponent("synthetic.sqlite3"))
    }

    func testValidUpsertsSurviveReopenAndEmptyMerge() async throws {
        try await withDatabase { url in
            let store = try UsageStore(databaseURL: url)
            try await store.merge([
                DailyUsageBucket(startDate: "2031-01-02", tokens: 20),
                DailyUsageBucket(startDate: "2031-01-01", tokens: 10),
            ])
            try await store.merge([DailyUsageBucket(startDate: "2031-01-01", tokens: 15)])
            try await store.merge([])
            let reopened = try UsageStore(databaseURL: url)
            let result = try await reopened.loadAll()
            XCTAssertEqual(
                result,
                [
                    DailyUsageBucket(startDate: "2031-01-01", tokens: 15),
                    DailyUsageBucket(startDate: "2031-01-02", tokens: 20),
                ])
        }
    }

    func testInvalidBatchCannotPartiallyUpdateValidRows() async throws {
        try await withDatabase { url in
            let store = try UsageStore(databaseURL: url)
            try await store.merge([DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
            for invalid in [
                DailyUsageBucket(startDate: "2031-02-30", tokens: 1),
                DailyUsageBucket(startDate: "2031-01-02", tokens: -1),
            ] {
                do {
                    try await store.merge([
                        DailyUsageBucket(startDate: "2031-01-01", tokens: 99), invalid,
                    ])
                    XCTFail("invalid batches must fail")
                } catch {}
                let result = try await store.loadAll()
                XCTAssertEqual(result, [DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
            }
        }
    }

    func testInvalidStoredRowsAreRejectedWithoutReturningPartialHistory() async throws {
        for row in [
            "'2031-02-30', 1", "'2031-01-02', -1", "'2031-01-02', 'not-a-counter'",
            "'2031-01-02', 1.5", "'2031-01-02' || char(0) || 'suffix', 1", "CAST(x'ff' AS TEXT), 1",
        ] {
            try await withDatabase { url in
                let store = try UsageStore(databaseURL: url)
                try await store.merge([DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
                try sql(url, "INSERT INTO daily_usage(date,tokens,fetched_at) VALUES (\(row),0)")
                do {
                    _ = try await store.loadAll()
                    XCTFail("corrupt row must fail the complete read: \(row)")
                } catch {}
            }
        }
    }

    func testSQLiteAutomaticRollbackKeepsConnectionUsable() async throws {
        try await withDatabase { url in
            let store = try UsageStore(databaseURL: url)
            try await store.merge([DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
            try sql(
                url,
                "CREATE TRIGGER injected_rollback BEFORE INSERT ON daily_usage WHEN NEW.date = '2031-01-02' BEGIN SELECT RAISE(ROLLBACK, 'synthetic rollback'); END;"
            )
            do {
                try await store.merge([
                    DailyUsageBucket(startDate: "2031-01-01", tokens: 99),
                    DailyUsageBucket(startDate: "2031-01-02", tokens: 20),
                ])
                XCTFail("injected rollback must fail the merge")
            } catch {}
            let unchanged = try await store.loadAll()
            XCTAssertEqual(unchanged, [DailyUsageBucket(startDate: "2031-01-01", tokens: 10)])
            try sql(url, "DROP TRIGGER injected_rollback")
            try await store.merge([DailyUsageBucket(startDate: "2031-01-02", tokens: 20)])
            let restored = try await store.loadAll()
            XCTAssertEqual(restored.count, 2)
        }
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
