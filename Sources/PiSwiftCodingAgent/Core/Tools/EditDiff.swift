import Foundation

public enum LineEnding: String {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

public func detectLineEnding(_ content: String) -> LineEnding {
    if content.contains("\r\n") {
        return .crlf
    }
    if content.contains("\r") {
        return .cr
    }
    return .lf
}

public func normalizeToLF(_ content: String) -> String {
    content
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

public func restoreLineEndings(_ content: String, _ ending: LineEnding) -> String {
    switch ending {
    case .lf:
        return content
    case .crlf:
        return content.replacingOccurrences(of: "\n", with: "\r\n")
    case .cr:
        return content.replacingOccurrences(of: "\n", with: "\r")
    }
}

public func stripBom(_ content: String) -> (bom: String, text: String) {
    if content.hasPrefix("\u{FEFF}") {
        let start = content.index(after: content.startIndex)
        return ("\u{FEFF}", String(content[start...]))
    }
    return ("", content)
}

/// Read file as Data and convert to String, preserving BOM information.
/// Swift's String(contentsOfFile:encoding:) automatically strips the BOM,
/// so we need to read as Data first and check for BOM bytes manually.
public func readFilePreservingBom(_ path: String) throws -> (bom: String, text: String) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))

    // Check for UTF-8 BOM: EF BB BF
    let hasBom = data.count >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF

    if hasBom {
        // Convert text after BOM to String
        let textData = data.dropFirst(3)
        guard let text = String(data: Data(textData), encoding: .utf8) else {
            throw NSError(domain: "EditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode file as UTF-8"])
        }
        return ("\u{FEFF}", text)
    } else {
        // No BOM, convert entire data to String
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "EditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode file as UTF-8"])
        }
        return ("", text)
    }
}

// MARK: - Fuzzy Matching

/// Normalize text for fuzzy matching. Applies transformations:
/// - Strip trailing whitespace from each line
/// - Normalize smart quotes to ASCII equivalents
/// - Normalize Unicode dashes/hyphens to ASCII hyphen
/// - Normalize special Unicode spaces to regular space
public func normalizeForFuzzyMatch(_ text: String) -> String {
    var result = text
        // NFKC normalization for consistent Unicode matching
        .precomposedStringWithCompatibilityMapping
        // Strip trailing whitespace per line
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            var s = String(line)
            while s.last?.isWhitespace == true { s.removeLast() }
            return s
        }
        .joined(separator: "\n")

    // Smart single quotes → '
    // U+2018 left single quote, U+2019 right single quote,
    // U+201A single low-9 quote, U+201B single high-reversed-9 quote
    result = result.replacingOccurrences(
        of: "[\u{2018}\u{2019}\u{201A}\u{201B}]",
        with: "'",
        options: .regularExpression
    )

    // Smart double quotes → "
    // U+201C left double quote, U+201D right double quote,
    // U+201E double low-9 quote, U+201F double high-reversed-9 quote
    result = result.replacingOccurrences(
        of: "[\u{201C}\u{201D}\u{201E}\u{201F}]",
        with: "\"",
        options: .regularExpression
    )

    // Various dashes/hyphens → -
    // U+2010 hyphen, U+2011 non-breaking hyphen, U+2012 figure dash,
    // U+2013 en-dash, U+2014 em-dash, U+2015 horizontal bar, U+2212 minus
    result = result.replacingOccurrences(
        of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}]",
        with: "-",
        options: .regularExpression
    )

    // Special spaces → regular space
    // U+00A0 NBSP, U+2002-U+200A various spaces, U+202F narrow NBSP,
    // U+205F medium math space, U+3000 ideographic space
    result = result.replacingOccurrences(
        of: "[\u{00A0}\u{2002}-\u{200A}\u{202F}\u{205F}\u{3000}]",
        with: " ",
        options: .regularExpression
    )

    return result
}

/// Result of fuzzy text matching
public struct EditFuzzyMatchResult: Sendable {
    /// Whether a match was found
    public var found: Bool
    /// The index where the match starts (in the content that should be used for replacement)
    public var index: Int
    /// Length of the matched text
    public var matchLength: Int
    /// Whether fuzzy matching was used (false = exact match)
    public var usedFuzzyMatch: Bool
    /// The content to use for replacement operations.
    /// When exact match: original content. When fuzzy match: normalized content.
    public var contentForReplacement: String
}

/// Find oldText in content, trying exact match first, then fuzzy match.
/// When fuzzy matching is used, the returned contentForReplacement is the
/// fuzzy-normalized version of the content.
public func fuzzyFindText(_ content: String, _ oldText: String) -> EditFuzzyMatchResult {
    // Try exact match first
    if let exactRange = content.range(of: oldText) {
        let index = content.distance(from: content.startIndex, to: exactRange.lowerBound)
        return EditFuzzyMatchResult(
            found: true,
            index: index,
            matchLength: oldText.count,
            usedFuzzyMatch: false,
            contentForReplacement: content
        )
    }

    // Try fuzzy match - work entirely in normalized space
    let fuzzyContent = normalizeForFuzzyMatch(content)
    let fuzzyOldText = normalizeForFuzzyMatch(oldText)

    guard let fuzzyRange = fuzzyContent.range(of: fuzzyOldText) else {
        return EditFuzzyMatchResult(
            found: false,
            index: -1,
            matchLength: 0,
            usedFuzzyMatch: false,
            contentForReplacement: content
        )
    }

    let index = fuzzyContent.distance(from: fuzzyContent.startIndex, to: fuzzyRange.lowerBound)

    // When fuzzy matching, we work in the normalized space for replacement.
    return EditFuzzyMatchResult(
        found: true,
        index: index,
        matchLength: fuzzyOldText.count,
        usedFuzzyMatch: true,
        contentForReplacement: fuzzyContent
    )
}

// MARK: - Line Diff Algorithm

/// Represents a part of a diff result
public struct DiffPart: Sendable {
    public enum Kind: Sendable {
        case equal
        case added
        case removed
    }
    public var kind: Kind
    public var value: String
}

/// Compute line-by-line diff between two strings using LCS algorithm
public func diffLines(_ oldText: String, _ newText: String) -> [DiffPart] {
    let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

    // Compute LCS (Longest Common Subsequence) table
    let m = oldLines.count
    let n = newLines.count
    var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

    for i in 1...m {
        for j in 1...n {
            if oldLines[i - 1] == newLines[j - 1] {
                lcs[i][j] = lcs[i - 1][j - 1] + 1
            } else {
                lcs[i][j] = max(lcs[i - 1][j], lcs[i][j - 1])
            }
        }
    }

    // Backtrack to find the diff
    var result: [DiffPart] = []
    var i = m
    var j = n

    var pendingEqual: [String] = []
    var pendingRemoved: [String] = []
    var pendingAdded: [String] = []

    func flushPending() {
        if !pendingRemoved.isEmpty {
            result.append(DiffPart(kind: .removed, value: pendingRemoved.joined(separator: "\n")))
            pendingRemoved = []
        }
        if !pendingAdded.isEmpty {
            result.append(DiffPart(kind: .added, value: pendingAdded.joined(separator: "\n")))
            pendingAdded = []
        }
        if !pendingEqual.isEmpty {
            result.append(DiffPart(kind: .equal, value: pendingEqual.joined(separator: "\n")))
            pendingEqual = []
        }
    }

    while i > 0 || j > 0 {
        if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
            // Flush non-equal parts first
            if !pendingRemoved.isEmpty || !pendingAdded.isEmpty {
                if !pendingRemoved.isEmpty {
                    result.append(DiffPart(kind: .removed, value: pendingRemoved.reversed().joined(separator: "\n")))
                    pendingRemoved = []
                }
                if !pendingAdded.isEmpty {
                    result.append(DiffPart(kind: .added, value: pendingAdded.reversed().joined(separator: "\n")))
                    pendingAdded = []
                }
            }
            pendingEqual.insert(oldLines[i - 1], at: 0)
            i -= 1
            j -= 1
        } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
            // Flush equal parts first
            if !pendingEqual.isEmpty {
                result.append(DiffPart(kind: .equal, value: pendingEqual.joined(separator: "\n")))
                pendingEqual = []
            }
            pendingAdded.insert(newLines[j - 1], at: 0)
            j -= 1
        } else if i > 0 {
            // Flush equal parts first
            if !pendingEqual.isEmpty {
                result.append(DiffPart(kind: .equal, value: pendingEqual.joined(separator: "\n")))
                pendingEqual = []
            }
            pendingRemoved.insert(oldLines[i - 1], at: 0)
            i -= 1
        }
    }

    // Flush any remaining
    if !pendingRemoved.isEmpty {
        result.append(DiffPart(kind: .removed, value: pendingRemoved.joined(separator: "\n")))
    }
    if !pendingAdded.isEmpty {
        result.append(DiffPart(kind: .added, value: pendingAdded.joined(separator: "\n")))
    }
    if !pendingEqual.isEmpty {
        result.append(DiffPart(kind: .equal, value: pendingEqual.joined(separator: "\n")))
    }

    return result
}

// MARK: - Edit Diff Result Types

/// Result of a successful edit diff computation
public struct EditDiffResult: Sendable {
    public var diff: String
    public var firstChangedLine: Int?

    public init(diff: String, firstChangedLine: Int?) {
        self.diff = diff
        self.firstChangedLine = firstChangedLine
    }
}

/// Error result from edit diff computation
public struct EditDiffError: Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}

/// Union type for edit diff results
public enum EditDiffOutcome: Sendable {
    case success(EditDiffResult)
    case error(EditDiffError)
}

/// Compute the diff for an edit operation without applying it.
/// Used for preview rendering in the TUI before the tool executes.
public func computeEditDiff(path: String, oldText: String, newText: String, cwd: String) -> EditDiffOutcome {
    let absolutePath = resolveToCwd(path, cwd: cwd)

    // Check if file exists and is readable
    guard FileManager.default.isReadableFile(atPath: absolutePath) else {
        return .error(EditDiffError(error: "File not found: \(path)"))
    }

    do {
        // Read the file preserving BOM
        let (_, content) = try readFilePreservingBom(absolutePath)

        let normalizedContent = normalizeToLF(content)
        let normalizedOldText = normalizeToLF(oldText)
        let normalizedNewText = normalizeToLF(newText)

        // Find the old text using fuzzy matching (tries exact match first, then fuzzy)
        let matchResult = fuzzyFindText(normalizedContent, normalizedOldText)

        guard matchResult.found else {
            return .error(EditDiffError(error: "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."))
        }

        // Count occurrences using fuzzy-normalized content for consistency
        let fuzzyContent = normalizeForFuzzyMatch(normalizedContent)
        let fuzzyOldText = normalizeForFuzzyMatch(normalizedOldText)
        let occurrences = fuzzyContent.components(separatedBy: fuzzyOldText).count - 1

        if occurrences > 1 {
            return .error(EditDiffError(error: "Found \(occurrences) occurrences of the text in \(path). The text must be unique. Please provide more context to make it unique."))
        }

        // Compute the new content using the matched position
        let baseContent = matchResult.contentForReplacement
        let startIndex = baseContent.index(baseContent.startIndex, offsetBy: matchResult.index)
        let endIndex = baseContent.index(startIndex, offsetBy: matchResult.matchLength)
        let newContent = baseContent.replacingCharacters(in: startIndex..<endIndex, with: normalizedNewText)

        // Check if it would actually change anything
        if baseContent == newContent {
            return .error(EditDiffError(error: "No changes would be made to \(path). The replacement produces identical content."))
        }

        // Generate the diff
        let result = generateDiffString(baseContent, newContent)
        return .success(EditDiffResult(diff: result.diff, firstChangedLine: result.firstChangedLine))
    } catch {
        return .error(EditDiffError(error: error.localizedDescription))
    }
}

/// Generate a unified diff string with line numbers and context.
/// Returns both the diff string and the first changed line number (in the new file).
public func generateDiffString(_ oldContent: String, _ newContent: String, contextLines: Int = 4) -> (diff: String, firstChangedLine: Int?) {
    let parts = diffLines(oldContent, newContent)
    var output: [String] = []

    let oldLines = oldContent.split(separator: "\n", omittingEmptySubsequences: false)
    let newLines = newContent.split(separator: "\n", omittingEmptySubsequences: false)
    let maxLineNum = max(oldLines.count, newLines.count)
    let lineNumWidth = String(maxLineNum).count

    var oldLineNum = 1
    var newLineNum = 1
    var lastWasChange = false
    var firstChangedLine: Int? = nil

    for i in 0..<parts.count {
        let part = parts[i]
        var raw = part.value.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        if raw.last == "" && !part.value.isEmpty && !part.value.hasSuffix("\n") {
            // Don't remove empty string if it's meaningful
        } else if raw.last == "" && raw.count > 1 {
            raw.removeLast()
        }

        switch part.kind {
        case .added, .removed:
            // Capture the first changed line (in the new file)
            if firstChangedLine == nil {
                firstChangedLine = newLineNum
            }

            // Show the change
            for line in raw {
                if part.kind == .added {
                    let lineNum = String(newLineNum).padding(toLength: lineNumWidth, withPad: " ", startingAt: 0)
                    let padded = String(repeating: " ", count: lineNumWidth - lineNum.trimmingCharacters(in: .whitespaces).count) + lineNum.trimmingCharacters(in: .whitespaces)
                    output.append("+\(padded) \(line)")
                    newLineNum += 1
                } else {
                    let lineNum = String(oldLineNum).padding(toLength: lineNumWidth, withPad: " ", startingAt: 0)
                    let padded = String(repeating: " ", count: lineNumWidth - lineNum.trimmingCharacters(in: .whitespaces).count) + lineNum.trimmingCharacters(in: .whitespaces)
                    output.append("-\(padded) \(line)")
                    oldLineNum += 1
                }
            }
            lastWasChange = true

        case .equal:
            // Context lines - only show a few before/after changes
            let nextPartIsChange = i < parts.count - 1 && (parts[i + 1].kind == .added || parts[i + 1].kind == .removed)

            if lastWasChange || nextPartIsChange {
                var linesToShow = raw
                var skipStart = 0
                var skipEnd = 0

                if !lastWasChange {
                    // Show only last N lines as leading context
                    skipStart = max(0, raw.count - contextLines)
                    linesToShow = Array(raw.suffix(from: skipStart))
                }

                if !nextPartIsChange && linesToShow.count > contextLines {
                    // Show only first N lines as trailing context
                    skipEnd = linesToShow.count - contextLines
                    linesToShow = Array(linesToShow.prefix(contextLines))
                }

                // Add ellipsis if we skipped lines at start
                if skipStart > 0 {
                    let padding = String(repeating: " ", count: lineNumWidth)
                    output.append(" \(padding) ...")
                    oldLineNum += skipStart
                    newLineNum += skipStart
                }

                for line in linesToShow {
                    let lineNum = String(oldLineNum)
                    let padded = String(repeating: " ", count: lineNumWidth - lineNum.count) + lineNum
                    output.append(" \(padded) \(line)")
                    oldLineNum += 1
                    newLineNum += 1
                }

                // Add ellipsis if we skipped lines at end
                if skipEnd > 0 {
                    let padding = String(repeating: " ", count: lineNumWidth)
                    output.append(" \(padding) ...")
                    oldLineNum += skipEnd
                    newLineNum += skipEnd
                }
            } else {
                // Skip these context lines entirely
                oldLineNum += raw.count
                newLineNum += raw.count
            }

            lastWasChange = false
        }
    }

    return (output.joined(separator: "\n"), firstChangedLine)
}
