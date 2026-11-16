import Foundation
import Testing
@testable import PiSwiftAI

private func events(_ chunks: [Data]) async throws -> [ServerSentEvent] {
    let body = AsyncThrowingStream<Data, Error> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
    var result: [ServerSentEvent] = []
    for try await event in iterateSseEvents(body: body) { result.append(event) }
    return result
}

@Suite("SSE line buffer", .timeLimit(.minutes(1)))
struct SseLineBufferTests {
    @Test func longLineInSmallChunksIsParsedInLinearTime() async throws {
        // 8 MiB in 16 KiB chunks. A rescan from byte 0 for each chunk is
        // quadratic and takes far longer than the time limit.
        let payload = String(repeating: "A", count: 8 * 1024 * 1024)
        let bytes = Data("event: big\ndata: \(payload)\n\n".utf8)
        var chunks: [Data] = []
        var index = 0
        while index < bytes.count {
            chunks.append(bytes.subdata(in: index..<min(index + 16_384, bytes.count)))
            index += 16_384
        }
        let clock = ContinuousClock()
        let start = clock.now
        let parsed = try await events(chunks)
        #expect(clock.now - start < .seconds(20))
        #expect(parsed.count == 1)
        #expect(parsed.first?.event == "big")
        #expect(parsed.first?.data.utf8.count == payload.utf8.count)
    }

    @Test func crlfSplitAcrossChunksIsOneLineEnd() async throws {
        let parsed = try await events([Data("event: x\r".utf8), Data("\ndata: y\r\n\r\n".utf8)])
        #expect(parsed.count == 1)
        #expect(parsed.first?.event == "x")
        #expect(parsed.first?.data == "y")
    }

    @Test func lineEndingsAndTrailingDataAreHandled() async throws {
        let parsed = try await events([Data("data: a\rdata: b\n\ndata: c\r\n\r\n: comment\ndata: tail".utf8)])
        #expect(parsed.map(\.data) == ["a\nb", "c", "tail"])
    }

    @Test func trailingCarriageReturnEndsTheStream() async throws {
        let parsed = try await events([Data("data: a\r\r".utf8)])
        #expect(parsed.map(\.data) == ["a"])
    }
}
