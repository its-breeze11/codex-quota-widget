import Foundation
import SQLite3

enum UsageStoreError: LocalizedError {
    case open(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "无法打开本地历史数据库：\(message)"
        case .execute(let message): return "无法更新本地历史数据库：\(message)"
        }
    }
}

actor UsageStore {
    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL? = nil) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("CodexQuotaWidget", isDirectory: true)
            try FileManager.default.createDirectory(
                at: support,
                withIntermediateDirectories: true
            )
            self.databaseURL = support.appendingPathComponent("usage.sqlite3")
        }

        var pointer: OpaquePointer?
        guard sqlite3_open(self.databaseURL.path, &pointer) == SQLITE_OK else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(pointer)
            throw UsageStoreError.open(message)
        }
        database = pointer

        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS daily_usage (
                date TEXT PRIMARY KEY NOT NULL,
                tokens INTEGER NOT NULL,
                fetched_at REAL NOT NULL
            );
            """
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(pointer, createTableSQL, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorPointer)
            sqlite3_close(pointer)
            database = nil
            throw UsageStoreError.execute(message)
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func merge(_ buckets: [DailyUsageBucket]) throws {
        guard let database else { throw UsageStoreError.open("数据库未初始化") }
        let sql = """
            INSERT INTO daily_usage(date, tokens, fetched_at)
            VALUES (?, ?, ?)
            ON CONFLICT(date) DO UPDATE SET
                tokens = excluded.tokens,
                fetched_at = excluded.fetched_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.execute(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for bucket in buckets {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, bucket.startDate, -1, transient)
            sqlite3_bind_int64(statement, 2, bucket.tokens)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw UsageStoreError.execute(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    func loadAll() throws -> [DailyUsageBucket] {
        guard let database else { throw UsageStoreError.open("数据库未初始化") }
        let sql = "SELECT date, tokens FROM daily_usage ORDER BY date ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.execute(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var buckets: [DailyUsageBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateText = sqlite3_column_text(statement, 0) else { continue }
            buckets.append(
                DailyUsageBucket(
                    startDate: String(cString: dateText),
                    tokens: sqlite3_column_int64(statement, 1)
                )
            )
        }
        return buckets
    }

}
