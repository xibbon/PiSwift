import Foundation
import PiSwiftAI

/// JSON-RPC 2.0 accepts a string or a finite number as a request identifier.
public enum JsonRpcId: Hashable, Sendable, Codable {
    case string(String)
    case integer(Int)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { self = .string(string); return }
        if let integer = try? value.decode(Int.self) { self = .integer(integer); return }
        if let number = try? value.decode(Double.self), number.isFinite { self = .number(number); return }
        throw DecodingError.dataCorruptedError(in: value, debugDescription: "JSON-RPC id must be a string or finite number")
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        }
    }
}

public func == (lhs: JsonRpcId, rhs: Int) -> Bool { lhs == .integer(rhs) }
public func == (lhs: Int, rhs: JsonRpcId) -> Bool { rhs == lhs }
public func == (lhs: JsonRpcId?, rhs: Int) -> Bool { lhs == .some(.integer(rhs)) }
public func == (lhs: Int, rhs: JsonRpcId?) -> Bool { rhs == lhs }

public struct JsonRpcRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: JsonRpcId
    public var method: String
    public var params: AnyCodable?

    public init(id: JsonRpcId, method: String, params: AnyCodable? = nil) {
        self.id = id; self.method = method; self.params = params
    }

    public init(id: Int, method: String, params: AnyCodable? = nil) {
        self.init(id: .integer(id), method: method, params: params)
    }
}

public struct JsonRpcNotification: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var method: String
    public var params: AnyCodable?

    public init(method: String, params: AnyCodable? = nil) {
        self.method = method; self.params = params
    }
}

public struct JsonRpcResponse: Codable, Sendable {
    public var jsonrpc: String
    public var id: JsonRpcId?
    public var result: AnyCodable?
    public var error: JsonRpcError?
}

public typealias JsonRpcServerRequest = JsonRpcRequest

public struct JsonRpcServerResponse: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: JsonRpcId
    public var result: AnyCodable?
    public var error: JsonRpcError?

    public init(id: JsonRpcId, result: AnyCodable?, error: JsonRpcError?) {
        self.id = id; self.result = result; self.error = error
    }
}

public enum JsonRpcIncomingMessage: Sendable {
    case response(JsonRpcResponse)
    case request(JsonRpcRequest)
    case notification(JsonRpcNotification)
}

public struct JsonRpcError: Codable, Sendable {
    public var code: Int
    public var message: String
    public var data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code; self.message = message; self.data = data
    }
}

public enum JsonRpc {
    public static func encode(_ request: JsonRpcRequest) throws -> Data { try JSONEncoder().encode(request) }
    public static func encodeNotification(_ notification: JsonRpcNotification) throws -> Data { try JSONEncoder().encode(notification) }
    public static func decodeResponse(_ data: Data) throws -> JsonRpcResponse {
        let response = try JSONDecoder().decode(JsonRpcResponse.self, from: data)
        guard response.jsonrpc == "2.0", response.id != nil, (response.result != nil) != (response.error != nil) else {
            throw McpError.protocolError("Invalid JSON-RPC response")
        }
        return response
    }

    public static func decodeIncoming(_ data: Data) throws -> JsonRpcIncomingMessage {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any], object["jsonrpc"] as? String == "2.0" else {
            throw McpError.protocolError("Invalid JSON-RPC message")
        }
        if let method = object["method"] as? String {
            if object.keys.contains("id") { return .request(try JSONDecoder().decode(JsonRpcRequest.self, from: data)) }
            return .notification(JsonRpcNotification(method: method, params: object["params"].map(AnyCodable.init)))
        }
        return .response(try decodeResponse(data))
    }

    public static func encodeToLine(_ request: JsonRpcRequest) throws -> Data {
        var data = try encode(request); data.append(10); return data
    }
    public static func encodeNotificationToLine(_ notification: JsonRpcNotification) throws -> Data {
        var data = try encodeNotification(notification); data.append(10); return data
    }
    public static func encodeServerResponseToLine(_ response: JsonRpcServerResponse) throws -> Data {
        var data = try JSONEncoder().encode(response); data.append(10); return data
    }
}

public enum McpError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case protocolError(String)
    case rpcError(code: Int, message: String)
    case timeout
    case transportClosed
    case initializationFailed(String)
    case connectionClosed
    case requestTimeout(Int)
    case aborted
}
