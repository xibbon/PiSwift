import Foundation
import PiSwiftChord

internal struct DurableToolError: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

internal func requireEnv(_ api: ToolExecutionApi) throws -> any ExecutionEnv {
    guard let env = api.env else { throw NoExecutionEnvironmentError() }
    return env
}

internal func checkToolAbort(_ context: ChordContext) throws {
    if context.abortSignal?.aborted == true { throw DurableToolError(message: "Operation aborted") }
}

internal func resolveToolPath(env: any ExecutionEnv, path: String, context: ChordContext) async throws -> String {
    let normalized = String(String.UnicodeScalarView(path.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return UnicodeScalar(0x20)!
        default: return scalar
        }
    }))
    let bytes = normalized.utf8
    let toolPath = bytes.first == 0x40 ? String(decoding: bytes.dropFirst(), as: UTF8.self) : normalized
    return try await env.absolutePath(toolPath, context: context).get()
}

internal func resolveReadToolPath(env: any ExecutionEnv, path: String, context: ChordContext) async throws -> String {
    let resolved = try await resolveToolPath(env: env, path: path, context: context)
    let narrow = resolved.replacingOccurrences(of: " (AM|PM)\\.", with: "\u{202F}$1.", options: [.regularExpression, .caseInsensitive])
    let decomposed = resolved.decomposedStringWithCanonicalMapping
    let variants = [resolved, narrow, decomposed,
                    resolved.replacingOccurrences(of: "'", with: "\u{2019}"),
                    decomposed.replacingOccurrences(of: "'", with: "\u{2019}")]
    // Compare UTF-8 bytes. Swift String equality treats NFC and NFD paths as equal.
    var seen: Set<Data> = []
    for variant in variants where seen.insert(Data(variant.utf8)).inserted {
        if try await env.exists(variant, context: context).get() { return variant }
    }
    return resolved
}
