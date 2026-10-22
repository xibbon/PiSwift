import Foundation
import Testing
@testable import PiSwiftCodingAgent

#if !canImport(UIKit) && !os(Windows)
@Test(.timeLimit(.minutes(1)))
func shellPipeDrainsLargeOutputBeforeWait() throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "head -c 1048576 /dev/zero"]
    process.standardOutput = output
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let result = readShellProcessOutput(process, stdout: output)

    #expect(result.stdout == Data(repeating: 0, count: 1_048_576))
    #expect(result.stderr.isEmpty)
    #expect(process.terminationStatus == 0)
}

@Test(.timeLimit(.minutes(1)))
func shellPipeDrainsLargeOutputAndErrorTogether() throws {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "head -c 1048576 /dev/zero >&2; head -c 1048576 /dev/zero"]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let result = readShellProcessOutput(process, stdout: output, stderr: error)

    #expect(result.stdout == Data(repeating: 0, count: 1_048_576))
    #expect(result.stderr == Data(repeating: 0, count: 1_048_576))
    #expect(process.terminationStatus == 0)
}
#endif
