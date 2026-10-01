import Foundation

public func parseStreamingJSON(_ partialJson: String?) -> [String: AnyCodable] {
    // Complete objects only: a tool call cut off mid-stream must come back empty
    // rather than run with partial arguments.
    guard var json = partialJson,
          let end = json.withUTF8(topLevelObjectEnd),
          let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8.prefix(end))),
          let object = parsed as? [String: Any] else {
        return [:]
    }
    let text = String(decoding: json.utf8.prefix(end), as: UTF8.self)
    return toolArgumentsWithOrder(object.mapValues { AnyCodable($0) },
                                  argumentsJSON: parseToolArgumentsSource(text))
}

extension ToolCall {
    /// Parse complete streamed arguments and retain their object order.
    /// Keep the same complete-object prefix rule as parseStreamingJSON.
    public mutating func setArguments(from text: String) {
        arguments = parseStreamingJSON(text)
        var json = text
        argumentsJSON = json.withUTF8(topLevelObjectEnd).flatMap { end in
            parseToolArgumentsSource(String(decoding: json.utf8.prefix(end), as: UTF8.self))
        }
    }
}

/// Byte offset just past the brace that closes the top-level object, or nil while
/// it is still open. It takes one pass because callers re-parse the accumulated
/// text on every streamed chunk. The start isn't checked: a leading BOM or
/// whitespace holds no quotes or brackets, and text that doesn't start with an
/// object can't parse as one anyway.
private func topLevelObjectEnd(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
    var depth = 0
    var inString = false
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if inString {
            if byte == UInt8(ascii: "\\") {
                index += 1 // skip the escaped byte
            } else if byte == UInt8(ascii: "\"") {
                inString = false
            }
            continue
        }
        switch byte {
        case UInt8(ascii: "\""):
            inString = true
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth -= 1
            if depth == 0 {
                return index
            }
        default:
            break
        }
    }
    return nil
}
