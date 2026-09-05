import Foundation

private let uuidV7State = LockedState(UUIDV7Generator())

/// Generate an ordered UUIDv7. A supplied timestamp is preserved for follower IDs.
public func uuidv7(timestampMs: Int64? = nil) throws -> String {
    try uuidV7State.withLock { generator in
        try generator.generate(timestampMs: timestampMs, now: Int64(Date().timeIntervalSince1970 * 1000))
    }
}

struct UUIDV7Generator: Sendable {
    var lastOrdinaryTimestamp: Int64 = -1
    var sequence: UInt64?

    mutating func generate(timestampMs: Int64? = nil, now: Int64, randomBytes: [UInt8]? = nil) throws -> String {
        let requested = timestampMs ?? now
        guard requested >= 0, requested <= 0xffffffffffff else { throw StreamError.invalidUUIDTimestamp }
        let timestamp = timestampMs == nil ? max(requested, lastOrdinaryTimestamp) : requested
        if timestampMs == nil { lastOrdinaryTimestamp = timestamp }
        var bytes = randomBytes ?? (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        if let previous = sequence {
            guard previous < (1 << 41) - 1 else { throw StreamError.uuidSequenceExhausted }
            sequence = previous + 1
        } else {
            sequence = bytes[1...5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let sequence = sequence!
        for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: timestamp >> ((5 - index) * 8)) }
        bytes[6] = 0x70 | UInt8((sequence >> 37) & 0x0f)
        bytes[7] = UInt8((sequence >> 29) & 0xff)
        bytes[8] = 0x80 | UInt8((sequence >> 23) & 0x3f)
        bytes[9] = UInt8((sequence >> 15) & 0xff)
        bytes[10] = UInt8((sequence >> 7) & 0xff)
        bytes[11] = UInt8((sequence & 0x7f) << 1) | (bytes[11] & 1)
        let hex = bytes.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }
}
