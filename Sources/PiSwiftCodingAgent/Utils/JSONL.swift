import Foundation

/// Encode a value as a single JSON line (no pretty printing) terminated by `\n`.
public func serializeJsonLine<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard var line = String(data: data, encoding: .utf8) else {
        throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Failed to encode value as UTF-8"))
    }
    line += "\n"
    return line
}

/// Split data by newlines and return non-empty chunks as individual `Data` values.
public func parseJsonLines(_ data: Data) -> [Data] {
    let newline = UInt8(ascii: "\n")
    var result: [Data] = []
    var start = data.startIndex
    for i in data.indices {
        if data[i] == newline {
            if i > start {
                result.append(data[start..<i])
            }
            start = data.index(after: i)
        }
    }
    // Handle trailing content without a final newline
    if start < data.endIndex {
        result.append(data[start..<data.endIndex])
    }
    return result
}
