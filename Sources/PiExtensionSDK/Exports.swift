// Re-export everything extensions need.
// Extension authors write `import PiExtensionSDK` and get all the types they're
// likely to touch in one import — events and APIs from PiSwiftCodingAgent, AnyCodable
// + content types from PiSwiftAI, and AgentToolResult / AgentTool plumbing from
// PiSwiftAgent (used by `pi.registerTool(_:)`).
@_exported import PiSwiftAI
@_exported import PiSwiftAgent
@_exported import PiSwiftCodingAgent
