import Foundation

/// Reads only timestamp and aggregate token counters from local Codex session logs.
/// This is deliberately separate from account history: it represents the current UTC
/// day on this machine and is replaced by Codex's archived value after the day closes.
enum LocalTodayUsageReader {
    static func usage(for day: String) async -> Int64? {
        await Task.detached(priority: .utility) {
            readUsage(for: day)
        }.value
    }

    private static func readUsage(for day: String) -> Int64? {
        let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var total: Int64 = 0
        var foundTokenEvent = false

        for case let fileURL as URL in enumerator {
            guard
                fileURL.pathExtension == "jsonl",
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileUsage = readUsage(from: fileURL, for: day)
            else {
                continue
            }
            total += fileUsage.total
            foundTokenEvent = foundTokenEvent || fileUsage.foundTokenEvent
        }

        return foundTokenEvent ? total : nil
    }

    /// Session records can contain prompt and response text. Read them in small
    /// chunks and decode only token-count events; raw session content is never
    /// retained beyond the current line or written by this widget.
    private static func readUsage(from fileURL: URL, for day: String) -> (total: Int64, foundTokenEvent: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var total: Int64 = 0
        var foundTokenEvent = false
        var previousCumulativeTotal: Int64?

        func consume(_ line: Data) {
            guard
                let event = try? JSONDecoder().decode(TokenCountEvent.self, from: line),
                event.type == "event_msg",
                event.payload?.type == "token_count",
                let timestamp = event.timestamp,
                let cumulativeTotal = event.payload?.info?.totalTokenUsage?.totalTokens
            else {
                return
            }

            if timestamp.hasPrefix(day) {
                foundTokenEvent = true
                if let previousCumulativeTotal {
                    total += cumulativeTotal >= previousCumulativeTotal
                        ? cumulativeTotal - previousCumulativeTotal
                        : cumulativeTotal
                } else {
                    total += cumulativeTotal
                }
            }
            previousCumulativeTotal = cumulativeTotal
        }

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { consume(line) }
            }
        }
        if !buffer.isEmpty { consume(buffer) }

        return (total, foundTokenEvent)
    }
}

private struct TokenCountEvent: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let info: Info?
    }

    struct Info: Decodable {
        let totalTokenUsage: TokenUsage?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
        }
    }

    struct TokenUsage: Decodable {
        let totalTokens: Int64?

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
        }
    }
}
