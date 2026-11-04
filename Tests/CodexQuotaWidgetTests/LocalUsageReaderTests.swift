import XCTest

@testable import CodexQuotaWidget

final class LocalUsageReaderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testCumulativeDeltasResetAndDuplicateEvents() throws {
        try file(
            "a.jsonl",
            [
                event("2031-01-01T23:59:00Z", 100), event("2031-01-02T00:01:00Z", 150),
                event("2031-01-02T00:02:00Z", 5), event("2031-01-02T00:03:00Z", 5),
                event("2031-01-02T00:04:00Z", 8),
            ])
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 58)
    }
    func testOffsetTimestampsAreAssignedToUTCDate() throws {
        try file(
            "a.jsonl",
            [
                event("2031-01-01T22:00:00Z", 100), event("2031-01-02T00:30:00+01:00", 110),
                event("2031-01-01T23:45:00-01:00", 130),
            ])
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 20)
    }
    func testFractionalTimestampsAndFinalLineWithoutNewline() throws {
        try file(
            "a.jsonl",
            [event("2031-01-02T00:01:00.123Z", 1), event("2031-01-02T00:02:00.123456Z", 3)],
            newline: false)
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 3)
    }
    func testMalformedNegativeAndNonTokenEventsDoNotInventZero() throws {
        try file(
            "a.jsonl",
            [
                "{broken", event("2031-01-02BAD", 99), event("2031-01-02T00:00:00Z", Int64.min),
                #"{"type":"response_item","payload":{"text":"synthetic-only"}}"#,
            ])
        XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root))
        try file("b.jsonl", [event("2031-01-02T00:02:00Z", 0)])
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 0)
    }
    func testSymlinkHiddenAndOtherExtensionsAreIgnored() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try file("outside/foreign.jsonl", [event("2031-01-02T00:00:00Z", 99)])
        let scan = root.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        try file("scan/owned.jsonl", [event("2031-01-02T00:00:00Z", 4)])
        try file("scan/other.txt", [event("2031-01-02T00:00:00Z", 8)])
        try file("scan/.hidden.jsonl", [event("2031-01-02T00:00:00Z", 8)])
        try FileManager.default.createSymbolicLink(
            at: scan.appendingPathComponent("link.jsonl"),
            withDestinationURL: outside.appendingPathComponent("foreign.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: scan.appendingPathComponent("directory-link"), withDestinationURL: outside)
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: scan), 4)
    }
    func testOverflowWithinAndAcrossFilesReturnsUnavailable() throws {
        try file(
            "a.jsonl",
            [
                event("2031-01-02T00:00:00Z", Int64.max), event("2031-01-02T00:01:00Z", 0),
                event("2031-01-02T00:02:00Z", 1),
            ])
        XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root))
        try file("a.jsonl", [event("2031-01-02T00:00:00Z", Int64.max)])
        try file("b.jsonl", [event("2031-01-02T00:00:00Z", 1)])
        XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root))
    }
    func testMissingEmptyAndInvalidDayAreUnavailable() throws {
        XCTAssertNil(
            LocalTodayUsageReader.usage(
                for: "2031-01-02", in: root.appendingPathComponent("absent")))
        XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root))
        try file("a.jsonl", [event("2031-01-02T00:00:00Z", 3)])
        for invalid in ["", "2031-01-0", "2031-02-30"] {
            XCTAssertNil(LocalTodayUsageReader.usage(for: invalid, in: root))
        }
    }
    func testLargeSyntheticNonMetricLineDoesNotPersistOrLoseNextCounter() throws {
        let text = String(repeating: "synthetic-content-", count: 140_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "response_item", "payload": ["text": text],
        ])
        try file(
            "a.jsonl", [String(decoding: data, as: UTF8.self), event("2031-01-02T00:01:00Z", 6)])
        let url = root.appendingPathComponent("a.jsonl")
        let before = try Data(contentsOf: url)
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 6)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["a.jsonl"])
    }
    func testUnreadableRegularFileMakesWholeScanUnavailableAndRecovers() throws {
        try file("a.jsonl", [event("2031-01-02T00:00:00Z", 10)])
        try file("b.jsonl", [event("2031-01-02T00:00:00Z", 20)])
        let first = root.appendingPathComponent("a.jsonl")
        let second = root.appendingPathComponent("b.jsonl")
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions]
        defer {
            if let originalPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: first.path)
            }
        }
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 30)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: first.path)
        XCTAssertThrowsError(try FileHandle(forReadingFrom: first), "fixture must deny a regular-file open")
        XCTAssertNil(LocalTodayUsageReader.usage(for: "2031-01-02", in: root),
                     "an unreadable source must not be silently omitted from the total")
        try FileManager.default.setAttributes([.posixPermissions: originalPermissions!], ofItemAtPath: first.path)
        XCTAssertEqual(LocalTodayUsageReader.usage(for: "2031-01-02", in: root), 30)
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["a.jsonl", "b.jsonl"])
    }

    private func event(_ timestamp: String, _ count: Int64) -> String {
        let object: [String: Any] = [
            "timestamp": timestamp, "type": "event_msg",
            "payload": [
                "type": "token_count", "info": ["total_token_usage": ["total_tokens": count]],
            ],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func file(_ name: String, _ lines: [String], newline: Bool = true) throws {
        try Data((lines.joined(separator: "\n") + (newline ? "\n" : "")).utf8).write(
            to: root.appendingPathComponent(name))
    }
}
