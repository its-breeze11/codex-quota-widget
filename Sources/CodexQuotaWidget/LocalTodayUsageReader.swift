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
        return usage(for: day, in: sessionsDirectory)
    }

    /// Explicit source for isolated callers; the application keeps its default source.
    static func usage(
        for day: String, in sessionsDirectory: URL, maximumLineBytes: Int = 8 * 1024 * 1024
    ) -> Int64? {
        guard maximumLineBytes > 0 else { return nil }
        guard DailyUsageBucket.utcDate(for: day) != nil else { return nil }
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
                values.isSymbolicLink != true
            else {
                continue
            }
            do {
                let fileUsage = try readUsage(from: fileURL, for: day, maximumLineBytes: maximumLineBytes)
                let (next, overflow) = total.addingReportingOverflow(fileUsage.total)
                guard !overflow else { return nil }
                total = next
                foundTokenEvent = foundTokenEvent || fileUsage.foundTokenEvent
            } catch {
                return nil
            }
        }

        return foundTokenEvent ? total : nil
    }

    /// Session records can contain prompt and response text. Read them in small
    /// chunks and decode only token-count events; raw session content is never
    /// retained beyond the current line or written by this widget.
    private enum ReadError: Error { case counterOverflow, lineTooLarge }

    private static func readUsage(
        from fileURL: URL, for day: String, maximumLineBytes: Int
    ) throws -> (total: Int64, foundTokenEvent: Bool) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var buffer = Data()
        var total: Int64 = 0
        var foundTokenEvent = false
        var previousCumulativeTotal: Int64?

        let fractionalTimestamp = ISO8601DateFormatter()
        fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeTimestamp = ISO8601DateFormatter()
        wholeTimestamp.formatOptions = [.withInternetDateTime]

        func consume(_ line: Data) throws {
            guard
                let event = try? JSONDecoder().decode(TokenCountEvent.self, from: line),
                event.type == "event_msg",
                event.payload?.type == "token_count",
                let timestamp = event.timestamp,
                let date = fractionalTimestamp.date(from: timestamp) ?? wholeTimestamp.date(from: timestamp),
                let cumulativeTotal = event.payload?.info?.totalTokenUsage?.totalTokens,
                cumulativeTotal >= 0
            else {
                return
            }

            if DailyUsageBucket.utcDayKey(for: date) == day {
                let delta = previousCumulativeTotal.map {
                    cumulativeTotal >= $0 ? cumulativeTotal - $0 : cumulativeTotal
                } ?? cumulativeTotal
                let (next, overflow) = total.addingReportingOverflow(delta)
                guard !overflow else { throw ReadError.counterOverflow }
                total = next
                foundTokenEvent = true
            }
            previousCumulativeTotal = cumulativeTotal
        }

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumLineBytes else {
                    throw ReadError.lineTooLarge
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { try consume(line) }
            }
            guard buffer.count <= maximumLineBytes else { throw ReadError.lineTooLarge }
        }
        if !buffer.isEmpty { try consume(buffer) }

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
