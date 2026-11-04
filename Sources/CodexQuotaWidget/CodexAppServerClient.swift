import AppKit
import Foundation

enum CodexClientError: LocalizedError {
    case executableNotFound
    case npmNotFound
    case installationFailed(Int32)
    case installationTimedOut
    case responseTooLarge
    case launchFailed(String)
    case connectionClosed
    case requestTimedOut
    case server(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未检测到 Codex CLI。"
        case .npmNotFound:
            return "未检测到 Node.js/npm，暂时无法安装 Codex CLI。"
        case .installationFailed(let status):
            return "Codex CLI 安装失败（退出码 \(status)）。请检查网络后重试。"
        case .installationTimedOut:
            return "Codex CLI 安装超时，安装进程已停止。可能留有部分文件，请检查安装状态后重试。"
        case .responseTooLarge:
            return "Codex 返回的数据超过读取上限，本次刷新已停止。"
        case .launchFailed(let message):
            return "无法启动 Codex App Server：\(message)"
        case .connectionClosed:
            return "Codex App Server 在返回数据前关闭了连接。"
        case .requestTimedOut:
            return "读取 Codex 额度超时。"
        case .server:
            return "Codex 账户信息暂时不可用，请稍后重试。"
        case .malformedResponse:
            return "Codex 返回了无法识别的数据。"
        }
    }
}

struct CodexAppServerClient {
    /// Keep the executable installed by the widget reproducible. Upgrades are
    /// intentional source changes instead of a moving `latest` tag.
    private static let codexCLIVersion = "0.146.0"
    private let executableOverride: URL?
    private let argumentPrefix: [String]
    private let requestTimeout: TimeInterval
    private let maximumResponseLineBytes: Int
    private let maximumResponseBytes: Int
    private let installationOperation: @Sendable () throws -> Void

    init(
        executableURL: URL? = nil, argumentPrefix: [String] = [], requestTimeout: TimeInterval = 15,
        installationOperation: (@Sendable () throws -> Void)? = nil,
        maximumResponseLineBytes: Int = 8 * 1024 * 1024, maximumResponseBytes: Int = 32 * 1024 * 1024
    ) {
        executableOverride = executableURL
        self.argumentPrefix = argumentPrefix
        self.requestTimeout = requestTimeout
        self.maximumResponseLineBytes = maximumResponseLineBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.installationOperation = installationOperation ?? { try Self.installBlocking() }
    }

    func fetchSnapshot() async throws -> DashboardSnapshot {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try await self.fetchWithRetry() }
        return try await withTaskCancellationHandler(operation: {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        }, onCancel: { worker.cancel() })
    }

    /// Installs the CLI into the current user's home directory. This deliberately
    /// avoids `sudo` and never changes a system-wide Node installation.
    func installCLI() async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try self.installationOperation()
        }
        try await withTaskCancellationHandler(operation: {
            try await worker.value
            try Task.checkCancellation()
        }, onCancel: { worker.cancel() })
    }

    private static func installBlocking() throws {
        try Task.checkCancellation()
        let npmURL: URL
        do {
            npmURL = try locateExecutable(named: "npm")
        } catch {
            throw CodexClientError.npmNotFound
        }
        let prefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local")
        try runInstaller(executableURL: npmURL, prefix: prefix) {
            installedExecutable(at: prefix) != nil
        }
    }

    /// Blocking worker port. Tests supply only a temporary fake executable,
    /// prefix and readiness check. The application calls it only after consent.
    static func installedExecutable(at prefix: URL) -> URL? {
        let executable = prefix.appendingPathComponent("bin/codex")
        let resolvedExecutable = executable.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPrefix = prefix.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard resolvedExecutable.path.hasPrefix(resolvedPrefix),
            (try? resolvedExecutable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    static func runInstaller(
        executableURL: URL, prefix: URL, timeout: TimeInterval = 300, isInstalled: () -> Bool
    ) throws {
        try Task.checkCancellation()
        let session: CLIProcessSession
        do {
            session = try CLIProcessSession(
                executableURL: executableURL,
                arguments: [
                    "install", "--global", "--prefix", prefix.path,
                    "@openai/codex@\(codexCLIVersion)"
                ],
                // Installation has its own five-minute budget, independent of RPC.
                timeout: timeout, captureOutput: false, pipeInput: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch CodexClientError.requestTimedOut {
            throw CodexClientError.installationTimedOut
        } catch {
            throw CodexClientError.npmNotFound
        }
        defer { session.close() }
        let status: Int32
        do { status = try session.waitForExitStatus() }
        catch CodexClientError.requestTimedOut { throw CodexClientError.installationTimedOut }
        guard status == 0 else { throw CodexClientError.installationFailed(status) }
        try Task.checkCancellation()
        guard isInstalled() else { throw CodexClientError.installationFailed(status) }
    }

    /// `codex login` owns the interactive browser authorization.  Its status
    /// command is intentionally used only as a post-login readiness check; the
    /// widget never reads or stores the resulting credential.
    func isLoggedIn() async -> Bool {
        guard !Task.isCancelled else { return false }
        let worker = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let executable = try executableOverride ?? Self.locateCodexExecutable()
                let session = try CLIProcessSession(
                    executableURL: executable,
                    arguments: argumentPrefix + ["login", "status"],
                    timeout: requestTimeout,
                    captureOutput: false
                )
                defer { session.close() }
                return try session.waitForExit()
            } catch { return false }
        }
        return await withTaskCancellationHandler(operation: {
            let result = await worker.value
            return !Task.isCancelled && result
        }, onCancel: { worker.cancel() })
    }

    /// Login is deliberately performed in Terminal so Codex receives a real
    /// interactive TTY for its browser/device authorization flow. macOS may
    /// ask for Automation permission to open Terminal; that permission exists
    /// solely to start this user-visible command.
    func openLoginInTerminal() throws {
        let executable = try Self.locateCodexExecutable()
        let command = Self.loginCommand(for: executable)
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.appleScriptEscape(command))"
        end tell
        """
        var error: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
            let message = error?[NSAppleScript.errorMessage] as? String ?? "无法打开终端"
            throw CodexClientError.launchFailed(message)
        }
    }

    static func openNodeDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://nodejs.org/en/download")!)
    }

    private func fetchWithRetry() async throws -> DashboardSnapshot {
        do {
            return try fetchBlocking()
        } catch CodexClientError.server {
            // The App Server occasionally returns a transient profile-read
            // failure while its ChatGPT session is refreshing. Retry once
            // before surfacing a stale-data warning to the widget.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try fetchBlocking()
        }
    }

    private func fetchBlocking() throws -> DashboardSnapshot {
        try Task.checkCancellation()
        let executableURL = try executableOverride ?? Self.locateCodexExecutable()
        let session = try CLIProcessSession(
            executableURL: executableURL,
            arguments: argumentPrefix + ["app-server", "--stdio"],
            timeout: requestTimeout,
            maximumLineBytes: maximumResponseLineBytes, maximumOutputBytes: maximumResponseBytes
        )
        defer { session.close() }

        try session.send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-quota-widget",
                        "version": "0.1.0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ]
        )

        var didInitialize = false
        var rateLimits: RateLimitsResponse?
        var usage: TokenUsageResponse?

        while rateLimits == nil || usage == nil {
            guard let messageData = try session.nextLine() else {
                throw CodexClientError.connectionClosed
            }

            guard
                let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
            else {
                continue
            }

            if let error = object["error"] as? [String: Any] {
                throw CodexClientError.server(error["message"] as? String ?? "未知错误")
            }

            guard let id = object["id"] as? Int else { continue }

            if id == 1, object["result"] != nil, !didInitialize {
                didInitialize = true
                try session.send(["method": "initialized"])
                try session.send(["id": 2, "method": "account/rateLimits/read"])
                try session.send(["id": 3, "method": "account/usage/read"])
                continue
            }

            guard id == 2 || id == 3, let result = object["result"] else { continue }
            guard result is [String: Any] else { throw CodexClientError.malformedResponse }
            let resultData = try JSONSerialization.data(withJSONObject: result)

            switch id {
            case 2:
                rateLimits = try JSONDecoder().decode(RateLimitsResponse.self, from: resultData)
            case 3:
                usage = try JSONDecoder().decode(TokenUsageResponse.self, from: resultData)
            default:
                break
            }
        }

        guard let rateLimits, let usage else {
            throw CodexClientError.malformedResponse
        }

        return DashboardSnapshot(rateLimits: rateLimits, usage: usage, fetchedAt: Date())
    }

    private static func locateCodexExecutable() throws -> URL {
        do {
            return try locateExecutable(named: "codex")
        } catch {
            throw CodexClientError.executableNotFound
        }
    }

    private static func locateExecutable(named name: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".local/bin/node/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".codex/bin"),
            home.appendingPathComponent(".codex/packages/standalone/current/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin")
        ]

        if let nodeVersions = try? FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent(".nvm/versions/node"),
            includingPropertiesForKeys: nil
        ) {
            directories.append(contentsOf: nodeVersions.map { $0.appendingPathComponent("bin") })
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0))
            })
        }

        if let executable = directories
            .map({ $0.appendingPathComponent(name) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }

        throw CodexClientError.executableNotFound
    }

    static func loginCommand(for executable: URL) -> String {
        shellQuote(executable.path) + " login"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
