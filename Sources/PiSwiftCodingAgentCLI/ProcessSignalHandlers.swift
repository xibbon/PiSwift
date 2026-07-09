import Darwin
import Dispatch
import Foundation
import PiSwiftCodingAgent

func registerNonInteractiveSignalHandlers() -> [DispatchSourceSignal] {
    let signalQueue = DispatchQueue(label: "pi-coding-agent.non-interactive-signals")
    let signals: [(signal: Int32, exitCode: Int32)] = [
        (SIGTERM, 143),
        (SIGHUP, 129),
    ]

    return signals.map { entry in
        signal(entry.signal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: entry.signal, queue: signalQueue)
        source.setEventHandler {
            killTrackedDetachedChildren()
            restoreStdoutAfterMachineReadableOutput()
            Darwin.exit(entry.exitCode)
        }
        source.resume()
        return source
    }
}

func unregisterNonInteractiveSignalHandlers(_ sources: [DispatchSourceSignal]) {
    for source in sources {
        source.cancel()
    }
    signal(SIGTERM, SIG_DFL)
    signal(SIGHUP, SIG_DFL)
}
