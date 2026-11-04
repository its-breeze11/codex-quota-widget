import XCTest

@testable import CodexQuotaWidget

final class ClientCommandTests: XCTestCase {
    func testLoginCommandPreservesApostrophesSpacesAndShellCharacters() throws {
        for name in ["fixture's helper", "fixture' ; printf unsafe > UNEXPECTED; #"] {
            try exercise(name)
        }
    }
    func testOrdinaryLoginCommandStillPassesOnlyLoginArgument() throws {
        try exercise("fixture-helper")
    }
    private func exercise(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(name)
        try Data("#!/bin/sh\n/usr/bin/printf '%s\\n' \"$1\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = root
        process.arguments = ["-c", CodexAppServerClient.loginCommand(for: executable)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "login\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("UNEXPECTED").path))
    }
}
