import Darwin
import Foundation

/// Owns one explicitly requested CLI process and its pipes. Used on a detached worker, never
/// on the main actor. All I/O and cleanup stay on that worker; cancellation is
/// polled rather than closing a descriptor while another thread is using it.
final class CLIProcessSession {
    private var processID: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1
    private let deadline: DispatchTime?
    private var buffer = Data()
    private var reachedEOF = false
    private let maximumLineBytes: Int
    private let maximumOutputBytes: Int
    private var receivedBytes = 0

    init(
        executableURL: URL, arguments: [String], timeout: TimeInterval?,
        captureOutput: Bool = true, pipeInput: Bool = true,
        maximumLineBytes: Int = 8 * 1024 * 1024, maximumOutputBytes: Int = 32 * 1024 * 1024
    )
        throws
    {
        guard maximumLineBytes > 0, maximumOutputBytes > 0 else {
            throw CodexClientError.malformedResponse
        }
        self.maximumLineBytes = maximumLineBytes
        self.maximumOutputBytes = maximumOutputBytes
        if let timeout {
            guard timeout.isFinite, timeout > 0 else { throw CodexClientError.requestTimedOut }
            deadline = .now() + timeout
        } else {
            // Optional only for explicit internal callers. Application RPC, status
            // and installation operations each provide their own finite deadline.
            deadline = nil
        }
        try Task.checkCancellation()

        var descriptors: [Int32] = []
        defer { descriptors.forEach { _ = Darwin.close($0) } }
        func ownedDescriptor(_ descriptor: Int32) throws -> Int32 {
            guard descriptor >= 0 else { throw CodexClientError.launchFailed("无法创建查询管道") }
            // Spawn file actions must not accidentally close stdin/stdout/stderr
            // even if the host started with one of those descriptors closed.
            let result: Int32
            if descriptor < 3 {
                result = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
                _ = Darwin.close(descriptor)
                guard result >= 0 else { throw CodexClientError.launchFailed("无法创建查询管道") }
            } else {
                result = descriptor
            }
            descriptors.append(result)
            guard fcntl(result, F_SETFD, FD_CLOEXEC) != -1 else {
                throw CodexClientError.connectionClosed
            }
            return result
        }
        func ownedPipe() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard Darwin.pipe(&pair) == 0 else { throw CodexClientError.launchFailed("无法创建查询管道") }
            // Register both ends before further operations, including failure.
            let readEnd: Int32
            do { readEnd = try ownedDescriptor(pair[0]) } catch {
                _ = Darwin.close(pair[1])
                throw error
            }
            return (readEnd, try ownedDescriptor(pair[1]))
        }
        let (childInput, parentInput) = try ownedPipe()
        let (parentOutput, childOutput) = try ownedPipe()
        let null = try ownedDescriptor(Darwin.open("/dev/null", O_RDWR | O_CLOEXEC))
        for descriptor in [parentInput, parentOutput] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw CodexClientError.connectionClosed
            }
        }
        // Per-descriptor suppression: never change the application's SIGPIPE
        // handler just to write to a child that may have closed its input.
        guard fcntl(parentInput, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexClientError.connectionClosed
        }

        var actions: posix_spawn_file_actions_t?
        try Self.checkSpawn(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.checkSpawn(posix_spawn_file_actions_adddup2(&actions, pipeInput ? childInput : null, STDIN_FILENO))
        try Self.checkSpawn(
            posix_spawn_file_actions_adddup2(
                &actions, captureOutput ? childOutput : null, STDOUT_FILENO))
        try Self.checkSpawn(posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO))
        for descriptor in descriptors {
            try Self.checkSpawn(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        var attributes: posix_spawnattr_t?
        try Self.checkSpawn(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.checkSpawn(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t()
        sigemptyset(&mask)
        try Self.checkSpawn(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT] { sigaddset(&defaults, signal) }
        try Self.checkSpawn(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.checkSpawn(
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                        | POSIX_SPAWN_CLOEXEC_DEFAULT
                )))

        var argv = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }) else {
            throw CodexClientError.launchFailed("无法启动查询进程")
        }
        var environment =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }
        guard environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw CodexClientError.launchFailed("无法启动查询进程")
        }
        var child: pid_t = 0
        try Task.checkCancellation()
        let status = argv.withUnsafeMutableBufferPointer { pointers in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(
                    &child, executableURL.path, &actions, &attributes, pointers.baseAddress!,
                    environment.baseAddress!)
            }
        }
        try Self.checkSpawn(status)
        processID = child
        input = pipeInput ? parentInput : -1
        output = captureOutput ? parentOutput : -1
        descriptors.removeAll { $0 == input || $0 == output }
    }

    deinit { close() }

    private static func checkSpawn(_ status: Int32) throws {
        guard status == 0 else { throw CodexClientError.launchFailed("无法启动只读查询（错误码 \(status)）") }
    }

    private func checkDeadline() throws {
        try Task.checkCancellation()
        if let deadline, DispatchTime.now() >= deadline {
            throw CodexClientError.requestTimedOut
        }
    }

    private func waitForIO(_ descriptor: Int32, events: Int16) throws {
        while true {
            try checkDeadline()
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, 20)
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexClientError.connectionClosed
            }
            if result == 0 { continue }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                throw CodexClientError.connectionClosed
            }
            return  // read/write handles EOF, EPIPE and readiness races itself.
        }
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try write(data)
    }

    func write(_ data: Data) throws {
        guard input >= 0 else { throw CodexClientError.connectionClosed }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                try waitForIO(input, events: Int16(POLLOUT))
                let count = Darwin.write(
                    input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                throw CodexClientError.connectionClosed
            }
        }
    }

    func nextLine() throws -> Data? {
        guard output >= 0 else { throw CodexClientError.connectionClosed }
        while true {
            try checkDeadline()
            if let newline = buffer.firstIndex(of: 0x0A) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumLineBytes else {
                    throw CodexClientError.responseTooLarge
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }
            guard buffer.count <= maximumLineBytes else { throw CodexClientError.responseTooLarge }
            if reachedEOF {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            try waitForIO(output, events: Int16(POLLIN))
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(output, &chunk, chunk.count)
            if count > 0 {
                guard count <= maximumOutputBytes - receivedBytes else {
                    throw CodexClientError.responseTooLarge
                }
                receivedBytes += count
                buffer.append(contentsOf: chunk.prefix(count))
                continue
            }
            if count == 0 {
                reachedEOF = true
                continue
            }
            if errno == EINTR || errno == EAGAIN { continue }
            throw CodexClientError.connectionClosed
        }
    }

    /// Observe exit without reaping: keep the child PID reserved until every
    /// group signal is finished, so cleanup cannot signal a recycled PID/group.
    private func exitInformation() throws -> siginfo_t? {
        guard processID > 0 else { throw CodexClientError.connectionClosed }
        var info = siginfo_t()
        while waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            if errno == EINTR { continue }
            throw CodexClientError.connectionClosed
        }
        return info.si_pid == processID ? info : nil
    }

    private func waitForTermination() throws -> siginfo_t {
        while true {
            try checkDeadline()
            if let info = try exitInformation() { return info }
            usleep(10_000)
        }
    }

    func waitForExit() throws -> Bool {
        let info = try waitForTermination()
        return info.si_code == CLD_EXITED && info.si_status == 0
    }

    /// Matches Foundation Process.terminationStatus for normal exits/signals.
    func waitForExitStatus() throws -> Int32 {
        try waitForTermination().si_status
    }

    func close() {
        guard processID > 0 else { return }
        let child = processID
        processID = 0
        if input >= 0 {
            _ = Darwin.close(input)
            input = -1
        }
        if output >= 0 {
            _ = Darwin.close(output)
            output = -1
        }
        buffer.removeAll()
        // No other code waits for these children. If ownership was lost, never
        // signal a possibly recycled identifier.
        var info = siginfo_t()
        var status: Int32
        repeat {
            status = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
        } while status != 0 && errno == EINTR
        guard status == 0 else { return }
        _ = kill(-child, SIGTERM)
        let grace = DispatchTime.now() + .milliseconds(50)
        while info.si_pid != child, DispatchTime.now() < grace {
            usleep(5_000)
            _ = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
        }
        // The unreaped direct child reserves this process-group ID throughout.
        _ = kill(-child, SIGKILL)
        _ = kill(child, SIGKILL)
        let reapDeadline = DispatchTime.now() + .milliseconds(250)
        var exitStatus: Int32 = 0
        while true {
            let result = waitpid(child, &exitStatus, WNOHANG)
            if result == child || (result < 0 && errno != EINTR) { return }
            if DispatchTime.now() >= reapDeadline { break }
            usleep(5_000)
        }
        // An uninterruptible kernel operation must not hold the UI's worker
        // forever. Retain a reaper for this exact owned child, without further
        // signals or PID lookups, until the kernel makes its exit waitable.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
    }
}
