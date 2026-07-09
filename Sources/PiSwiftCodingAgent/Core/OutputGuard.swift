import Darwin
import Foundation
import PiSwiftAI

/// SAFETY: instances are immutable file descriptor snapshots; the optional global
/// snapshot is protected by `stdoutTakeoverState`.
private final class StdoutTakeoverState: @unchecked Sendable {
    let rawStdoutFD: Int32
    let originalStdoutFD: Int32

    init(rawStdoutFD: Int32, originalStdoutFD: Int32) {
        self.rawStdoutFD = rawStdoutFD
        self.originalStdoutFD = originalStdoutFD
    }
}

private let stdoutTakeoverState = LockedState<StdoutTakeoverState?>(nil)

public final class MachineReadableOutput: Sendable {
    private let state = LockedState<Void>(())
    private let fd: Int32

    fileprivate init(fd: Int32) {
        self.fd = fd
    }

    public func write(_ data: Data) {
        state.withLock { _ in
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < data.count {
                    let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    public func writeString(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        write(data)
    }

    public func writeJSONLine(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return
        }
        data.append(0x0A)
        write(data)
    }
}

public func takeOverStdoutForMachineReadableOutput() -> MachineReadableOutput {
    stdoutTakeoverState.withLock { state in
        if let state {
            return MachineReadableOutput(fd: state.rawStdoutFD)
        }

        let rawStdoutFD = dup(STDOUT_FILENO)
        let originalStdoutFD = dup(STDOUT_FILENO)
        guard rawStdoutFD >= 0, originalStdoutFD >= 0 else {
            if rawStdoutFD >= 0 { close(rawStdoutFD) }
            if originalStdoutFD >= 0 { close(originalStdoutFD) }
            return MachineReadableOutput(fd: STDOUT_FILENO)
        }

        _ = dup2(STDERR_FILENO, STDOUT_FILENO)
        let newState = StdoutTakeoverState(rawStdoutFD: rawStdoutFD, originalStdoutFD: originalStdoutFD)
        state = newState
        return MachineReadableOutput(fd: newState.rawStdoutFD)
    }
}

public func restoreStdoutAfterMachineReadableOutput() {
    let state = stdoutTakeoverState.withLock { state -> StdoutTakeoverState? in
        let current = state
        state = nil
        return current
    }
    guard let state else { return }
    _ = dup2(state.originalStdoutFD, STDOUT_FILENO)
    close(state.rawStdoutFD)
    close(state.originalStdoutFD)
}

public func isStdoutTakenOverForMachineReadableOutput() -> Bool {
    stdoutTakeoverState.withLock { $0 != nil }
}
