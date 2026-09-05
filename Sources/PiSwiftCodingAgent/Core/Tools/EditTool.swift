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
    var tool = AgentTool(
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
                    ],
                ],
            ]),
            "required": AnyCodable(["path", "edits"]),
        ],
        execute: { _, params, signal, _ in
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
        },
        prepareArguments: { params in
            prepareEditArguments(params)
        }
    )
    tool.executeWithContext = { id, params, signal, onUpdate, context in
        try await createEditTool(cwd: resolveToolExecutionCwd(context, fallback: cwd)).execute(id, params, signal, onUpdate)
    }
    tool.constrainedSampling = getExperimentalToolSampling()
    return tool
}

/// Normalizes inputs the model produces. Some models (Opus 4.6, GLM-5.1) send `edits` as a
/// JSON-encoded string. Others flatten the array into bracket-path keys
/// (`edits[0].oldText`). Older callers send a single `oldText`/`newText` pair without
/// `edits[]` — fold those into a one-element `edits` array and drop the legacy fields.
private func singleEditObject(_ value: Any?) -> [String: Any]? {
    guard let object = value as? [String: Any],
          object["oldText"] is String, object["newText"] is String else { return nil }
    return object
}

private func prepareEditArguments(_ params: [String: AnyCodable]) -> [String: AnyCodable] {
    var args = params

    if let editsString = args["edits"]?.value as? String,
       let data = editsString.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) {
        if let array = parsed as? [Any] {
            args["edits"] = AnyCodable(array)
        } else if let edit = singleEditObject(parsed) {
            args["edits"] = AnyCodable([edit])
        }
    } else if let edit = singleEditObject(args["edits"]?.value) {
        args["edits"] = AnyCodable([edit])
    }

    if args["edits"] == nil || args["edits"]?.value is NSNull {
        let candidateKeys = args.keys.filter { $0.hasPrefix(flattenedEditKeyPrefix) }.sorted()
        var fieldsByIndex: [Int: [String: Any]] = [:]
        var canRebuild = !candidateKeys.isEmpty

        for key in candidateKeys {
            guard let (index, field) = parseFlattenedEditKey(key),
                  fieldsByIndex[index]?[field] == nil else {
                canRebuild = false
                break
            }
            fieldsByIndex[index, default: [:]][field] = args[key]?.value ?? NSNull()
        }

        let indexes = fieldsByIndex.keys.sorted()
        if indexes != Array(0..<indexes.count) {
            canRebuild = false
        }
        if fieldsByIndex.values.contains(where: { $0["oldText"] == nil || $0["newText"] == nil }) {
            canRebuild = false
        }

        if canRebuild {
            args["edits"] = AnyCodable(indexes.compactMap { fieldsByIndex[$0] })
            for key in candidateKeys {
                args.removeValue(forKey: key)
            }
        } else if !candidateKeys.isEmpty {
            return args
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

private let flattenedEditKeyPrefix = "edits["

/// Splits `edits[0].oldText` into its zero-based index and field name.
private func parseFlattenedEditKey(_ key: String) -> (index: Int, field: String)? {
    guard key.hasPrefix(flattenedEditKeyPrefix),
          let closeBracket = key.firstIndex(of: "]") else {
        return nil
    }

    let indexStart = key.index(key.startIndex, offsetBy: flattenedEditKeyPrefix.count)
    let indexText = key[indexStart..<closeBracket]
    guard !indexText.isEmpty,
          indexText.allSatisfy({ $0.isASCII && $0.isNumber }),
          let index = Int(indexText),
          String(index) == indexText else {
        return nil
    }

    let period = key.index(after: closeBracket)
    guard period < key.endIndex, key[period] == "." else {
        return nil
    }
    let fieldStart = key.index(after: period)
    guard fieldStart < key.endIndex else {
        return nil
    }
    return (index, String(key[fieldStart...]))
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
