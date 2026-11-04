import Darwin
import XCTest

@testable import CodexQuotaWidget

final class FakeCLIFixture {
    let directory: URL
    let script: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fixture-helper.sh")
        let prefix = #"""
            trap '' TERM
            printf '%s\n' "$$" >> "$0.pids"
            printf '%s\n' "$*" >> "$0.arguments"
            """#
        try Data((prefix + "\n" + body + "\n").utf8).write(to: script)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func client(timeout: TimeInterval = 1) -> CodexAppServerClient {
        CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"), argumentPrefix: [script.path],
            requestTimeout: timeout)
    }

    func session(timeout: TimeInterval = 1) throws -> CLIProcessSession {
        try CLIProcessSession(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path],
            timeout: timeout)
    }

    func text(_ suffix: String) -> String {
        (try? String(contentsOf: URL(fileURLWithPath: script.path + suffix))) ?? ""
    }

    var processIDs: [pid_t] {
        text(".pids").split(separator: "\n").compactMap { Int32($0) }
    }

    func waitForLaunch() async throws {
        for _ in 0..<200 {
            if !processIDs.isEmpty { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("fake child did not start")
    }

    func assertReaped(file: StaticString = #filePath, line: UInt = #line) {
        for pid in processIDs {
            XCTAssertEqual(kill(pid, 0), -1, "owned child remains", file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
            var status: Int32 = 0
            XCTAssertEqual(
                waitpid(pid, &status, WNOHANG), -1, "direct child should already be reaped",
                file: file, line: line)
            XCTAssertEqual(errno, ECHILD, file: file, line: line)
        }
    }

    static let handshake = #"""
        IFS= read -r line || exit 2
        printf '%s\n' "$line" >> "$0.requests"
        printf '%s\n' '{"id":1,"result":{}}'
        for index in 1 2 3; do
            IFS= read -r line || exit 3
            printf '%s\n' "$line" >> "$0.requests"
        done
        """#

    static func results(usedPercent: Int = 21) -> String {
        #"""
        printf '%s\n' '{"id":3,"result":{"summary":{},"dailyUsageBuckets":[{"startDate":"2031-01-01","tokens":17}]}}'
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":USED}}}}'
        """#.replacingOccurrences(of: "USED", with: String(usedPercent))
    }

    static let hold = "exec /bin/sleep 5"
}
