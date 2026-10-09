import Foundation
import PiSwiftAI
import PiSwiftChord

/// Arguments for the edit tool.
public struct EditToolInput: Sendable, Codable, Equatable {
    /// The file path, relative to the environment directory or absolute.
    public var path: String
    /// The replacements to match against the same original file content.
    public var edits: [Edit]
    /// Creates edit arguments for a file and its replacements.
    public init(path: String, edits: [Edit]) { self.path = path; self.edits = edits }
}

/// The display diff, unified patch, and first changed line from an edit.
public struct EditToolDetails: Sendable, Codable, Equatable {
    /// The display diff with line numbers.
    public var diff: String
    /// The unified patch for the file.
    public var patch: String
    /// The first changed line in the new content, or nil when there is no changed line.
    public var firstChangedLine: Int?
    /// Creates edit details from the display diff, patch, and optional first changed line.
    public init(diff: String, patch: String, firstChangedLine: Int? = nil) {
        self.diff = diff; self.patch = patch; self.firstChangedLine = firstChangedLine
    }
}

private func editSingleArgument(_ value: JSONValue?) -> Bool {
    guard case .object(let value) = value, case .string = value["oldText"], case .string = value["newText"] else { return false }
    return true
}

/// Repairs common argument shapes without changing the input value.
internal func prepareEditArguments(_ input: JSONValue) throws -> JSONValue {
    guard case .object(var args) = input else { return input }
    if case .string(let encoded) = args["edits"], let data = encoded.data(using: .utf8),
       let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
        if case .array = parsed { args["edits"] = parsed }
        else if editSingleArgument(parsed) { args["edits"] = .array([parsed]) }
    } else if editSingleArgument(args["edits"]), let edit = args["edits"] { args["edits"] = .array([edit]) }
    if case .string(let oldText) = args["oldText"], case .string(let newText) = args["newText"] {
        var edits: [JSONValue] = []
        if case .array(let existing) = args["edits"] { edits = existing }
        edits.append(["oldText": .string(oldText), "newText": .string(newText)])
        args.removeValue(forKey: "oldText"); args.removeValue(forKey: "newText")
        args["edits"] = .array(edits)
    }
    return .object(args)
}

private func editAccessError(_ path: String, _ error: FileError) -> DurableToolError {
    DurableToolError(message: "Could not edit file: \(path). Error code: \(error.code.rawValue).")
}

/// Creates the exact text replacement tool.
public func createEditTool() throws -> ToolRegistration {
    let editSchema: JSONValue = ["type": "object", "properties": [
        "oldText": ["type": "string", "description": "Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."],
        "newText": ["type": "string", "description": "Replacement text for this targeted edit."]],
        "required": ["oldText", "newText"]]
    let parameters: JSONObject = ["type": "object", "properties": [
        "path": ["type": "string", "description": "Path to the file to edit (relative or absolute)"],
        "edits": ["type": "array", "items": editSchema,
                  "description": "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead."]],
        "required": ["path", "edits"]]
    return try defineTool(name: "edit",
        description: "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
        parameters: parameters, args: EditToolInput.self, prepareArguments: prepareEditArguments) { args, api, context in
            guard !args.edits.isEmpty else {
                throw DurableToolError(message: "Edit tool input is invalid. edits must contain at least one replacement.")
            }
            let env = try requireEnv(api)
            let absolutePath = try await resolveToolPath(env: env, path: args.path, context: context)
            return try await withFileMutationQueue(env: env, path: absolutePath, context: context) {
                try checkToolAbort(context)
                let info: FileInfo
                switch await env.fileInfo(absolutePath, context: context) {
                case .success(let value): info = value
                case .failure(let error): throw editAccessError(args.path, error)
                }
                guard info.kind == .file || info.kind == .symlink else {
                    throw DurableToolError(message: "Could not edit file: \(args.path). Path is not a file.")
                }
                let original: String
                switch await env.readTextFile(absolutePath, context: context) {
                case .success(let value): original = value
                case .failure(let error): throw editAccessError(args.path, error)
                }
                try checkToolAbort(context)
                let (bom, content) = stripBom(original), ending = detectLineEnding(content)
                let applied = try applyEditsToNormalizedContent(normalizeToLF(content), edits: args.edits, path: args.path)
                try checkToolAbort(context)
                let final = bom + restoreLineEndings(applied.newContent, ending: ending)
                if case .failure(let error) = await env.writeFile(absolutePath, content: .text(final), context: context) {
                    throw editAccessError(args.path, error)
                }
                try checkToolAbort(context)
                let diff = generateDiffString(applied.baseContent, newContent: applied.newContent)
                var details: JSONObject = ["diff": .string(diff.diff),
                    "patch": .string(generateUnifiedPatch(args.path, oldContent: applied.baseContent, newContent: applied.newContent))]
                if let first = diff.firstChangedLine { details["firstChangedLine"] = .number(Double(first)) }
                return ToolExecutionResult(content: [.text(TextContent(text: "Successfully replaced \(args.edits.count) block(s) in \(args.path)."))], details: .object(details))
            }
        }
}
