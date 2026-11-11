import Dispatch
import Foundation
import Synchronization
import Testing
import PiSwiftChord

@Suite struct DeltaPendingBenchmarkTests {
    @Test func boundedInputsFoldOrThrowOnSecondaryThread() {
        let result = Mutex<(Bool, Bool, Bool, Bool, Bool)?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let queue = PendingOps()
            queue.push([.append(Array(repeating: .key("x"), count: maxPendingPathDepth + 1), "x")])
            let deep = queue.take() == .replace
            queue.push(Array(repeating: .append(["s"], "x"), count: maxPendingReceivedOps + 1))
            let many = queue.take() == .replace
            queue.push([.append(["s"], String(repeating: "x", count: maxPendingTextBytes + 1))])
            let large = queue.take() == .replace
            var appendRejected = false
            var appendDepthRejected = false
            do {
                let tracker = try Delta.track(["s": ""])
                try tracker.beginChange().state.appendText("s", String(repeating: "x", count: maxPendingTextBytes + 1))
            } catch TrackerError.appendTextLimit { appendRejected = true }
            catch { appendRejected = false }
            do {
                let tracker = try Delta.track(["s": ""])
                var draft = try tracker.beginChange().state
                for _ in 0..<maxPendingPathDepth {
                    try draft.set("child", ["s": ""])
                    guard let child = try draft.child("child") else { break }
                    draft = child
                }
                try draft.appendText("s", "x")
            } catch TrackerError.appendTextLimit { appendDepthRejected = true }
            catch { appendDepthRejected = false }
            result.withLock { $0 = (deep, many, large, appendRejected, appendDepthRejected) }
            done.signal()
        }
        done.wait()
        let bounded = result.withLock { $0 }
        #expect(bounded?.0 == true)
        #expect(bounded?.1 == true)
        #expect(bounded?.2 == true)
        #expect(bounded?.3 == true)
        #expect(bounded?.4 == true)
    }

    @Test func millionAppendsAndTenThousandDistinctKeysOnSecondaryThread() {
        guard ProcessInfo.processInfo.environment["CHORD_BENCH"] == "1" else { return }
        let result = Mutex<(Double, Double, Int, Int)?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let queue = PendingOps()
            let start = Date.timeIntervalSinceReferenceDate
            for _ in 0..<1_000_000 { queue.push([.append(["text"], "x")]) }
            let appendTime = Date.timeIntervalSinceReferenceDate - start
            let appendCount = queue.size
            _ = queue.take()
            let distinctStart = Date.timeIntervalSinceReferenceDate
            for index in 0..<10_000 { queue.push([.set(["map", .index(index)], .number(Double(index)))]) }
            let distinctTime = Date.timeIntervalSinceReferenceDate - distinctStart
            result.withLock { $0 = (appendTime, distinctTime, appendCount, queue.size) }
            done.signal()
        }
        done.wait()
        let measurement = result.withLock { $0 }
        #expect(measurement?.2 == 1)
        #expect(measurement?.3 == 10_000)
        if let measurement {
            print("CHORD_BENCH million_appends_seconds=\(measurement.0) distinct_10000_seconds=\(measurement.1)")
        }
    }

    @Test func oneMegabyteInFourByteTokensOnSecondaryThread() {
        guard ProcessInfo.processInfo.environment["CHORD_BENCH_STREAM"] == "1" else { return }
        let result = Mutex<(Double?, Double, [Delta.Op]?, [Delta.Op])?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let base: JSONValue = ["text": ""]
                var slowTime: Double?
                var slowOps: [Delta.Op]?
                if ProcessInfo.processInfo.environment["CHORD_BENCH_STREAM_FAST"] != "1" {
                    let slow = try Delta.track(base)
                    let slowChange = slow.beginChange()
                    let slowDraft = try slowChange.state
                    let start = Date.timeIntervalSinceReferenceDate
                    for _ in 0..<262_144 {
                        let current = try slowDraft.get("text")?.stringValue ?? ""
                        try slowDraft.set("text", .string(current + "abcd"))
                    }
                    slowOps = try slowChange.prepare().ops
                    slowTime = Date.timeIntervalSinceReferenceDate - start
                }
                let fast = try Delta.track(base)
                let fastChange = fast.beginChange()
                let fastDraft = try fastChange.state
                let fastStart = Date.timeIntervalSinceReferenceDate
                for _ in 0..<262_144 { try fastDraft.appendText("text", "abcd") }
                let fastPrepared = try fastChange.prepare()
                let fastTime = Date.timeIntervalSinceReferenceDate - fastStart
                result.withLock { $0 = (slowTime, fastTime, slowOps, fastPrepared.ops) }
            } catch { print("CHORD_BENCH_STREAM error=\(error)") }
            done.signal()
        }
        done.wait()
        guard let measurement = result.withLock({ $0 }) else { Issue.record("Stream benchmark failed"); return }
        if let slowOps = measurement.2 { #expect(slowOps == measurement.3) }
        #expect(measurement.3.count == 1)
        print("CHORD_BENCH_STREAM assigned_seconds=\(measurement.0.map { String($0) } ?? ">300") append_text_seconds=\(measurement.1) op_count=\(measurement.3.count) bytes=1048576")
    }
}
