/// Check raw JSON without decoding it into Swift values. Foundation accepts some trailing
/// commas and cannot preserve lone UTF-16 surrogates that JavaScript's JSON.parse accepts.
func validateRuntimeJSONSyntax(_ json: String) throws {
    var scanner = RuntimeJSONScanner(bytes: Array(json.utf8))
    try scanner.validate()
}

private struct RuntimeJSONScanner {
    enum Container {
        case firstArrayValue, arrayValue, afterArrayValue
        case firstObjectKey, objectKey, objectColon, objectValue, afterObjectValue
    }

    var bytes: [UInt8]
    var offset = 0
    var containers: [Container] = []

    mutating func validate() throws {
        skipWhitespace()
        try value()
        while let container = containers.last {
            skipWhitespace()
            switch container {
            case .firstArrayValue where take(93):
                containers.removeLast()
            case .firstObjectKey where take(125):
                containers.removeLast()
            case .firstArrayValue, .arrayValue:
                containers[containers.count - 1] = .afterArrayValue
                try value()
            case .firstObjectKey, .objectKey:
                try string()
                containers[containers.count - 1] = .objectColon
            case .objectColon:
                guard take(58) else { throw CodemodeRuntimeProtocolError.invalidJSON }
                containers[containers.count - 1] = .objectValue
            case .objectValue:
                containers[containers.count - 1] = .afterObjectValue
                try value()
            case .afterArrayValue:
                if take(93) { containers.removeLast() }
                else if take(44) { containers[containers.count - 1] = .arrayValue }
                else { throw CodemodeRuntimeProtocolError.invalidJSON }
            case .afterObjectValue:
                if take(125) { containers.removeLast() }
                else if take(44) { containers[containers.count - 1] = .objectKey }
                else { throw CodemodeRuntimeProtocolError.invalidJSON }
            }
        }
        skipWhitespace()
        guard offset == bytes.count else { throw CodemodeRuntimeProtocolError.invalidJSON }
    }

    mutating func value() throws {
        skipWhitespace()
        guard offset < bytes.count else { throw CodemodeRuntimeProtocolError.invalidJSON }
        switch bytes[offset] {
        case 123:
            offset += 1
            containers.append(.firstObjectKey)
        case 91:
            offset += 1
            containers.append(.firstArrayValue)
        case 34:
            try string()
        case 116:
            try literal([116, 114, 117, 101])
        case 102:
            try literal([102, 97, 108, 115, 101])
        case 110:
            try literal([110, 117, 108, 108])
        case 45, 48...57:
            try number()
        default:
            throw CodemodeRuntimeProtocolError.invalidJSON
        }
    }

    mutating func string() throws {
        guard take(34) else { throw CodemodeRuntimeProtocolError.invalidJSON }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 { return }
            guard byte >= 32 else { throw CodemodeRuntimeProtocolError.invalidJSON }
            if byte == 92 {
                guard offset < bytes.count else { throw CodemodeRuntimeProtocolError.invalidJSON }
                let escape = bytes[offset]
                offset += 1
                switch escape {
                case 34, 47, 92, 98, 102, 110, 114, 116:
                    break
                case 117:
                    for _ in 0..<4 {
                        guard offset < bytes.count else { throw CodemodeRuntimeProtocolError.invalidJSON }
                        switch bytes[offset] {
                        case 48...57, 65...70, 97...102: offset += 1
                        default: throw CodemodeRuntimeProtocolError.invalidJSON
                        }
                    }
                default:
                    throw CodemodeRuntimeProtocolError.invalidJSON
                }
            }
        }
        throw CodemodeRuntimeProtocolError.invalidJSON
    }

    mutating func number() throws {
        _ = take(45)
        if !take(48) {
            guard offset < bytes.count, (49...57).contains(bytes[offset]) else {
                throw CodemodeRuntimeProtocolError.invalidJSON
            }
            digits()
        }
        if take(46) { try requiredDigits() }
        if take(101) || take(69) {
            if !take(43) { _ = take(45) }
            try requiredDigits()
        }
    }

    mutating func requiredDigits() throws {
        let start = offset
        digits()
        guard offset > start else { throw CodemodeRuntimeProtocolError.invalidJSON }
    }

    mutating func digits() {
        while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
    }

    mutating func literal(_ value: [UInt8]) throws {
        for byte in value {
            guard take(byte) else { throw CodemodeRuntimeProtocolError.invalidJSON }
        }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    mutating func skipWhitespace() {
        while offset < bytes.count {
            switch bytes[offset] {
            case 9, 10, 13, 32: offset += 1
            default: return
            }
        }
    }
}
