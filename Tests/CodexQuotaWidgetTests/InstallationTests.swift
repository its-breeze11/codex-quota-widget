import Darwin
import XCTest

@testable import CodexQuotaWidget

private final class InstallationFixture: @unchecked Sendable {
  let child: FakeCLIFixture
  let executable: URL
  let prefix: URL
  init(_ body: String) throws {
    child = try FakeCLIFixture(body)
    executable = child.directory.appendingPathComponent("synthetic-installer")
    prefix = child.directory.appendingPathComponent("synthetic prefix ' 合成")
    try Data(("#!/bin/sh\nexec /bin/sh '" + child.script.path + "' \"$@\"\n").utf8).write(
      to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }
  func client(ready: @Sendable @escaping () -> Bool = { true }, requestTimeout: TimeInterval = 15, installationTimeout: TimeInterval = 300)
    -> CodexAppServerClient
  {
    CodexAppServerClient(
      requestTimeout: requestTimeout,
      installationOperation: {
        try CodexAppServerClient.runInstaller(
          executableURL: self.executable, prefix: self.prefix, timeout: installationTimeout, isInstalled: ready)
      })
  }
}
private final class InstallationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func invoke(_ result: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return result
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
}

private actor InstallationGate {
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}

final class InstallationTests: XCTestCase {
  func testCancellationStopsIgnoringTermChildBeforeReturning() async throws {
    let fixture = try InstallationFixture(FakeCLIFixture.hold)
    let task = Task.detached { try await fixture.client().installCLI() }
    try await fixture.child.waitForLaunch()
    let start = Date()
    task.cancel()
    do {
      try await task.value
      XCTFail("must cancel")
    } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.7)
    fixture.child.assertReaped()
  }
  func testAlreadyCancelledCallerNeverLaunchesOrVerifies() async throws {
    let fixture = try InstallationFixture("exit 0")
    let gate = InstallationGate()
    let probe = InstallationProbe()
    let task = Task.detached {
      await gate.wait()
      try await fixture.client(ready: { probe.invoke(true) }).installCLI()
    }
    task.cancel()
    await gate.open()
    do {
      try await task.value
      XCTFail("must cancel")
    } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    XCTAssertTrue(fixture.child.processIDs.isEmpty)
    XCTAssertEqual(probe.count, 0)
  }
  func testSuccessPreservesArgumentsAndReadinessCheck() async throws {
    let fixture = try InstallationFixture("printf '%s\\n' \"$@\" > \"$0.argv\"\nexit 0")
    let probe = InstallationProbe()
    try await fixture.client(ready: { probe.invoke(true) }).installCLI()
    XCTAssertEqual(
      fixture.child.text(".argv").split(separator: "\n").map(String.init),
      ["install", "--global", "--prefix", fixture.prefix.path, "@openai/codex@0.146.0"])
    XCTAssertEqual(probe.count, 1)
    fixture.child.assertReaped()
  }
  func testNonzeroExitPreservesStatusAndDoesNotCheckReadiness() async throws {
    let fixture = try InstallationFixture("exit 27")
    let probe = InstallationProbe()
    do {
      try await fixture.client(ready: { probe.invoke(true) }).installCLI()
      XCTFail("must fail")
    } catch CodexClientError.installationFailed(let status) { XCTAssertEqual(status, 27) } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(probe.count, 0)
    fixture.child.assertReaped()
  }
  func testSignalExitPreservesFoundationStatusShape() async throws {
    let fixture = try InstallationFixture("kill -KILL $$")
    do {
      try await fixture.client().installCLI()
      XCTFail("must fail")
    } catch CodexClientError.installationFailed(let status) {
      XCTAssertEqual(status, SIGKILL)
    } catch { XCTFail("unexpected \(error)") }
    fixture.child.assertReaped()
  }
  func testMissingExecutableDoesNotVerifyOrLeakDescriptors() async throws {
    let fixture = try InstallationFixture("exit 0")
    let probe = InstallationProbe()
    let before = descriptorCount()
    for _ in 0..<8 {
      let client = CodexAppServerClient(installationOperation: {
        try CodexAppServerClient.runInstaller(
          executableURL: fixture.child.directory.appendingPathComponent("absent"),
          prefix: fixture.prefix, isInstalled: { probe.invoke(true) })
      })
      do {
        try await client.installCLI()
        XCTFail("must fail")
      } catch CodexClientError.npmNotFound {} catch { XCTFail("unexpected \(error)") }
    }
    XCTAssertEqual(probe.count, 0)
    XCTAssertTrue(fixture.child.processIDs.isEmpty)
    XCTAssertLessThanOrEqual(descriptorCount(), before + 1)
  }
  func testZeroExitWithoutReadyExecutableRemainsFailure() async throws {
    let fixture = try InstallationFixture("exit 0")
    do {
      try await fixture.client(ready: { false }).installCLI()
      XCTFail("must fail")
    } catch CodexClientError.installationFailed(let status) { XCTAssertEqual(status, 0) } catch {
      XCTFail("unexpected \(error)")
    }
    fixture.child.assertReaped()
  }
  func testInstallerGetsEofOnInputAndDiscardsLargeLogs() async throws {
    let body =
      "IFS= read -r line && exit 71\nindex=0\nwhile test \"$index\" -lt 1024; do printf '%s' '"
      + String(repeating: "x", count: 1024) + "'; printf '%s' '"
      + String(repeating: "y", count: 1024) + "' >&2; index=$((index+1)); done\nexit 0"
    let fixture = try InstallationFixture(body)
    let task = Task.detached { try await fixture.client().installCLI() }
    let watchdog = Task.detached {
      try await Task.sleep(nanoseconds: 2_000_000_000)
      task.cancel()
    }
    defer { watchdog.cancel() }
    try await task.value
    fixture.child.assertReaped()
  }
  func testCancellationDoesNotAffectConcurrentInstaller() async throws {
    let cancelled = try InstallationFixture(FakeCLIFixture.hold)
    let normal = try InstallationFixture(
      "while ! test -f \"$0.release\"; do /bin/sleep 0.01; done\nexit 0")
    let first = Task.detached { try await cancelled.client().installCLI() }
    let second = Task.detached { try await normal.client().installCLI() }
    try await cancelled.child.waitForLaunch()
    try await normal.child.waitForLaunch()
    first.cancel()
    do {
      try await first.value
      XCTFail("must cancel")
    } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    for pid in normal.child.processIDs { XCTAssertEqual(kill(pid, 0), 0) }
    try Data().write(to: URL(fileURLWithPath: normal.child.script.path + ".release"))
    try await second.value
    cancelled.child.assertReaped()
    normal.child.assertReaped()
  }
  func testCancellationKeepsPartialSyntheticInstallFiles() async throws {
    let fixture = try InstallationFixture(
      "/bin/mkdir -p \"$4\"\nprintf 'partial-synthetic' > \"$4/marker\"\n" + FakeCLIFixture.hold)
    let marker = fixture.prefix.appendingPathComponent("marker")
    let task = Task.detached { try await fixture.client().installCLI() }
    try await fixture.child.waitForLaunch()
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    task.cancel()
    do {
      try await task.value
      XCTFail("must cancel")
    } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    XCTAssertEqual(try String(contentsOf: marker), "partial-synthetic")
    fixture.child.assertReaped()
  }
  func testInstallationDoesNotInheritRpcDeadline() async throws {
    let fixture = try InstallationFixture("/bin/sleep 0.08\nexit 0")
    try await fixture.client(requestTimeout: 0.001).installCLI()
    fixture.child.assertReaped()
  }
  func testRepeatedSuccessfulInstallersReleaseDescriptors() async throws {
    let fixture = try InstallationFixture("exit 0")
    try await fixture.client().installCLI()
    let before = descriptorCount()
    for _ in 0..<10 { try await fixture.client().installCLI() }
    XCTAssertLessThanOrEqual(descriptorCount(), before + 1)
    XCTAssertEqual(fixture.child.processIDs.count, 11)
    fixture.child.assertReaped()
  }

  @MainActor
  func testSameTurnInstallRequestsLaunchOnlyOnce() async throws {
    let fixture = try InstallationFixture(
      "while ! test -f \"$0.release\"; do /bin/sleep 0.01; done\nexit 0")
    let model = DashboardViewModel(
      client: fixture.client(),
      databaseURL: fixture.child.directory.appendingPathComponent("synthetic.sqlite"))
    model.installCLI()
    model.installCLI()
    XCTAssertTrue(model.isInstallingCLI, "claim installation synchronously before enqueuing work")
    try await fixture.child.waitForLaunch()
    try await Task.sleep(nanoseconds: 100_000_000)
    let launched = fixture.child.processIDs.count
    try Data().write(to: URL(fileURLWithPath: fixture.child.script.path + ".release"))
    for _ in 0..<200 {
      if !model.isInstallingCLI { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(launched, 1)
    XCTAssertFalse(model.isInstallingCLI)
    XCTAssertTrue(model.isCLILoginPromptVisible)
    // A broken busy flag may clear while a second worker still owns a child.
    // Observe disappearance before asserting ownership; do not reap its PID.
    for _ in 0..<200 {
      if fixture.child.processIDs.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    fixture.child.assertReaped()
  }

  @MainActor
  func testFailedInstallClearsBusyStateAndCanBeRetried() async throws {
    let fixture = try InstallationFixture("exit 27")
    let model = DashboardViewModel(
      client: fixture.client(),
      databaseURL: fixture.child.directory.appendingPathComponent("synthetic.sqlite"))
    for expected in 1...2 {
      model.installCLI()
      for _ in 0..<200 {
        if fixture.child.processIDs.count == expected && !model.isInstallingCLI { break }
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      XCTAssertFalse(model.isInstallingCLI)
      XCTAssertNotNil(model.errorMessage)
      XCTAssertFalse(model.isCLILoginPromptVisible)
      XCTAssertEqual(fixture.child.processIDs.count, expected)
    }
    fixture.child.assertReaped()
  }
  private func descriptorCount() -> Int {
    (0..<1024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
  }
}

extension InstallationTests {
  func testInstallerDeadlineStopsChildAndSkipsReadiness() async throws {
    let fixture = try InstallationFixture(FakeCLIFixture.hold)
    let probe = InstallationProbe()
    let start = Date()
    do {
      try await fixture.client(ready: { probe.invoke(true) }, installationTimeout: 0.12).installCLI()
      XCTFail("must time out")
    } catch CodexClientError.installationTimedOut {} catch { XCTFail("unexpected \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    XCTAssertEqual(probe.count, 0); fixture.child.assertReaped()
  }

  func testInvalidInstallerBudgetsDoNotLaunchOrVerify() async throws {
    let fixture = try InstallationFixture("exit 0")
    let probe = InstallationProbe()
    for timeout in [0, -1, TimeInterval.nan, TimeInterval.infinity] {
      do {
        try await fixture.client(ready: { probe.invoke(true) }, installationTimeout: timeout).installCLI()
        XCTFail("must reject")
      } catch CodexClientError.installationTimedOut {} catch { XCTFail("unexpected \(error)") }
    }
    XCTAssertTrue(fixture.child.processIDs.isEmpty); XCTAssertEqual(probe.count, 0)
  }

  func testTimeoutPreservesPartialFilesAndAllowsExplicitRetry() async throws {
    let fixture = try InstallationFixture("/bin/mkdir -p \"$4\"\nprintf 'partial' > \"$4/marker\"\nif ! test -f \"$0.release\"; then " + FakeCLIFixture.hold + "; fi\nexit 0")
    do {
      try await fixture.client(installationTimeout: 1.0).installCLI(); XCTFail("must timeout")
    } catch CodexClientError.installationTimedOut {} catch { XCTFail("unexpected \(error)") }
    XCTAssertEqual(try String(contentsOf: fixture.prefix.appendingPathComponent("marker")), "partial")
    fixture.child.assertReaped()
    try Data().write(to: URL(fileURLWithPath: fixture.child.script.path + ".release"))
    try await fixture.client().installCLI(); XCTAssertEqual(fixture.child.processIDs.count, 2)
    fixture.child.assertReaped()
  }

  func testTimedOutInstallerDoesNotKillConcurrentInstaller() async throws {
    let expired = try InstallationFixture(FakeCLIFixture.hold)
    let normal = try InstallationFixture("/bin/sleep 0.25; exit 0")
    let first = Task.detached { try await expired.client(installationTimeout: 0.12).installCLI() }
    let second = Task.detached { try await normal.client().installCLI() }
    do { try await first.value; XCTFail("must time out") }
    catch CodexClientError.installationTimedOut {} catch { XCTFail("unexpected \(error)") }
    try await second.value; expired.child.assertReaped(); normal.child.assertReaped()
  }

  func testReadinessRequiresExecutableWithinRequestedPrefix() throws {
    let fixture = try InstallationFixture("exit 0")
    XCTAssertNil(CodexAppServerClient.installedExecutable(at: fixture.prefix))
    let bin = fixture.prefix.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let codex = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codex)
    XCTAssertNil(CodexAppServerClient.installedExecutable(at: fixture.prefix))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    XCTAssertEqual(CodexAppServerClient.installedExecutable(at: fixture.prefix), codex)
    try FileManager.default.removeItem(at: codex)
    try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: fixture.executable)
    XCTAssertNil(CodexAppServerClient.installedExecutable(at: fixture.prefix))
  }

  func testReadinessRejectsDirectoryAndFifoAndAllowsPackageSymlink() throws {
    let fixture = try InstallationFixture("exit 0")
    let bin = fixture.prefix.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let codex = bin.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: false)
    XCTAssertNil(CodexAppServerClient.installedExecutable(at: fixture.prefix))
    try FileManager.default.removeItem(at: codex)
    XCTAssertEqual(mkfifo(codex.path, 0o700), 0)
    XCTAssertNil(CodexAppServerClient.installedExecutable(at: fixture.prefix))
    try FileManager.default.removeItem(at: codex)
    let package = fixture.prefix.appendingPathComponent("lib/package")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let real = package.appendingPathComponent("cli")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: real)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: real.path)
    try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: real)
    XCTAssertEqual(CodexAppServerClient.installedExecutable(at: fixture.prefix), codex)
  }

  @MainActor
  func testInstallerTimeoutClearsUiBusyStateAndOffersRetry() async throws {
    let fixture = try InstallationFixture("if ! test -f \"$0.release\"; then " + FakeCLIFixture.hold + "; fi\nexit 0")
    let model = DashboardViewModel(client: fixture.client(installationTimeout: 1),
      databaseURL: fixture.child.directory.appendingPathComponent("synthetic.sqlite"))
    model.installCLI()
    for _ in 0..<400 {
      if !model.isInstallingCLI { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertFalse(model.isInstallingCLI)
    XCTAssertTrue(model.errorMessage?.contains("安装超时") == true)
    XCTAssertFalse(model.isCLILoginPromptVisible)
    fixture.child.assertReaped()
    try Data().write(to: URL(fileURLWithPath: fixture.child.script.path + ".release"))
    model.installCLI()
    for _ in 0..<400 {
      if !model.isInstallingCLI { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertFalse(model.isInstallingCLI); XCTAssertTrue(model.isCLILoginPromptVisible)
    fixture.child.assertReaped()
  }
}
