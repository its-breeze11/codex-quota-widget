import Foundation

enum CodexClientError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case connectionClosed
    case requestTimedOut
    case server(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 Codex CLI。请先安装 Codex，或确认 ~/.local/bin/codex 存在。"
        case .launchFailed(let message):
            return "无法启动 Codex App Server：\(message)"
        case .connectionClosed:
            return "Codex App Server 在返回数据前关闭了连接。"
        case .requestTimedOut:
            return "读取 Codex 额度超时。"
        case .server(let message):
            return "Codex 返回错误：\(message)"
        case .malformedResponse:
            return "Codex 返回了无法识别的数据。"
        }
    }
}

struct CodexAppServerClient {
    func fetchSnapshot() async throws -> DashboardSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.fetchBlocking()
        }.value
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            })
        }

        if let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }

        throw CodexClientError.executableNotFound
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
