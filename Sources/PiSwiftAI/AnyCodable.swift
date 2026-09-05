import Foundation
import CoreFoundation

public struct AnyCodable: Codable, Sendable, Equatable {
    private let storage: Storage

    public var value: Any {
        storage.jsonValue
    }

    public init(_ value: Any) {
        self.storage = Storage(value)
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            storage = .null
        } else if let intVal = try? container.decode(Int.self) {
            storage = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            storage = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            storage = .string(stringVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            storage = .bool(boolVal)
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            storage = .array(arrayVal.map { $0.storage })
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            storage = .object(dictVal.mapValues { $0.storage })
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .null:
            try container.encodeNil()
        case .int(let intVal):
            try container.encode(intVal)
        case .double(let doubleVal):
            try container.encode(doubleVal)
        case .string(let stringVal):
            try container.encode(stringVal)
        case .bool(let boolVal):
            try container.encode(boolVal)
        case .array(let arrayVal):
            try container.encode(arrayVal.map { AnyCodable(storage: $0) })
        case .object(let dictVal):
            try container.encode(dictVal.mapValues { AnyCodable(storage: $0) })
        case .unsupported(let description):
            throw EncodingError.invalidValue(
                description,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AnyCodable value cannot be encoded")
            )
        }
    }

    public var jsonValue: Any {
        storage.jsonValue
    }

    private enum Storage: Sendable, Equatable {
        case null
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)
        case array([Storage])
        case object([String: Storage])
        case unsupported(String)

        init(_ value: Any) {
            // Foundation bridges JSON booleans to NSNumber. Test the CF type before numbers.
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
                return
            }
            switch value {
            case is NSNull:
                self = .null
            case let intVal as Int:
                self = .int(intVal)
            case let intVal as Int64:
                if let exact = Int(exactly: intVal) { self = .int(exact) }
                else { self = .unsupported(String(intVal)) }
            case let doubleVal as Double:
                self = .double(doubleVal)
            case let stringVal as String:
                self = .string(stringVal)
            case let boolVal as Bool:
                self = .bool(boolVal)
            case let arrayVal as [Any]:
                self = .array(arrayVal.map { Storage($0) })
            case let dictVal as [String: Any]:
                self = .object(dictVal.mapValues { Storage($0) })
            default:
                self = .unsupported(String(describing: value))
            }
        }

        var jsonValue: Any {
            switch self {
            case .null:
                return NSNull()
            case .int(let intVal):
                return intVal
            case .double(let doubleVal):
                return doubleVal
            case .string(let stringVal):
                return stringVal
            case .bool(let boolVal):
                return boolVal
            case .array(let arrayVal):
                return arrayVal.map { $0.jsonValue }
            case .object(let dictVal):
                return dictVal.mapValues { $0.jsonValue }
            case .unsupported(let description):
                return description
            }
        }
    }
}
