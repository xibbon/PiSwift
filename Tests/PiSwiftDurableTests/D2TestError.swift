import Testing
import PiSwiftDurable

/// An error for test callbacks, cancellation, and storage failures.
struct D2TestError: Error, Sendable, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func expectD2SessionFailure<Value>(_ cause: D2TestError, _ operation: () async throws -> Value) async {
    do { _ = try await operation(); Issue.record("Failed Session accepted a call") }
    catch {
        let failed = error as? SessionFailed
        #expect(failed != nil)
        #expect(failed?.cause as? D2TestError == cause)
    }
}

func expectD2FailedEnd(_ harness: Harness, _ cause: D2TestError) async {
    guard case .failed(let error) = await harness.closed else {
        Issue.record("Session did not end as failed")
        return
    }
    #expect(error as? D2TestError == cause)
}
