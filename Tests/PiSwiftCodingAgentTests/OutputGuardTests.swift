import Darwin
import Foundation
import Testing
import PiSwiftCodingAgent

@Test func machineReadableOutputRedirectsRegularStdoutToStderr() async throws {
    await processOutputCaptureGate.acquire()
    defer { Task { await processOutputCaptureGate.release() } }
    let savedStdout = dup(STDOUT_FILENO)
    let savedStderr = dup(STDERR_FILENO)
    #expect(savedStdout >= 0)
    #expect(savedStderr >= 0)

    var rawPipe = [Int32](repeating: 0, count: 2)
    var stderrPipe = [Int32](repeating: 0, count: 2)
    #expect(pipe(&rawPipe) == 0)
    #expect(pipe(&stderrPipe) == 0)

    var restored = false
    func restoreDescriptors() {
        guard !restored else { return }
        restored = true
        restoreStdoutAfterMachineReadableOutput()
        if savedStdout >= 0 {
            _ = dup2(savedStdout, STDOUT_FILENO)
            close(savedStdout)
        }
        if savedStderr >= 0 {
            _ = dup2(savedStderr, STDERR_FILENO)
            close(savedStderr)
        }
        close(rawPipe[1])
        close(stderrPipe[1])
    }
    defer {
        restoreDescriptors()
        close(rawPipe[0])
        close(stderrPipe[0])
    }

    #expect(dup2(rawPipe[1], STDOUT_FILENO) >= 0)
    #expect(dup2(stderrPipe[1], STDERR_FILENO) >= 0)

    let output = takeOverStdoutForMachineReadableOutput()
    fputs("diagnostic\n", stdout)
    fflush(stdout)
    output.writeString("protocol\n")

    restoreDescriptors()

    let rawData = FileHandle(fileDescriptor: rawPipe[0], closeOnDealloc: false).readDataToEndOfFile()
    let stderrData = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: false).readDataToEndOfFile()

    #expect(String(data: rawData, encoding: .utf8) == "protocol\n")
    #expect(String(data: stderrData, encoding: .utf8)?.contains("diagnostic\n") == true)
}
