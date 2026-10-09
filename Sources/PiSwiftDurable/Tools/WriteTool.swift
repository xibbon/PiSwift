import PiSwiftAI
import PiSwiftChord

/// The file path and UTF-8 text supplied to the write tool.
public struct WriteToolInput: Codable, Sendable, Equatable {
    /// A relative or absolute file path.
    public var path: String
    /// The complete new file content.
    public var content: String
    /// Creates write arguments.
    public init(path: String, content: String) { self.path = path; self.content = content }
}

/// Creates a tool that writes through the call's environment and shares the edit mutation queue.
public func createWriteTool() throws -> ToolRegistration {
    try defineTool(name: "write", description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        parameters: ["type": "object", "properties": [
            "path": ["type": "string", "description": "Path to the file to write (relative or absolute)"],
            "content": ["type": "string", "description": "Content to write to the file"]
        ], "required": ["path", "content"]], args: WriteToolInput.self) { args, api, context in
            let env = try requireEnv(api)
            let absolutePath = try await resolveToolPath(env: env, path: args.path, context: context)
            return try await withFileMutationQueue(env: env, path: absolutePath, context: context) {
                try checkToolAbort(context)
                try await env.writeFile(absolutePath, content: .text(args.content), context: context).get()
                try checkToolAbort(context)
                return ToolExecutionResult(content: [.text(TextContent(text: "Successfully wrote to \(args.path)"))])
            }
        }
}
