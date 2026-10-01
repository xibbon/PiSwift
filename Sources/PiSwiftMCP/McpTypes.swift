import Foundation
import PiSwiftAI

public let LATEST_PROTOCOL_VERSION = "2025-11-25"
public let SUPPORTED_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

public enum McpProtocolVersion: String, CaseIterable, Sendable {
    case v2025_11_25 = "2025-11-25"
    case v2025_06_18 = "2025-06-18"
    case v2025_03_26 = "2025-03-26"
    case v2024_11_05 = "2024-11-05"
}

public struct McpImplementation: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var title: String?
    public init(name: String, version: String, title: String? = nil) {
        self.name = name; self.version = version; self.title = title
    }
}

public struct McpRoot: Codable, Sendable, Equatable {
    public var uri: String
    public var name: String?
    public init(uri: String, name: String? = nil) { self.uri = uri; self.name = name }
}

public struct McpProgressNotification: Codable, Sendable {
    public var progressToken: JsonRpcId
    public var progress: Double
    public var total: Double?
    public var message: String?
}

public struct McpContentAnnotations: Codable, Sendable {
    public var audience: [String]?
    public var priority: Double?
    public var lastModified: String?
    public init(audience: [String]? = nil, priority: Double? = nil, lastModified: String? = nil) {
        self.audience = audience; self.priority = priority; self.lastModified = lastModified
    }
}

public struct McpToolAnnotations: Codable, Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?
    public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.title = title; self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint; self.openWorldHint = openWorldHint
    }
}

public struct McpToolExecution: Codable, Sendable {
    public var taskSupport: String?
    public init(taskSupport: String? = nil) { self.taskSupport = taskSupport }
}

// MARK: - Transport

public enum McpTransportType: String, Codable, Sendable {
    case stdio
    case http
}

// MARK: - MCP Tool / Resource Definitions

public struct McpTool: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: AnyCodable?
    public var outputSchema: AnyCodable?
    public var annotations: McpToolAnnotations?
    public var execution: McpToolExecution?
    public var meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, outputSchema, annotations, execution
        case meta = "_meta"
    }

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: AnyCodable? = nil,
        outputSchema: AnyCodable? = nil,
        annotations: McpToolAnnotations? = nil,
        execution: McpToolExecution? = nil,
        meta: AnyCodable? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.execution = execution
        self.meta = meta
    }
}

public struct McpResource: Codable, Sendable {
    public var uri: String
    public var name: String
    public var description: String?
    public var mimeType: String?
    public var title: String?
    public var size: Int?
    public var annotations: McpContentAnnotations?
    public var meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case uri, name, description, mimeType, title, size, annotations
        case meta = "_meta"
    }

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil, title: String? = nil, size: Int? = nil, annotations: McpContentAnnotations? = nil, meta: AnyCodable? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.title = title
        self.size = size
        self.annotations = annotations
        self.meta = meta
    }
}

public struct McpResourceTemplate: Codable, Sendable {
    public var uriTemplate: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var annotations: McpContentAnnotations?
    public var meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case uriTemplate, name, title, description, mimeType, annotations
        case meta = "_meta"
    }

    public init(uriTemplate: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil, annotations: McpContentAnnotations? = nil, meta: AnyCodable? = nil) {
        self.uriTemplate = uriTemplate; self.name = name; self.title = title
        self.description = description; self.mimeType = mimeType
        self.annotations = annotations; self.meta = meta
    }
}

public struct McpPromptArgument: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var required: Bool?

    public init(name: String, title: String? = nil, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }
}

public struct McpPrompt: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [McpPromptArgument]?

    public init(name: String, title: String? = nil, description: String? = nil, arguments: [McpPromptArgument]? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct McpPromptMessage: Sendable {
    public var role: String
    public var content: [McpContent]

    public init(role: String, content: [McpContent]) {
        self.role = role
        self.content = content
    }
}

public struct McpPromptResult: Sendable {
    public var description: String?
    public var messages: [McpPromptMessage]

    public init(description: String? = nil, messages: [McpPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

// MARK: - MCP Content Types (tool call responses)

public struct McpContent: Codable, Sendable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?
    public var resource: McpResourceContent?
    public var uri: String?
    public var name: String?
    public var title: String?
    public var description: String?
    public var size: Int?
    public var annotations: McpContentAnnotations?
    public var meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource, uri, name, title, description, size, annotations
        case meta = "_meta"
    }

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil, resource: McpResourceContent? = nil, uri: String? = nil, name: String? = nil, title: String? = nil, description: String? = nil, size: Int? = nil, annotations: McpContentAnnotations? = nil, meta: AnyCodable? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
        self.resource = resource
        self.uri = uri
        self.name = name
        self.title = title; self.description = description; self.size = size
        self.annotations = annotations; self.meta = meta
    }
}

public struct McpResourceContent: Codable, Sendable {
    public var uri: String
    public var text: String?
    public var blob: String?
    public var mimeType: String?
    public var meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case uri, text, blob, mimeType
        case meta = "_meta"
    }

    public init(uri: String, text: String? = nil, blob: String? = nil, mimeType: String? = nil, meta: AnyCodable? = nil) {
        self.uri = uri
        self.text = text
        self.blob = blob
        self.mimeType = mimeType; self.meta = meta
    }
}

public struct McpToolResult: Sendable {
    public var content: [McpContent]
    public var isError: Bool
    /// Structured MCP result data. The adapter renders this when `content` is
    /// empty, which is permitted by the MCP tools/call result shape.
    public var structuredContent: AnyCodable?
    /// The unmodified JSON-RPC result. This is retained only for proxy-tool
    /// details, where the output guard bounds it before it reaches a session.
    public var rawResult: AnyCodable?
    /// Protocol-level result metadata (`_meta`).
    public var meta: AnyCodable?

    public init(
        content: [McpContent],
        isError: Bool = false,
        structuredContent: AnyCodable? = nil,
        rawResult: AnyCodable? = nil,
        meta: AnyCodable? = nil
    ) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
        self.rawResult = rawResult
        self.meta = meta
    }
}
