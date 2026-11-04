import Darwin
import XCTest
@testable import CodexQuotaWidget

final class InputLimitTests: XCTestCase {
    private func session(_ fixture: FakeCLIFixture, line: Int, total: Int = 100_000) throws -> CLIProcessSession {
        try CLIProcessSession(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [fixture.script.path], timeout: 2,
            maximumLineBytes: line, maximumOutputBytes: total)
    }

    func testExactLineAndTotalLimitsWithFinalUnterminatedLine() throws {
        let f = try FakeCLIFixture("printf '1234\\nxy'; exit 0")
        let s = try session(f, line: 4, total: 7); defer { s.close() }
        XCTAssertEqual(try s.nextLine(), Data("1234".utf8))
        XCTAssertEqual(try s.nextLine(), Data("xy".utf8))
        XCTAssertNil(try s.nextLine()); s.close(); f.assertReaped()
    }

    func testOversizedLineWithAndWithoutNewlineRejectsAndReaps() throws {
        for suffix in ["", "\\n"] {
            let f = try FakeCLIFixture("printf '12345\(suffix)'\n" + FakeCLIFixture.hold)
            let s = try session(f, line: 4); defer { s.close() }
            XCTAssertThrowsError(try s.nextLine()) {
                guard case CodexClientError.responseTooLarge = $0 else { return XCTFail("unexpected \($0)") }
            }
            s.close(); f.assertReaped()
        }
    }

    func testLimitCountsUtf8BytesAndHandlesFragmentedLines() throws {
        let f = try FakeCLIFixture("printf 'abc'; /bin/sleep 0.03; printf 'def';\n" + FakeCLIFixture.hold)
        let s = try session(f, line: 5); defer { s.close() }
        XCTAssertThrowsError(try s.nextLine()) {
            guard case CodexClientError.responseTooLarge = $0 else { return XCTFail("unexpected \($0)") }
        }
        s.close(); f.assertReaped()
        let multi = try FakeCLIFixture("printf '你好\\n'; exit 0")
        let exact = try session(multi, line: 6); defer { exact.close() }
        XCTAssertEqual(try exact.nextLine(), Data("你好".utf8)); exact.close(); multi.assertReaped()
        let over = try FakeCLIFixture("printf '你好\\n'; exit 0")
        let limited = try session(over, line: 5); defer { limited.close() }
        XCTAssertThrowsError(try limited.nextLine()); limited.close(); over.assertReaped()
    }

    func testTotalBudgetCountsBlankLinesAndAllSmallFrames() throws {
        let f = try FakeCLIFixture("printf '\\n\\naaaa\\nbbbb\\ncccc\\n'\n" + FakeCLIFixture.hold)
        let s = try session(f, line: 4, total: 10); defer { s.close() }
        XCTAssertThrowsError(try { while try s.nextLine() != nil {} }()) {
            guard case CodexClientError.responseTooLarge = $0 else { return XCTFail("unexpected \($0)") }
        }
        s.close(); f.assertReaped()
    }

    func testInvalidLimitsDoNotLaunchChild() throws {
        let f = try FakeCLIFixture("exit 0")
        for limits in [(0, 1), (1, 0), (-1, 1), (1, -1)] {
            XCTAssertThrowsError(try session(f, line: limits.0, total: limits.1))
        }
        XCTAssertTrue(f.processIDs.isEmpty)
    }

    func testOversizedRpcIsNotRetriedOrReturnedAsPartialSnapshot() async throws {
        let f = try FakeCLIFixture(FakeCLIFixture.handshake + "\nprintf '%s\\n' '" + String(repeating: "x", count: 200) + "'\n" + FakeCLIFixture.hold)
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/bin/sh"),
            argumentPrefix: [f.script.path], requestTimeout: 2, maximumResponseLineBytes: 160)
        do { _ = try await client.fetchSnapshot(); XCTFail("must reject") }
        catch CodexClientError.responseTooLarge {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(f.processIDs.count, 1); f.assertReaped()
    }

    func testOversizedSessionLineMakesUsageUnavailableWithoutEditingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metric = #"{"timestamp":"2031-01-02T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":7}}}}"#
        let url = root.appendingPathComponent("synthetic.jsonl")
        for newline in ["", "\n"] {
            let data = Data((metric + "\n" + String(repeating: "x", count: 2_000) + newline).utf8)
            try data.write(to: url)
            XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root, maximumLineBytes: 1_000))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        for newline in ["", "\n"] {
            try Data((metric + newline).utf8).write(to: url)
            XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root, maximumLineBytes: metric.utf8.count), 7)
            XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root, maximumLineBytes: metric.utf8.count - 1))
        }
        XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root, maximumLineBytes: 0))
    }

    func testLimitFailureDoesNotAffectConcurrentClient() async throws {
        let rejected = try FakeCLIFixture(FakeCLIFixture.handshake + "\nprintf '%s\\n' '" + String(repeating: "x", count: 200) + "'\n" + FakeCLIFixture.hold)
        let normal = try FakeCLIFixture(FakeCLIFixture.handshake + "\n" + FakeCLIFixture.results())
        let limited = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/bin/sh"),
            argumentPrefix: [rejected.script.path], requestTimeout: 2, maximumResponseBytes: 40)
        let first = Task.detached { try await limited.fetchSnapshot() }
        let second = Task.detached { try await normal.client(timeout: 2).fetchSnapshot() }
        do { _ = try await first.value; XCTFail("must reject") }
        catch CodexClientError.responseTooLarge {} catch { XCTFail("unexpected \(error)") }
        _ = try await second.value
        rejected.assertReaped(); normal.assertReaped()
    }

    func testRepeatedOversizedResponsesReleaseDescriptors() throws {
        let f = try FakeCLIFixture("printf '12345'; exit 0")
        let before = (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        for _ in 0..<8 {
            let s = try session(f, line: 4)
            XCTAssertThrowsError(try s.nextLine()); s.close()
        }
        let after = (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        XCTAssertLessThanOrEqual(after, before + 1)
        f.assertReaped()
    }
}
