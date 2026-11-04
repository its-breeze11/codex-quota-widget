import Darwin
import XCTest

@testable import CodexQuotaWidget

private final class RPCResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class RPCRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testIgnoringTerminationStillReturnsTimeoutAndReapsChild() async throws {
        try await exercise(mode: "silent", expected: "timeout")
    }

    func testExitedLeaderWithDescendantHoldingStdoutCannotBlockDeadline() async throws {
        try await exercise(mode: "descendant", expected: "timeout")
    }

    func testEarlyStdoutCloseIsConnectionClosedRatherThanTimeout() async throws {
        try await exercise(mode: "early-close", expected: "closed")
    }

    func testSuccessfulReadCleansUpAChildIgnoringTermination() async throws {
        try await exercise(mode: "valid", expected: "success")
    }

    func testCallerCancellationReachesDetachedWorkerAndReapsChild() async throws {
        try await exercise(mode: "silent", expected: "cancelled", cancel: true)
    }

    private func exercise(mode: String, expected: String, cancel: Bool = false) async throws {
        let script = directory.appendingPathComponent("fixture-helper.sh")
        let body = #"""
            trap '' TERM
            printf '%s\n' "$$" > "$0.pid"
            case MODE in
            descendant)
                /bin/sleep 5 &
                printf '%s\n' "$!" > "$0.child.pid"
                exit 0 ;;
            early-close) exec 1>&- ;;
            valid)
                IFS= read -r line || exit 2
                printf '%s\n' '{"id":1,"result":{}}'
                IFS= read -r line || exit 3
                IFS= read -r line || exit 3
                IFS= read -r line || exit 3
                printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":21}}}}'
                printf '%s\n' '{"id":3,"result":{"summary":{},"dailyUsageBuckets":[]}}' ;;
            esac
            exec /bin/sleep 5
            """#.replacingOccurrences(of: "MODE", with: mode)
        try Data(body.utf8).write(to: script)
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"), argumentPrefix: [script.path],
            requestTimeout: 0.12)
        let box = RPCResultBox()
        let task = Task {
            do {
                _ = try await client.fetchSnapshot()
                box.set("success")
            } catch is CancellationError { box.set("cancelled") } catch CodexClientError
                .requestTimedOut
            { box.set("timeout") } catch CodexClientError.connectionClosed {
                box.set("closed")
            } catch { box.set("other:\(error)") }
        }
        let marker = URL(fileURLWithPath: script.path + ".pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(
            Int32(try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        if cancel { task.cancel() }
        try await Task.sleep(nanoseconds: 450_000_000)
        let observed = box.get()
        let childStillExists = kill(pid, 0) == 0
        // The fixture exits naturally after five seconds if a regression prevents
        // cleanup; recording the deadline precedes that fallback.
        if observed == nil { task.cancel() }
        await task.value
        XCTAssertEqual(observed, expected)
        XCTAssertFalse(childStillExists, "owned child must be reaped before completion")
        let childMarker = URL(fileURLWithPath: script.path + ".child.pid")
        if let text = try? String(contentsOf: childMarker),
            let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            XCTAssertEqual(
                kill(child, 0), -1, "owned descendant must not retain the pipe after cleanup")
            XCTAssertEqual(errno, ESRCH)
        }
    }
}
