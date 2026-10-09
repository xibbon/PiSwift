import CryptoKit
import Darwin
import Foundation
@testable import PiSwiftCodingAgentDurable
import Testing

private struct SessionTestDirectories {
    let base: URL
    let cwd: URL
    let agent: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("session-tests-" + UUID().uuidString)
        cwd = base.appendingPathComponent("cwd")
        agent = base.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func select(continueSession: Bool = false) async throws -> SessionLocation {
        try await selectSession(cwd.path, continueSession: continueSession, agentDirectory: agent.path)
    }

    func realCwd() throws -> String {
        guard let pointer = realpath(cwd.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

@Suite struct SessionTests {
    @Test func newSessionPathAndCreated() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let location = try await paths.select()
        defer { location.release() }
        let real = try paths.realCwd()
        let hash = SHA256.hash(data: Data(real.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(location.cwd == real)
        #expect(location.created)
        #expect(location.id.range(of: #"^\d{13}-[0-9a-f-]{36}$"#, options: .regularExpression) != nil)
        #expect(UUID(uuidString: String(location.id.suffix(36))) != nil)
        let parent = URL(fileURLWithPath: location.directory).deletingLastPathComponent()
        #expect(parent.lastPathComponent == String(hash.prefix(24)))
        #expect(parent.deletingLastPathComponent().lastPathComponent == "durable-sessions-swift")
        #expect(parent.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "experimental")
        #expect(parent.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
            == paths.agent.resolvingSymlinksInPath().path)
        #expect(location.database == location.directory + "/session.sqlite")
        #expect(FileManager.default.fileExists(atPath: location.directory))
        #expect(!FileManager.default.fileExists(atPath: location.database))
        #expect(FileManager.default.fileExists(atPath: location.directory + "/session.lock"))
    }

    @Test func continuePicksNewestMatchingDirectory() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let initial = try await paths.select()
        let root = URL(fileURLWithPath: initial.directory).deletingLastPathComponent()
        initial.release()
        let older = "0000000000001-00000000-0000-0000-0000-000000000000"
        let newest = "9999999999998-ffffffff-ffff-ffff-ffff-ffffffffffff"
        for name in [older, newest, "9999999999999-invalid", "9999999999999-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        // A matching file and a matching symlink are not directories in upstream's readdir.
        try Data().write(to: root.appendingPathComponent("9999999999999-eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("9999999999999-ffffffff-ffff-ffff-ffff-ffffffffffff"),
            withDestinationURL: root.appendingPathComponent(newest)
        )
        let continued = try await paths.select(continueSession: true)
        defer { continued.release() }
        #expect(continued.id == newest)
        #expect(!continued.created)
    }

    @Test func noSessionHasUpstreamText() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        do {
            let location = try await paths.select(continueSession: true)
            location.release()
            Issue.record("Expected no-session error")
        } catch let error as SessionLocationError {
            #expect(error.errorDescription == "No durable session exists for \(try paths.realCwd())")
            guard case .noSession = error else { Issue.record("Wrong session error"); return }
        }
    }

    @Test func symlinkAndRelativeCwdUseRealPath() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let initial = try await paths.select()
        let directory = initial.directory
        initial.release()
        let link = paths.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.cwd)
        let linked = try await selectSession(link.path, continueSession: true, agentDirectory: paths.agent.path)
        #expect(linked.cwd == (try paths.realCwd()))
        #expect(linked.directory == directory)
        linked.release()
        let dotted = try await selectSession(paths.base.path + "/absent/../cwd", continueSession: true, agentDirectory: paths.agent.path)
        #expect(dotted.directory == directory)
        dotted.release()
        let nested = paths.cwd.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedLink = paths.base.appendingPathComponent("nested-link")
        try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: nested)
        let lexicalParent = try await selectSession(nestedLink.path + "/../cwd", continueSession: true, agentDirectory: paths.agent.path)
        #expect(lexicalParent.directory == directory)
        lexicalParent.release()
        // Use a relative path without changing the process working directory.
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).pathComponents
        let target = paths.cwd.pathComponents
        let shared = zip(current, target).prefix { $0 == $1 }.count
        let relative = Array(repeating: "..", count: current.count - shared) + target.dropFirst(shared)
        let selected = try await selectSession(relative.joined(separator: "/"), continueSession: true, agentDirectory: paths.agent.path)
        defer { selected.release() }
        #expect(selected.directory == directory)
    }

    @Test func secondDescriptorFailsAfterShortRetry() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let first = try await paths.select()
        defer { first.release() }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let second = try await paths.select(continueSession: true)
            second.release()
            Issue.record("Expected lock conflict")
        } catch let error as SessionLocationError {
            #expect(error.errorDescription == "Session is already open in another process: \(first.directory)")
            guard case .alreadyOpen(_, let cause) = error else { Issue.record("Wrong session error"); return }
            #expect(cause.code == .EWOULDBLOCK)
        }
        #expect(start.duration(to: clock.now) >= .milliseconds(1_800))
        #expect(start.duration(to: clock.now) < .seconds(6))
    }

    @Test func releaseTwiceThenReopen() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let first = try await paths.select()
        first.release()
        first.release()
        let reopened = try await paths.select(continueSession: true)
        defer { reopened.release() }
        #expect(reopened.directory == first.directory)
    }

    @Test func droppedLocationReleasesLock() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        var location: SessionLocation? = try await paths.select()
        let directory = try #require(location?.directory)
        location = nil
        let reopened = try await paths.select(continueSession: true)
        defer { reopened.release() }
        #expect(reopened.directory == directory)
    }

    @Test func descriptorHasCloseOnExec() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let location = try await paths.select()
        defer { location.release() }
        #expect(location.lockHasCloseOnExec)
    }

    @Test func releaseDuringRetrySucceeds() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let first = try await paths.select()
        defer { first.release() }
        let release = Task {
            try await Task.sleep(for: .milliseconds(200))
            first.release()
        }
        defer { release.cancel() }
        let second = try await paths.select(continueSession: true)
        defer { second.release() }
        try await release.value
        #expect(second.directory == first.directory)
    }

    @Test func concurrentReleaseIsSafe() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let first = try await paths.select()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { first.release() } }
        }
        let second = try await paths.select(continueSession: true)
        defer { second.release() }
        #expect(second.directory == first.directory)
    }

    @Test func cancellationDuringRetryClosesDescriptor() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let first = try await paths.select()
        defer { first.release() }
        let pending = Task { try await paths.select(continueSession: true) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        do {
            let unexpected = try await pending.value
            unexpected.release()
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        first.release()
        let second = try await paths.select(continueSession: true)
        defer { second.release() }
        #expect(second.directory == first.directory)
    }

    #if os(macOS)
    @Test func killedChildReleasesKernelLock() async throws {
        let paths = try SessionTestDirectories()
        defer { paths.remove() }
        let initial = try await paths.select()
        let directory = initial.directory
        initial.release()
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "open(my $f, '+>>', $ARGV[0]) or die $!; flock($f, 2) or die $!; $|=1; print qq(ready\\n); sleep 60;", directory + "/session.lock"]
        child.standardOutput = output
        try child.run()
        defer {
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            try? output.fileHandleForReading.close()
        }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        #expect(ready == Data("ready\n".utf8))
        do {
            let unexpected = try await paths.select(continueSession: true)
            unexpected.release()
            Issue.record("Expected child lock conflict")
        } catch let error as SessionLocationError {
            #expect(error.errorDescription == "Session is already open in another process: \(directory)")
        }
        #expect(kill(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        let reopened = try await paths.select(continueSession: true)
        defer { reopened.release() }
        #expect(reopened.directory == directory)
    }
    #endif
}
