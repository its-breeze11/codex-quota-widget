import Foundation

enum CodexClientError: LocalizedError {
    case executableNotFound
    case installerNotAvailable
    case installationFailed(Int32)
    case launchFailed(String)
    case connectionClosed
    case requestTimedOut
    case server(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未检测到 Codex CLI。"
        case .installerNotAvailable:
            return "未找到 Node/npm，无法自动安装 Codex CLI。请先安装 Node.js 后重试。"
        case .installationFailed(let status):
            return "Codex CLI 安装失败（退出码 \(status)）。请检查网络后重试。"
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
    func fetchSnapshot() async throws -> DashboardSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.fetchWithRetry()
        }.value
    }

    /// Installs the CLI into the current user's home directory. This deliberately
    /// avoids `sudo` and never changes a system-wide Node installation.
    func installCLI() async throws {
        try await Task.detached(priority: .utility) {
            let npmURL = try Self.locateExecutable(named: "npm")
            let home = FileManager.default.homeDirectoryForCurrentUser
            let process = Process()
            process.executableURL = npmURL
            process.arguments = [
                "install",
                "--global",
                "--prefix", home.appendingPathComponent(".local").path,
                "@openai/codex@latest"
            ]
            // npm can emit a large progress log. It is intentionally discarded so
            // its pipe cannot block the installation process.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                throw CodexClientError.installerNotAvailable
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw CodexClientError.installationFailed(process.terminationStatus)
            }
            guard (try? Self.locateCodexExecutable()) != nil else {
                throw CodexClientError.installationFailed(process.terminationStatus)
            }
        }.value
    }

    private static func fetchWithRetry() throws -> DashboardSnapshot {
        do {
            return try fetchBlocking()
        } catch CodexClientError.server {
            // The App Server occasionally returns a transient profile-read
            // failure while its ChatGPT session is refreshing. Retry once
            // before surfacing a stale-data warning to the widget.
            Thread.sleep(forTimeInterval: 1)
            return try fetchBlocking()
        }
    }

    private static func fetchBlocking() throws -> DashboardSnapshot {
        let executableURL = try locateCodexExecutable()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexClientError.launchFailed(error.localizedDescription)
        }

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)

        defer {
            timeout.cancel()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }

        try send(
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
            ],
            to: inputPipe.fileHandleForWriting
        )

        var reader = JSONLineReader(handle: outputPipe.fileHandleForReading)
        var didInitialize = false
        var rateLimits: RateLimitsResponse?
        var usage: TokenUsageResponse?

        while rateLimits == nil || usage == nil {
            guard let messageData = try reader.nextLine() else {
                if process.terminationReason == .uncaughtSignal {
                    throw CodexClientError.requestTimedOut
                }
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
                try send(["method": "initialized"], to: inputPipe.fileHandleForWriting)
                try send(["id": 2, "method": "account/rateLimits/read"], to: inputPipe.fileHandleForWriting)
                try send(["id": 3, "method": "account/usage/read"], to: inputPipe.fileHandleForWriting)
                continue
            }

            guard let result = object["result"] else { continue }
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

        try? inputPipe.fileHandleForWriting.close()
        return DashboardSnapshot(rateLimits: rateLimits, usage: usage, fetchedAt: Date())
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
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

        throw CodexClientError.installerNotAvailable
    }
}

private struct JSONLineReader {
    let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func nextLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }

            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk)
        }
    }
}
