#if os(macOS)
import Darwin
import Dispatch
import Foundation
import PiSwiftChord
import Synchronization

/// Internal hooks count kernel event waits for each command. The callback runs outside locks.
internal struct LocalShellHooks: Sendable {
    var loopWoke: @Sendable () -> Void = {}
}

/// Formats a timeout in seconds. Whole seconds omit the fraction; other values use Double's shortest text.
internal func shellTimeoutNumber(_ timeout: Duration) -> String {
    let parts = timeout.components
    if parts.attoseconds == 0 { return String(parts.seconds) }
    let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    let text = String(seconds)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
}

/// POSIX spill operations. Tests can replace a writer without changing process execution.
internal struct LocalShellIO: Sendable {
    var spillHighWaterMark = 1024 * 1024
    var createSpill: @Sendable () throws -> (fd: Int32, path: String) = {
        var template = Array((FileManager.default.temporaryDirectory.path + "/tmp-XXXXXX").utf8CString)
        let directory = try template.withUnsafeMutableBufferPointer { buffer in
            guard let pointer = mkdtemp(buffer.baseAddress!) else { throw LocalShell.posixError(.unknown) }
            return String(cString: pointer)
        }
        let path = directory + "/pi-output-" + UUID().uuidString.lowercased() + ".log"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalShell.posixError(.unknown) }
        return (fd, path)
    }
    var writeSpill: @Sendable (Int32, [UInt8]) throws -> Void = { fd, bytes in
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LocalShell.posixError(.unknown, number: count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }
    var closeSpill: @Sendable (Int32) throws -> Void = { fd in
        guard Darwin.close(fd) == 0 else { throw LocalShell.posixError(.unknown) }
    }
}

/// A process token prevents late abort and timer callbacks from killing a completed command.
private final class LocalShellProcess: Sendable {
    private struct State: Sendable {
        var pid: pid_t?
        var reaped = false
        var timedOut = false
    }
    private let state: Mutex<State>
    init(pid: pid_t) { state = Mutex(State(pid: pid)) }
    func kill(timeout: Bool = false) {
        state.withLock { value in
            guard let pid = value.pid else { return }
            if timeout { value.timedOut = true }
            if Darwin.kill(-pid, SIGKILL) != 0, !value.reaped { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
    func reaped() { state.withLock { $0.reaped = true } }
    @discardableResult
    func finish() -> Bool { state.withLock { value in value.pid = nil; return value.timedOut } }
}

/// Serial writes preserve raw chunk order. At the high-water mark, pipe reads stop until writes drain.
private final class LocalShellSpill: Sendable {
    private struct State: Sendable {
        var pendingBytes = 0
        var backpressured = false
        var error: ExecutionError?
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "PiSwiftDurable.shell.spill")
    private let io: LocalShellIO
    private let process: LocalShellProcess
    private let events: LocalShellEvents
    private let fd: Int32
    let path: String
    init(io: LocalShellIO, process: LocalShellProcess, events: LocalShellEvents) throws {
        self.io = io; self.process = process; self.events = events
        let file = try io.createSpill()
        fd = file.fd; path = file.path
    }
    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        state.withLock { value in
            value.pendingBytes += bytes.count
            if value.pendingBytes >= max(1, io.spillHighWaterMark) { value.backpressured = true }
        }
        queue.async { [self] in
            if error == nil {
                do { try io.writeSpill(fd, bytes) }
                catch { fail(error) }
            }
            let drained = state.withLock { value in
                value.pendingBytes -= bytes.count
                let drained = value.backpressured && value.pendingBytes == 0
                if drained { value.backpressured = false }
                return drained
            }
            if drained { events.triggerSpill() }
        }
    }
    private func fail(_ cause: any Error) {
        state.withLock { value in
            if value.error == nil {
                value.error = ExecutionError(.unknown, message: "Failed to preserve complete shell output: \(cause)", cause: cause)
            }
        }
        process.kill()
        events.triggerSpill()
    }
    var error: ExecutionError? { state.withLock { $0.error } }
    var backpressured: Bool { state.withLock { $0.error == nil && $0.backpressured } }
    func finish() {
        queue.sync {
            do { try io.closeSpill(fd) }
            catch { fail(error) }
        }
    }
}

/// macOS shell execution. Spill files are not deleted, as in upstream NodeExecutionEnv.
internal final class LocalShell: Sendable {
    private let shellPath: String?
    private let shellEnv: [String: String]?
    private let io: LocalShellIO
    private let hooks: LocalShellHooks
    private let processes = Mutex<[UUID: LocalShellProcess]>([:])
    init(shellPath: String? = nil, shellEnv: [String: String]? = nil, io: LocalShellIO = .init(), hooks: LocalShellHooks = .init()) {
        self.shellPath = shellPath; self.shellEnv = shellEnv; self.io = io; self.hooks = hooks
    }
    func cleanup() {
        processes.withLock { value in
            for process in value.values { process.kill() }
            value.removeAll()
        }
    }
    static func posixError(_ code: ExecutionErrorCode, number: Int32 = errno) -> ExecutionError {
        ExecutionError(code, message: String(cString: strerror(number)))
    }
    func exec(_ command: ShellCommand, cwd: String, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> {
        if context.abortSignal?.aborted == true { return .failure(.init(.aborted, message: "aborted")) }
        if let timeout = options?.timeout {
            if timeout <= .zero { return .failure(.init(.timeout, message: "Invalid timeout: must be a finite number of seconds")) }
            if timeout > .milliseconds(2_147_483_647) {
                return .failure(.init(.timeout, message: "Invalid timeout: maximum is 2147483.647 seconds"))
            }
        }
        // Blocking POSIX I/O uses a private dispatch worker, not a Swift cooperative executor.
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "PiSwiftDurable.shell.exec").async { [self] in
                continuation.resume(returning: run(command, cwd: cwd, options: options, context: context))
            }
        }
    }
    private func shellProgram() throws -> String {
        try Self.selectShell(customShellPath: shellPath, pathExists: { access($0, F_OK) == 0 }, bashOnPath: {
            findProgram("bash", cwd: FileManager.default.currentDirectoryPath,
                        path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        })
    }
    /// The selection seam makes fallback cases testable on a host that always has /bin/bash.
    internal static func selectShell(customShellPath: String?, pathExists: (String) -> Bool, bashOnPath: () -> String?) throws -> String {
        if let customShellPath, !customShellPath.isEmpty {
            guard pathExists(customShellPath) else {
                throw ExecutionError(.shellUnavailable, message: "Custom shell path not found: \(customShellPath)")
            }
            return customShellPath
        }
        if pathExists("/bin/bash") { return "/bin/bash" }
        if let bash = bashOnPath() { return bash }
        return "sh"
    }
    private func findProgram(_ program: String, cwd: String, path: String) -> String? {
        for part in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = part.isEmpty ? cwd : (part.hasPrefix("/") ? String(part) : cwd + "/" + part)
            let candidate = directory + "/" + program
            var info = stat()
            if access(candidate, X_OK) == 0, stat(candidate, &info) == 0,
               info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) { return candidate }
        }
        return nil
    }
    private func run(_ command: ShellCommand, cwd base: String, options: ShellExecOptions?, context: ChordContext) -> Result<ShellExecResult, ExecutionError> {
        do {
            let argv: [String]
            switch command {
            case .shell(let text): argv = [try shellProgram(), "-c", text]
            case .argv(let values):
                guard !values.isEmpty else { throw ExecutionError(.spawnError, message: "Empty argv: no program to run") }
                argv = values
            }
            let cwd = options?.cwd.flatMap { $0.isEmpty ? nil : LocalFS.resolve($0, cwd: base) } ?? base
            guard !cwd.utf8.contains(0), access(cwd, F_OK) == 0 else {
                throw ExecutionError(.spawnError, message: "Working directory does not exist: \(cwd)\nCannot execute bash commands.")
            }
            var environment = options?.inheritEnv == false ? [:] : ProcessInfo.processInfo.environment
            if options?.inheritEnv != false { environment.merge(shellEnv ?? [:]) { _, new in new } }
            environment.merge(options?.env ?? [:]) { _, new in new }
            guard argv.allSatisfy({ !$0.utf8.contains(0) }),
                  environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
                throw ExecutionError(.spawnError, message: "Command or environment contains an invalid string")
            }
            let program: String
            // Program paths are literal. Shell expansion applies only to a shell expression.
            let absoluteCwd = cwd.hasPrefix("/") ? cwd : FileManager.default.currentDirectoryPath + "/" + cwd
            if argv[0].contains("/") { program = argv[0].hasPrefix("/") ? argv[0] : absoluteCwd + "/" + argv[0] }
            else {
                guard let found = findProgram(argv[0], cwd: absoluteCwd, path: environment["PATH"] ?? "/usr/bin:/bin") else {
                    throw Self.posixError(.spawnError, number: ENOENT)
                }
                program = found
            }
            let spawned = try processes.withLock { value -> (UUID, LocalShellProcess, Int32, Int32, pid_t) in
                let child = try spawn(program: program, argv: argv, environment: environment, cwd: cwd)
                let identity = UUID(), process = LocalShellProcess(pid: child.pid)
                value[identity] = process
                return (identity, process, child.stdout, child.stderr, child.pid)
            }
            return collect(spawned, options: options, context: context)
        } catch let error as ExecutionError { return .failure(error) }
        catch { return .failure(.init(.spawnError, message: String(describing: error), cause: error)) }
    }
    private func spawn(program: String, argv: [String], environment: [String: String], cwd: String) throws -> (pid: pid_t, stdout: Int32, stderr: Int32) {
        func pipePair() throws -> [Int32] {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw Self.posixError(.spawnError) }
            // Raise descriptors above stdio, even when the host has closed one of its standard descriptors.
            for index in descriptors.indices {
                let original = descriptors[index]
                let raised = fcntl(original, F_DUPFD_CLOEXEC, 3)
                guard raised >= 0 else {
                    let error = Self.posixError(.spawnError)
                    for fd in descriptors { _ = Darwin.close(fd) }
                    throw error
                }
                _ = Darwin.close(original); descriptors[index] = raised
            }
            return descriptors
        }
        let stdout = try pipePair()
        defer { _ = Darwin.close(stdout[1]) }
        let stderr: [Int32]
        do { stderr = try pipePair() }
        catch { _ = Darwin.close(stdout[0]); throw error }
        defer { _ = Darwin.close(stderr[1]) }
        var success = false
        defer { if !success { _ = Darwin.close(stdout[0]); _ = Darwin.close(stderr[0]) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw Self.posixError(.spawnError, number: code) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaultSignals = sigset_t(), signalMask = sigset_t()
        sigfillset(&defaultSignals); sigdelset(&defaultSignals, SIGKILL); sigdelset(&defaultSignals, SIGSTOP)
        sigemptyset(&signalMask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
        try check(posix_spawn_file_actions_addchdir_np(&actions, cwd))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO))
        for fd in stdout + stderr { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        let arguments = argv.map { strdup($0)! }, variables = environment.map { strdup("\($0.key)=\($0.value)")! }
        defer { for pointer in arguments + variables { free(pointer) } }
        var argumentPointers = arguments.map(Optional.some) + [nil]
        var variablePointers = variables.map(Optional.some) + [nil]
        var pid: pid_t = 0
        try argumentPointers.withUnsafeMutableBufferPointer { args in
            try variablePointers.withUnsafeMutableBufferPointer { env in
                try check(posix_spawn(&pid, program, &actions, &attributes, args.baseAddress!, env.baseAddress!))
            }
        }
        for fd in [stdout[0], stderr[0]] {
            if fcntl(fd, F_SETFL, O_NONBLOCK) < 0 {
                let error = Self.posixError(.spawnError)
                _ = Darwin.kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw error
            }
        }
        success = true
        return (pid, stdout[0], stderr[0])
    }
    private func collect(_ child: (UUID, LocalShellProcess, Int32, Int32, pid_t), options: ShellExecOptions?, context: ChordContext) -> Result<ShellExecResult, ExecutionError> {
        let (identity, process, stdout, stderr, pid) = child
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline: UInt64? = options?.timeout.map { timeout in
            let parts = timeout.components
            let nanoseconds = parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
            return startedAt + UInt64(max(1, nanoseconds))
        }
        defer {
            process.finish()
            processes.withLock { _ = $0.removeValue(forKey: identity) }
            _ = Darwin.close(stdout); _ = Darwin.close(stderr)
        }
        var stdoutDecoder = StreamDecoder(), stderrDecoder = StreamDecoder()
        var stdoutEnded = false, stderrEnded = false
        var status: Int32 = 0, exited = false
        var idleSince: UInt64 = 0
        var callbackError: ExecutionError?, spillError: ExecutionError?
        var spill: LocalShellSpill?
        func reap(blocking: Bool = false) {
            guard !exited else { return }
            var waited: pid_t
            repeat { waited = waitpid(pid, &status, blocking ? 0 : WNOHANG) }
            while waited < 0 && errno == EINTR
            if waited == pid {
                exited = true; process.reaped(); idleSince = DispatchTime.now().uptimeNanoseconds
            } else if waited < 0 && errno != EINTR {
                spillError = Self.posixError(.unknown); process.kill()
                // The host can reap children through SIGCHLD. There is no remaining child to wait for.
                exited = true; process.reaped(); idleSince = DispatchTime.now().uptimeNanoseconds
            }
        }
        let events: LocalShellEvents
        do { events = try LocalShellEvents(pid: pid, stdout: stdout, stderr: stderr) }
        catch {
            process.kill(); reap(blocking: true)
            return .failure(.init(.unknown, message: String(describing: error), cause: error))
        }
        defer { events.close() }
        // A failed NOTE_EXIT registration means the child exited before the filter was installed.
        if events.childExitedBeforeRegistration { reap() }
        let registration = context.abortSignal?.addAbortListener { _ in process.kill() }
        defer { if let registration { context.abortSignal?.removeAbortListener(registration) } }
        if context.abortSignal?.aborted == true { process.kill() }
        var timer: DispatchSourceTimer?
        if let deadline {
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
            source.setEventHandler { process.kill(timeout: true) }
            source.resume(); timer = source
        }
        defer { timer?.cancel() }
        var prefix: [[UInt8]] = [], seenBytes = 0, seenNewlines = 0
        func emit(_ text: String, stream: ShellOutputStream) {
            guard !text.isEmpty, callbackError == nil, let callback = options?.onOutput else { return }
            do { try callback(text, context, .init(stream: stream)) }
            catch {
                callbackError = .init(.callbackError, message: String(describing: error), cause: error)
                process.kill()
            }
        }
        func preserve(_ bytes: [UInt8]) {
            guard let thresholds = options?.spill, spillError == nil else { return }
            if let spill { spill.append(bytes); return }
            seenBytes += bytes.count
            seenNewlines += bytes.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            let lines = seenNewlines + (bytes.last == 10 ? 0 : 1)
            if seenBytes <= thresholds.afterBytes && lines <= thresholds.afterLines { prefix.append(bytes); return }
            do {
                let writer = try LocalShellSpill(io: io, process: process, events: events)
                spill = writer
                for chunk in prefix { writer.append(chunk) }
                prefix.removeAll(); writer.append(bytes)
            } catch {
                spillError = .init(.unknown, message: "Failed to preserve complete shell output: \(error)", cause: error)
                process.kill()
            }
        }
        func readChunk(_ fd: Int32, ended: inout Bool, decoder: inout StreamDecoder, stream: ShellOutputStream) -> Bool {
            guard !ended else { return false }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count == 0 { ended = true; return false }
            if count < 0 {
                if errno != EAGAIN && errno != EINTR {
                    ended = true
                    spillError = Self.posixError(.unknown); process.kill()
                }
                return false
            }
            let bytes = Array(buffer.prefix(count))
            emit(decoder.decode(bytes), stream: stream); preserve(bytes)
            if exited { idleSince = DispatchTime.now().uptimeNanoseconds }
            return true
        }
        var stdoutRegistered = true, stderrRegistered = true, readFiltersDisabled = false
        var wasBackpressured = false, deadlineReached = false
        while true {
            // Timer delivery can wait behind other dispatch work. The reader also enforces the same deadline.
            if !deadlineReached, let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                deadlineReached = true; process.kill(timeout: true)
            }
            let backpressured = spill?.backpressured == true
            var readData = false
            if !backpressured {
                readData = readChunk(stdout, ended: &stdoutEnded, decoder: &stdoutDecoder, stream: .stdout)
                if spill?.backpressured != true {
                    readData = readChunk(stderr, ended: &stderrEnded, decoder: &stderrDecoder, stream: .stderr) || readData
                }
            }
            reap()
            let paused = spill?.backpressured == true
            do {
                if stdoutEnded && stdoutRegistered { try events.setRead(stdout, flags: EV_DELETE); stdoutRegistered = false }
                if stderrEnded && stderrRegistered { try events.setRead(stderr, flags: EV_DELETE); stderrRegistered = false }
                if paused != readFiltersDisabled {
                    let flags = paused ? EV_DISABLE : EV_ENABLE
                    if stdoutRegistered { try events.setRead(stdout, flags: flags) }
                    if stderrRegistered { try events.setRead(stderr, flags: flags) }
                    readFiltersDisabled = paused
                }
            } catch {
                spillError = .init(.unknown, message: String(describing: error), cause: error)
                process.kill(); reap(blocking: true); break
            }
            if exited {
                if stdoutEnded && stderrEnded { break }
                let now = DispatchTime.now().uptimeNanoseconds
                // The full idle grace starts again when a paused spill drains.
                if paused || wasBackpressured { idleSince = now }
                else if now - idleSince >= 100_000_000 { break }
            }
            wasBackpressured = paused
            if !readData {
                var nextDeadline = deadlineReached ? nil : deadline
                if exited && !paused {
                    let graceDeadline = idleSince + 100_000_000
                    nextDeadline = nextDeadline.map { min($0, graceDeadline) } ?? graceDeadline
                }
                do {
                    // kevent blocks this command's private dispatch worker, never a cooperative Swift executor.
                    try events.wait(until: nextDeadline, onWake: hooks.loopWoke)
                    reap()
                } catch {
                    spillError = .init(.unknown, message: String(describing: error), cause: error)
                    process.kill(); reap(blocking: true); break
                }
            }
        }
        spill?.finish()
        emit(stdoutDecoder.decode(), stream: .stdout); emit(stderrDecoder.decode(), stream: .stderr)
        timer?.cancel()
        let timedOut = process.finish()
        if let callbackError { return .failure(callbackError) }
        if timedOut {
            return .failure(.init(.timeout, message: "timeout:\(shellTimeoutNumber(options!.timeout!))", spillPath: spill?.path))
        }
        if context.abortSignal?.aborted == true { return .failure(.init(.aborted, message: "aborted", spillPath: spill?.path)) }
        if let error = spillError ?? spill?.error { return .failure(error) }
        let signal = status & 0x7f
        let code = signal == 0 ? Int((status >> 8) & 0xff) : 128 + Int(signal)
        return .success(.init(exitCode: code, spillPath: spill?.path))
    }
}
#endif
