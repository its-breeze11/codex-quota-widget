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
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var previousCumulativeTotal: Int64?
            for line in contents.split(whereSeparator: \.isNewline) {
                guard let event = try? JSONDecoder().decode(TokenCountEvent.self, from: Data(line.utf8)),
                      event.type == "event_msg",
                      event.payload?.type == "token_count",
                      let timestamp = event.timestamp,
                      let cumulativeTotal = event.payload?.info?.totalTokenUsage?.totalTokens
                else {
                    continue
                }

                let isCurrentDay = timestamp.hasPrefix(day)
                if isCurrentDay {
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
        }

        return foundTokenEvent ? total : nil
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
