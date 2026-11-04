import Darwin
import XCTest

@testable import CodexQuotaWidget

final class RPCIntegrationTests: XCTestCase {
    func testHandshakeMethodsAndReadOnlyArgumentsRemainCompatible() async throws {
        let fixture = try FakeCLIFixture(
            FakeCLIFixture.handshake + "\n" + FakeCLIFixture.results() + "\n" + FakeCLIFixture.hold)
        let snapshot = try await fixture.client().fetchSnapshot()
        XCTAssertEqual(snapshot.rateLimits.primaryRemainingPercent, 79)
        XCTAssertEqual(snapshot.usage.dailyUsageBuckets?.first?.tokens, 17)
        XCTAssertEqual(fixture.text(".arguments"), "app-server --stdio\n")
        let messages = try fixture.text(".requests").split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(
            messages.compactMap { $0["method"] as? String },
            ["initialize", "initialized", "account/rateLimits/read", "account/usage/read"])
        XCTAssertEqual(messages.compactMap { $0["id"] as? Int }, [1, 2, 3])
        let params = try XCTUnwrap(messages[0]["params"] as? [String: Any])
        XCTAssertEqual((params["capabilities"] as? [String: Bool])?["experimentalApi"], true)
        fixture.assertReaped()
    }

    func testSplitMessagesBlankLinesAndFinalLineWithoutNewline() async throws {
        let body = #"""
            IFS= read -r line || exit 2
            printf '\n{"id":1,"res'
            /bin/sleep 0.02
            printf 'ult":{}}\n'
            for index in 1 2 3; do IFS= read -r line || exit 3; done
            printf '%s\n' '{"method":"synthetic/notice","params":{}}'
            printf '%s\n' '{"id":999,"result":[]}'
            printf '%s\n' '{"id":998,"result":3}'
            printf '%s\n' '{"id":3,"result":{"summary":{},"dailyUsageBuckets":[]}}'
            printf '%s' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42}}}}'
            exit 0
            """#
        let fixture = try FakeCLIFixture(body)
        let snapshot = try await fixture.client().fetchSnapshot()
        XCTAssertEqual(snapshot.rateLimits.primaryRemainingPercent, 58)
        fixture.assertReaped()
    }

    func testEarlyNonzeroExitReportsClosedConnection() async throws {
        let fixture = try FakeCLIFixture("exit 7")
        do {
            _ = try await fixture.client().fetchSnapshot()
            XCTFail("must fail")
        } catch CodexClientError.connectionClosed {} catch { XCTFail("unexpected \(error)") }
        fixture.assertReaped()
    }

    func testEOFBeforeBothResponsesDoesNotReturnPartialSnapshot() async throws {
        let fixture = try FakeCLIFixture(
            FakeCLIFixture.handshake
                + "\nprintf '%s\\n' '{\"id\":2,\"result\":{\"rateLimits\":{}}}'\nexit 0")
        do {
            _ = try await fixture.client().fetchSnapshot()
            XCTFail("must fail")
        } catch CodexClientError.connectionClosed {} catch { XCTFail("unexpected \(error)") }
        fixture.assertReaped()
    }

    func testScalarResultsFailWithoutObjectiveCSerializationException() async throws {
        for result in ["null", "3", "false", "[]"] {
            let body =
                FakeCLIFixture.handshake + "\nprintf '%s\\n' '{\"id\":2,\"result\":\(result)}'\n"
                + FakeCLIFixture.hold
            let fixture = try FakeCLIFixture(body)
            do {
                _ = try await fixture.client().fetchSnapshot()
                XCTFail("must fail")
            } catch CodexClientError.malformedResponse {} catch { XCTFail("unexpected \(error)") }
            XCTAssertEqual(fixture.processIDs.count, 1, "malformed data must not retry")
            fixture.assertReaped()
        }
    }

    func testMalformedJSONFailsAndCleansUp() async throws {
        let fixture = try FakeCLIFixture("printf '%s\\n' '{broken'\n" + FakeCLIFixture.hold)
        do {
            _ = try await fixture.client().fetchSnapshot()
            XCTFail("must fail")
        } catch {}
        XCTAssertEqual(fixture.processIDs.count, 1)
        fixture.assertReaped()
    }

    func testTransientServerErrorRetriesOnceWithFreshProcess() async throws {
        let body =
            FakeCLIFixture.handshake + "\n" + #"""
                if test ! -f "$0.once"; then
                    printf 'yes' > "$0.once"
                    printf '%s\n' '{"id":2,"error":{"message":"synthetic transient"}}'
                    exec /bin/sleep 5
                fi
                """# + "\n" + FakeCLIFixture.results() + "\n" + FakeCLIFixture.hold
        let fixture = try FakeCLIFixture(body)
        _ = try await fixture.client().fetchSnapshot()
        XCTAssertEqual(fixture.processIDs.count, 2)
        fixture.assertReaped()
    }

    func testPersistentServerErrorDoesNotRetryIndefinitely() async throws {
        let fixture = try FakeCLIFixture(
            FakeCLIFixture.handshake
                + "\nprintf '%s\\n' '{\"id\":2,\"error\":{\"message\":\"synthetic\"}}'\n"
                + FakeCLIFixture.hold)
        do {
            _ = try await fixture.client().fetchSnapshot()
            XCTFail("must fail")
        } catch CodexClientError.server {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(fixture.processIDs.count, 2)
        fixture.assertReaped()
    }

    func testCancellationDuringRetryDelayPreventsSecondProcess() async throws {
        let fixture = try FakeCLIFixture(
            FakeCLIFixture.handshake
                + "\nprintf '%s\\n' '{\"id\":2,\"error\":{\"message\":\"synthetic\"}}'\n"
                + FakeCLIFixture.hold)
        let task = Task { try await fixture.client().fetchSnapshot() }
        try await fixture.waitForLaunch()
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("must cancel")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(fixture.processIDs.count, 1)
        fixture.assertReaped()
    }

    func testAlreadyCancelledCallerStartsNoProcess() async throws {
        let fixture = try FakeCLIFixture(FakeCLIFixture.hold)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.client().fetchSnapshot()
        }
        do {
            _ = try await task.value
            XCTFail("must cancel")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        XCTAssertTrue(fixture.processIDs.isEmpty)
    }

    func testConcurrentRequestsHaveIndependentProcessesAndResults() async throws {
        let fixtures = try (0..<6).map { index in
            try FakeCLIFixture(
                FakeCLIFixture.handshake + "\n" + FakeCLIFixture.results(usedPercent: index * 10)
                    + "\n" + FakeCLIFixture.hold)
        }
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for fixture in fixtures {
                group.addTask {
                    let snapshot = try await fixture.client().fetchSnapshot()
                    return try XCTUnwrap(snapshot.rateLimits.primaryRemainingPercent)
                }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values.sorted()
        }
        XCTAssertEqual(results, [50, 60, 70, 80, 90, 100])
        for fixture in fixtures { fixture.assertReaped() }
    }

    func testCancellingOneConcurrentCallDoesNotTerminateAnother() async throws {
        let cancelled = try FakeCLIFixture(FakeCLIFixture.hold)
        let successful = try FakeCLIFixture(
            FakeCLIFixture.handshake + "\n/bin/sleep 0.1\n" + FakeCLIFixture.results() + "\n"
                + FakeCLIFixture.hold)
        let first = Task { try await cancelled.client().fetchSnapshot() }
        let second = Task { try await successful.client().fetchSnapshot() }
        try await cancelled.waitForLaunch()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("must cancel")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        let result = try await second.value
        XCTAssertEqual(result.rateLimits.primaryRemainingPercent, 79)
        cancelled.assertReaped()
        successful.assertReaped()
    }

    func testStoppedChildStillTimesOutAndIsReaped() async throws {
        let fixture = try FakeCLIFixture("kill -STOP $$\n" + FakeCLIFixture.hold)
        do {
            _ = try await fixture.client(timeout: 0.12).fetchSnapshot()
            XCTFail("must time out")
        } catch CodexClientError.requestTimedOut {} catch { XCTFail("unexpected \(error)") }
        fixture.assertReaped()
    }

    func testReadinessStatusIsBoundedAndUsesOnlyLoginStatus() async throws {
        for (body, expected) in [
            ("exit 0", true), ("exit 4", false), (FakeCLIFixture.hold, false),
            ("kill -KILL $$", false),
        ] {
            let fixture = try FakeCLIFixture(body)
            let result = await fixture.client(timeout: 0.12).isLoggedIn()
            XCTAssertEqual(result, expected)
            XCTAssertEqual(fixture.text(".arguments"), "login status\n")
            fixture.assertReaped()
        }
    }

    func testReadinessStatusCancellationReapsActiveChild() async throws {
        let fixture = try FakeCLIFixture(FakeCLIFixture.hold)
        let task = Task { await fixture.client().isLoggedIn() }
        try await fixture.waitForLaunch()
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        fixture.assertReaped()
        let neverStarted = try FakeCLIFixture(FakeCLIFixture.hold)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await neverStarted.client().isLoggedIn()
        }
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(neverStarted.processIDs.isEmpty)
    }
    func testOneClientCanRunIndependentConcurrentSessions() async throws {
        let fixture = try FakeCLIFixture(
            FakeCLIFixture.handshake + "\n" + FakeCLIFixture.results() + "\n" + FakeCLIFixture.hold)
        let client = fixture.client()
        let count = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    let snapshot = try await client.fetchSnapshot()
                    return try XCTUnwrap(snapshot.rateLimits.primaryRemainingPercent)
                }
            }
            var count = 0
            for try await result in group {
                XCTAssertEqual(result, 79)
                count += 1
            }
            return count
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(fixture.processIDs.count, 3)
        fixture.assertReaped()
    }

}
