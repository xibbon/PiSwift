import Foundation
import PiSwiftAI
import PiSwiftAgent

enum EditToolError: LocalizedError, Sendable {
    case operationAborted
    case missingPath
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
        description: "Edit a file by replacing exact text. The oldText must match exactly (including whitespace).",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to edit (relative or absolute)"],
                "oldText": ["type": "string", "description": "Exact text to find and replace"],
                "newText": ["type": "string", "description": "New text to replace the old text with"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw EditToolError.operationAborted
        }
        guard let path = params["path"]?.value as? String else {
            throw EditToolError.missingPath
        }
        let oldText = params["oldText"]?.value as? String ?? ""
        let newText = params["newText"]?.value as? String ?? ""

        let absolutePath = resolveToCwd(path, cwd: cwd)
        guard FileManager.default.isReadableFile(atPath: absolutePath),
              FileManager.default.isWritableFile(atPath: absolutePath) else {
            throw EditToolError.fileNotFound(path: path)
        }

        return try await FileMutationQueue.shared.withFileLock(absolutePath) {
            // Read file preserving BOM - Swift's String(contentsOfFile:) strips BOM automatically
            let (bom, content) = try readFilePreservingBom(absolutePath)

            let originalEnding = detectLineEnding(content)
            let normalizedContent = normalizeToLF(content)
            let normalizedOldText = normalizeToLF(oldText)
            let normalizedNewText = normalizeToLF(newText)

            // Find the old text using fuzzy matching (tries exact match first, then fuzzy)
            let matchResult = fuzzyFindText(normalizedContent, normalizedOldText)

            guard matchResult.found else {
                throw EditToolError.exactTextNotFoundDetailed(path: path)
            }

            // Count occurrences using fuzzy-normalized content for consistency
            let fuzzyContent = normalizeForFuzzyMatch(normalizedContent)
            let fuzzyOldText = normalizeForFuzzyMatch(normalizedOldText)
            let occurrences = fuzzyContent.components(separatedBy: fuzzyOldText).count - 1

            if occurrences > 1 {
                throw EditToolError.textNotUnique(path: path, occurrences: occurrences)
            }

            // Perform replacement using the matched text position
            // When fuzzy matching was used, contentForReplacement is the normalized version
            let baseContent = matchResult.contentForReplacement
            let startIndex = baseContent.index(baseContent.startIndex, offsetBy: matchResult.index)
            let endIndex = baseContent.index(startIndex, offsetBy: matchResult.matchLength)
            let normalizedNewContent = baseContent.replacingCharacters(
                in: startIndex..<endIndex,
                with: normalizedNewText
            )

            if baseContent == normalizedNewContent {
                throw EditToolError.noChanges(path: path)
            }

            let finalContent = bom + restoreLineEndings(normalizedNewContent, originalEnding)
            try finalContent.write(toFile: absolutePath, atomically: true, encoding: .utf8)

            let diffResult = generateDiffString(normalizedContent, normalizedNewContent)
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
