import Darwin
import Foundation
import Synchronization
import Testing
@testable import PiSwiftCodingAgent

@MainActor
private func captureFD(_ fd: Int32, operation: () async -> Void) async -> String {
    fflush(fd == STDOUT_FILENO ? stdout : stderr)
    let pipeFDs = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
    defer { pipeFDs.deallocate() }
    guard pipe(pipeFDs) == 0 else { return "" }

    let savedFD = dup(fd)
    guard savedFD >= 0 else {
        close(pipeFDs[0])
        close(pipeFDs[1])
        return ""
    }

    guard dup2(pipeFDs[1], fd) >= 0 else {
        close(savedFD)
        close(pipeFDs[0])
        close(pipeFDs[1])
        return ""
    }

    // Drain the pipe while the operation runs. The descriptor is process-wide, so a
    // large listing or any other writer can fill the pipe and block (X1).
    let readFD = pipeFDs[0]
    let reader = CapturedPipeReader(readFD)

    await operation()
    fflush(fd == STDOUT_FILENO ? stdout : stderr)
    _ = dup2(savedFD, fd)
    close(savedFD)
    close(pipeFDs[1])

    let data = await reader.finish()
    close(readFD)
    return String(decoding: data, as: UTF8.self)
}

/// Reads a descriptor to EOF on a background queue.
private final class CapturedPipeReader: Sendable {
    private let data = Mutex(Data())
    private let done = DispatchGroup()

    nonisolated init(_ fd: Int32) {
        done.enter()
        DispatchQueue.global().async { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                data.withLock { $0.append(buffer, count: Int(count)) }
            }
            done.leave()
        }
    }

    nonisolated func finish() async -> Data {
        await withCheckedContinuation { continuation in
            done.notify(queue: .global()) { continuation.resume() }
        }
        return data.withLock { $0 }
    }
}

@MainActor
@Test(.timeLimit(.minutes(1))) func listModelsReportsModelsJsonParseErrorToStderr() async throws {
    await processOutputCaptureGate.acquire()
    defer { Task { await processOutputCaptureGate.release() } }
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-list-models-invalid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try "{ invalid json".write(
        to: tempDir.appendingPathComponent("models.json"),
        atomically: true,
        encoding: .utf8
    )

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    var stderrOutput = ""
    _ = await captureFD(STDOUT_FILENO) {
        stderrOutput = await captureFD(STDERR_FILENO) {
            await listModels(registry)
        }
    }

    #expect(stderrOutput.contains("Warning: models.json parse error"))
}

@MainActor
@Test(.timeLimit(.minutes(1))) func listModelsShowsModelsWithConfiguredHeadersOnly() async throws {
    await processOutputCaptureGate.acquire()
    defer { Task { await processOutputCaptureGate.release() } }
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-list-models-headers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let modelsJSON = """
    {
      "providers": {
        "header-provider": {
          "api": "openai-completions",
          "baseUrl": "https://example.invalid/v1",
          "headers": {
            "Authorization": "Bearer header-token"
          },
          "models": [
            { "id": "header-model" }
          ]
        }
      }
    }
    """
    try modelsJSON.write(
        to: tempDir.appendingPathComponent("models.json"),
        atomically: true,
        encoding: .utf8
    )

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    let available = await registry.getAvailable()
    #expect(available.contains { $0.provider == "header-provider" && $0.id == "header-model" })

    let stdoutOutput = await captureFD(STDOUT_FILENO) {
        await listModels(registry, "header-model")
    }
    #expect(stdoutOutput.contains("header-provider"))
    #expect(stdoutOutput.contains("header-model"))
}
