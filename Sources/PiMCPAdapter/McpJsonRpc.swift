import Foundation
import PiSwiftAI

// MARK: - JSON-RPC 2.0 Types

struct JsonRpcRequest: Codable, Sendable {
    var jsonrpc: String = "2.0"
    var id: Int
    var method: String
    var params: AnyCodable?

    init(id: Int, method: String, params: AnyCodable? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JsonRpcNotification: Codable, Sendable {
    var jsonrpc: String = "2.0"
    var method: String
    var params: AnyCodable?

    init(method: String, params: AnyCodable? = nil) {
        self.method = method
        self.params = params
    }
}

struct JsonRpcResponse: Codable, Sendable {
    var jsonrpc: String
    var id: Int?
    var result: AnyCodable?
    var error: JsonRpcError?
}

struct JsonRpcServerRequest: Codable, Sendable {
    var jsonrpc: String
    var id: AnyCodable
    var method: String
    var params: AnyCodable?
}

struct JsonRpcServerResponse: Codable, Sendable {
    var jsonrpc: String = "2.0"
    var id: AnyCodable
    var result: AnyCodable?
    var error: JsonRpcError?
}

enum JsonRpcIncomingMessage: Sendable {
    case response(JsonRpcResponse)
    case request(JsonRpcServerRequest)
    case notification(JsonRpcNotification)
}

struct JsonRpcError: Codable, Sendable {
    var code: Int
    var message: String
    var data: AnyCodable?
}

// MARK: - Encoding / Decoding Helpers

enum JsonRpc {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    private static let decoder = JSONDecoder()

    static func encode(_ request: JsonRpcRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func encodeNotification(_ notification: JsonRpcNotification) throws -> Data {
        try encoder.encode(notification)
    }

    static func decodeResponse(_ data: Data) throws -> JsonRpcResponse {
        try decoder.decode(JsonRpcResponse.self, from: data)
    }

    static func decodeIncoming(_ data: Data) throws -> JsonRpcIncomingMessage {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw McpError.protocolError("JSON-RPC message is not an object")
        }
        if dictionary["method"] != nil {
            if dictionary["id"] != nil {
                return .request(try decoder.decode(JsonRpcServerRequest.self, from: data))
            }
            return .notification(try decoder.decode(JsonRpcNotification.self, from: data))
        }
        return .response(try decoder.decode(JsonRpcResponse.self, from: data))
    }

    static func encodeToLine(_ request: JsonRpcRequest) throws -> Data {
        var data = try encode(request)
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }

    static func encodeNotificationToLine(_ notification: JsonRpcNotification) throws -> Data {
        var data = try encodeNotification(notification)
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }

    static func encodeServerResponseToLine(_ response: JsonRpcServerResponse) throws -> Data {
        var data = try encoder.encode(response)
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }
}

// MARK: - Errors

public enum McpError: Error, Sendable {
    case connectionFailed(String)
    case protocolError(String)
    case rpcError(code: Int, message: String)
    case timeout
    case transportClosed
    case initializationFailed(String)
}
