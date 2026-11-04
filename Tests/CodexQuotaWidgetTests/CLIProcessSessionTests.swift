import Darwin
import XCTest

@testable import CodexQuotaWidget

final class CLIProcessSessionTests: XCTestCase {
    func testBackpressuredWriteChecksDeadlineInsteadOfBlocking() throws {
        let fixture = try FakeCLIFixture(FakeCLIFixture.hold)
        let session = try fixture.session(timeout: 0.12)
        defer { session.close() }
        let start = Date()
        XCTAssertThrowsError(try session.write(Data(repeating: 1, count: 1_000_000))) { error in
            guard case CodexClientError.requestTimedOut = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        session.close()
        fixture.assertReaped()
    }

    func testClosedInputReportsErrorWithoutChangingGlobalSIGPIPE() throws {
        var before = sigaction()
        XCTAssertEqual(sigaction(SIGPIPE, nil, &before), 0)
        let fixture = try FakeCLIFixture("exec 0<&-\nprintf 'ready\\n'\n" + FakeCLIFixture.hold)
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertEqual(try session.nextLine(), Data("ready".utf8))
        XCTAssertThrowsError(try session.write(Data("request".utf8))) { error in
            guard case CodexClientError.connectionClosed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        session.close()
        var after = sigaction()
        XCTAssertEqual(sigaction(SIGPIPE, nil, &after), 0)
        XCTAssertEqual(memcmp(&before, &after, MemoryLayout<sigaction>.size), 0)
        fixture.assertReaped()
    }

    func testReaderPreservesPartialEOFAndSkipsEmptyLines() throws {
        let fixture = try FakeCLIFixture("printf 'one\\n\\ntwo'\nexit 0")
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertEqual(try session.nextLine(), Data("one".utf8))
        XCTAssertEqual(try session.nextLine(), Data("two".utf8))
        XCTAssertNil(try session.nextLine())
        session.close()
        session.close()
        fixture.assertReaped()
    }

    func testMissingExecutableAndInvalidTimeoutsLeaveNoDescriptors() throws {
        let fixture = try FakeCLIFixture(FakeCLIFixture.hold)
        let before = descriptorCount()
        for _ in 0..<20 {
            XCTAssertThrowsError(
                try CLIProcessSession(
                    executableURL: fixture.directory.appendingPathComponent("absent"),
                    arguments: [], timeout: 1))
        }
        for timeout in [0, -1, TimeInterval.nan, TimeInterval.infinity] {
            XCTAssertThrowsError(try fixture.session(timeout: timeout))
        }
        XCTAssertLessThanOrEqual(descriptorCount(), before + 1)
        XCTAssertTrue(fixture.processIDs.isEmpty)
    }

    func testRepeatedSessionsAndIdempotentCloseReleaseDescriptors() throws {
        let fixture = try FakeCLIFixture("exit 0")
        let warmup = try fixture.session()
        _ = try warmup.waitForExit()
        warmup.close()
        let before = descriptorCount()
        for _ in 0..<20 {
            let session = try fixture.session()
            XCTAssertTrue(try session.waitForExit())
            session.close()
            session.close()
        }
        XCTAssertLessThanOrEqual(descriptorCount(), before + 1)
        XCTAssertEqual(fixture.processIDs.count, 21)
        fixture.assertReaped()
    }

    func testUnrelatedParentDescriptorsAreNotInherited() throws {
        let fixture = try FakeCLIFixture("exit 0")
        let file = fixture.directory.appendingPathComponent("synthetic-sentinel")
        try Data("synthetic-only".utf8).write(to: file)
        let original = Darwin.open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(original, 0)
        defer { _ = Darwin.close(original) }
        let sentinel = fcntl(original, F_DUPFD, 200)
        XCTAssertGreaterThanOrEqual(sentinel, 200)
        defer { _ = Darwin.close(sentinel) }
        XCTAssertEqual(fcntl(sentinel, F_GETFD) & FD_CLOEXEC, 0)
        let child = try FakeCLIFixture(
            "if test -e /dev/fd/\(sentinel); then printf 'leaked\\n'; else printf 'clean\\n'; fi\nexit 0"
        )
        let session = try child.session()
        defer { session.close() }
        XCTAssertEqual(try session.nextLine(), Data("clean".utf8))
        session.close()
        child.assertReaped()
    }

    func testContinuousUnterminatedOutputStillChecksDeadline() throws {
        let body =
            "index=0; while test \"$index\" -lt 4000; do printf '%s' '"
            + String(repeating: "x", count: 1000) + "'; index=$((index + 1)); done\n"
            + FakeCLIFixture.hold
        let fixture = try FakeCLIFixture(body)
        let session = try fixture.session(timeout: 0.12)
        defer { session.close() }
        XCTAssertThrowsError(try session.nextLine()) { error in
            guard case CodexClientError.requestTimedOut = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        session.close()
        fixture.assertReaped()
    }

    func testCancellationInterruptsBackpressuredWriteAndReapsChild() async throws {
        let fixture = try FakeCLIFixture(FakeCLIFixture.hold)
        let task = Task.detached {
            let session = try fixture.session(timeout: 2)
            defer { session.close() }
            try session.write(Data(repeating: 1, count: 1_000_000))
        }
        try await fixture.waitForLaunch()
        task.cancel()
        do {
            try await task.value
            XCTFail("must cancel")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        fixture.assertReaped()
    }

    func testFoundationNeighborDoesNotStealRPCChildReaping() throws {
        let neighbor = Process()
        neighbor.executableURL = URL(fileURLWithPath: "/bin/sh")
        neighbor.arguments = ["-c", "/bin/sleep 0.05; exit 0"]
        neighbor.standardInput = FileHandle.nullDevice
        neighbor.standardOutput = FileHandle.nullDevice
        neighbor.standardError = FileHandle.nullDevice
        try neighbor.run()
        defer { neighbor.waitUntilExit() }
        let fixture = try FakeCLIFixture(FakeCLIFixture.hold)
        let session = try fixture.session(timeout: 0.12)
        defer { session.close() }
        XCTAssertThrowsError(try session.nextLine()) { error in
            guard case CodexClientError.requestTimedOut = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        session.close()
        neighbor.waitUntilExit()
        XCTAssertEqual(neighbor.terminationStatus, 0)
        fixture.assertReaped()
    }

    private func descriptorCount() -> Int {
        (0..<1024).reduce(0) { count, descriptor in
            count + (fcntl(Int32(descriptor), F_GETFD) >= 0 ? 1 : 0)
        }
    }
}
