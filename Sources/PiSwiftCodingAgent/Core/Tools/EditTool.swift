import Foundation
import PiSwiftAI
import PiSwiftAgent

enum EditToolError: LocalizedError, Sendable {
    case operationAborted
    case missingPath
    case invalidInput
    case fileNotFound(path: String)
    case exactTextNotFoundDetailed(path: String)
    case textNotUnique(path: String, occurrences: Int)
    case exactTextNotFound(path: String)
    case noChanges(path: String)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case .missingPath:
            return "Missing path"
        case .invalidInput:
            return "Edit tool input is invalid. edits must contain at least one replacement."
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case let .exactTextNotFoundDetailed(path):
            return "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."
        case let .textNotUnique(path, occurrences):
            return "Found \(occurrences) occurrences of the text in \(path). The text must be unique. Please provide more context to make it unique."
        case let .exactTextNotFound(path):
            return "Could not find the exact text in \(path)."
        case let .noChanges(path):
            return "No changes made to \(path). The replacement produced identical content."
        }
    }
}

public struct EditToolDetails: Sendable {
    public var diff: String
    public var firstChangedLine: Int?
}

public func createEditTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "edit",
        name: "edit",
        description: "Edit a file with one or more targeted text replacements.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to edit (relative or absolute)"],
                "edits": [
                    "type": "array",
                    "description": "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "oldText": ["type": "string", "description": "Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."],
                            "newText": ["type": "string", "description": "Replacement text for this targeted edit."],
                        ],
                        "required": ["oldText", "newText"],
                        "additionalProperties": false,
                    ],
                ],
            ]),
            "required": AnyCodable(["path", "edits"]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw EditToolError.operationAborted
        }
        let prepared = prepareEditArguments(params)
        guard let path = prepared["path"]?.value as? String else {
            throw EditToolError.missingPath
        }
        let edits = parseEdits(from: prepared["edits"])
        guard !edits.isEmpty else {
            throw EditToolError.invalidInput
        }

        let absolutePath = resolveToCwd(path, cwd: cwd)
        guard FileManager.default.isReadableFile(atPath: absolutePath),
              FileManager.default.isWritableFile(atPath: absolutePath) else {
            throw EditToolError.fileNotFound(path: path)
        }

        return try await FileMutationQueue.shared.withFileLock(absolutePath) {
            let (bom, content) = try readFilePreservingBom(absolutePath)
            let originalEnding = detectLineEnding(content)
            let normalizedContent = normalizeToLF(content)
            let applied = try applyEditsToNormalizedContent(normalizedContent, edits: edits, path: path)
            let finalContent = bom + restoreLineEndings(applied.newContent, originalEnding)
            try finalContent.write(toFile: absolutePath, atomically: true, encoding: .utf8)

            let diffResult = generateDiffString(applied.baseContent, applied.newContent)
            let firstChanged: Any = diffResult.firstChangedLine != nil ? diffResult.firstChangedLine! : NSNull()
            let details = AnyCodable([
                "diff": diffResult.diff,
                "firstChangedLine": firstChanged,
            ])

            return AgentToolResult(
                content: [.text(TextContent(text: "Successfully replaced text in \(path)."))],
                details: details
            )
        }
    }
}

/// Normalizes inputs the model produces. Some models (Opus 4.6, GLM-5.1) send `edits` as a
/// JSON-encoded string. Older callers send a single `oldText`/`newText` pair without `edits[]`
/// — fold those into a one-element `edits` array and drop the legacy fields from the args.
private func prepareEditArguments(_ params: [String: AnyCodable]) -> [String: AnyCodable] {
    var args = params

    if let editsValue = args["edits"]?.value, let editsString = editsValue as? String {
        if let data = editsString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any] {
            args["edits"] = AnyCodable(parsed)
        }
    }

    let legacyOld = args["oldText"]?.value as? String
    let legacyNew = args["newText"]?.value as? String
    if let legacyOld, let legacyNew {
        var existing: [Any] = (args["edits"]?.value as? [Any]) ?? []
        existing.append([
            "oldText": legacyOld,
            "newText": legacyNew,
        ])
        args["edits"] = AnyCodable(existing)
        args.removeValue(forKey: "oldText")
        args.removeValue(forKey: "newText")
    }
    return args
}

private func parseEdits(from value: AnyCodable?) -> [EditReplacement] {
    guard let raw = value?.value else { return [] }
    guard let array = raw as? [Any] else { return [] }
    var result: [EditReplacement] = []
    for item in array {
        guard let dict = item as? [String: Any] else { continue }
        let oldText = dict["oldText"] as? String ?? ""
        let newText = dict["newText"] as? String ?? ""
        result.append(EditReplacement(oldText: oldText, newText: newText))
    }
    return result
}
