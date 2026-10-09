// The line diff and patch algorithms below are adapted from jsdiff.
// BSD 3-Clause License
// Copyright (c) 2009-2015, Kevin Decker <kpdecker@gmail.com>
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
import Foundation

/// One text replacement. All replacements use the same source content.
public struct Edit: Sendable, Codable, Equatable {
    /// The unique text to replace in the original file.
    public var oldText: String
    /// The replacement text.
    public var newText: String
    /// Creates a replacement from the original text and the new text.
    public init(oldText: String, newText: String) { self.oldText = oldText; self.newText = newText }
}

/// The source and result of a group of replacements.
internal struct AppliedEditsResult: Sendable, Codable, Equatable {
    internal var baseContent: String
    internal var newContent: String
    internal init(baseContent: String, newContent: String) { self.baseContent = baseContent; self.newContent = newContent }
}

/// A text match with offsets measured in UTF-16 code units.
internal struct FuzzyMatchResult: Sendable, Equatable {
    internal var found: Bool
    internal var index: Int
    internal var matchLength: Int
    internal var usedFuzzyMatch: Bool
    internal var contentForReplacement: String
}

/// A replacement with offsets measured in UTF-16 code units.
internal struct TextReplacement: Sendable, Equatable {
    internal var matchIndex: Int
    internal var matchLength: Int
    internal var newText: String
    internal init(matchIndex: Int, matchLength: Int, newText: String) {
        self.matchIndex = matchIndex; self.matchLength = matchLength; self.newText = newText
    }
}

/// A display diff and the first changed line in the new content.
internal struct EditDiffResult: Sendable, Equatable {
    internal var diff: String
    internal var firstChangedLine: Int?
    internal init(diff: String, firstChangedLine: Int?) { self.diff = diff; self.firstChangedLine = firstChangedLine }
}

/// Returns the first newline style, or LF when the content has no newline.
internal func detectLineEnding(_ content: String) -> String {
    let units = Array(content.utf16)
    guard let firstLF = units.firstIndex(of: 10) else { return "\n" }
    return firstLF > 0 && units[firstLF - 1] == 13 ? "\r\n" : "\n"
}

/// Replaces CRLF and CR newlines with LF.
internal func normalizeToLF(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
        .replacingOccurrences(of: "\r", with: "\n", options: .literal)
}

/// Restores CRLF when the source used CRLF.
internal func restoreLineEndings(_ text: String, ending: String) -> String {
    ending == "\r\n" ? text.replacingOccurrences(of: "\n", with: "\r\n", options: .literal) : text
}

// ECMAScript WhiteSpace and LineTerminator values used by String.trimEnd().
private func editTrimWhitespace(_ value: UInt32) -> Bool {
    switch value {
    case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
}

/// Applies NFKC, removes trailing spaces, and converts quotes, dashes, and spaces.
internal func normalizeForFuzzyMatch(_ text: String) -> String {
    let normalized = text.precomposedStringWithCompatibilityMapping
    let trimmed = normalized.components(separatedBy: "\n").map { line in
        var scalars = Array(line.unicodeScalars)
        while let last = scalars.last, editTrimWhitespace(last.value) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }.joined(separator: "\n")
    return String(String.UnicodeScalarView(trimmed.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0x2018...0x201B: Unicode.Scalar(0x27)!
        case 0x201C...0x201F: Unicode.Scalar(0x22)!
        case 0x2010...0x2015, 0x2212: Unicode.Scalar(0x2D)!
        case 0xA0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000: Unicode.Scalar(0x20)!
        default: scalar
        }
    }))
}

private func editExactIndex(_ content: String, _ needle: String, from: Int = 0) -> Int? {
    let source = content as NSString
    // JavaScript indexOf("") matches the starting position. NSString does not.
    if needle.isEmpty { return min(max(0, from), source.length) }
    let range = source.range(of: needle, options: .literal, range: NSRange(location: from, length: source.length - from))
    return range.location == NSNotFound ? nil : range.location
}
private func editExactEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
private func editSlice(_ content: String, _ start: Int, _ end: Int) -> String {
    (content as NSString).substring(with: NSRange(location: start, length: end - start))
}

/// Finds exact text first, then text with the fuzzy normalization rules.
internal func fuzzyFindText(_ content: String, oldText: String) -> FuzzyMatchResult {
    if let index = editExactIndex(content, oldText) {
        return .init(found: true, index: index, matchLength: oldText.utf16.count,
                     usedFuzzyMatch: false, contentForReplacement: content)
    }
    let base = normalizeForFuzzyMatch(content), target = normalizeForFuzzyMatch(oldText)
    if let index = editExactIndex(base, target) {
        return .init(found: true, index: index, matchLength: target.utf16.count,
                     usedFuzzyMatch: true, contentForReplacement: base)
    }
    return .init(found: false, index: -1, matchLength: 0, usedFuzzyMatch: false, contentForReplacement: content)
}

/// Removes one leading UTF-8 byte order mark from decoded text.
internal func stripBom(_ content: String) -> (bom: String, text: String) {
    content.utf16.first == 0xFEFF ? ("\u{FEFF}", editSlice(content, 1, content.utf16.count)) : ("", content)
}

private func editLinesWithEndings(_ content: String) -> [String] {
    let units = Array(content.utf16)
    var lines: [String] = [], start = 0
    for index in units.indices where units[index] == 10 {
        lines.append(String(decoding: units[start...index], as: UTF16.self)); start = index + 1
    }
    if start < units.count { lines.append(String(decoding: units[start...], as: UTF16.self)) }
    return lines
}

private func applyTextReplacements(_ content: String, replacements: [TextReplacement], offset: Int = 0) -> String {
    var result = content
    for replacement in replacements.reversed() {
        let start = replacement.matchIndex - offset, end = start + replacement.matchLength
        result = editSlice(result, 0, start) + replacement.newText + editSlice(result, end, result.utf16.count)
    }
    return result
}

/// Changes only the lines that the replacement ranges touch.
internal func applyReplacementsPreservingUnchangedLines(
    _ originalContent: String, baseContent: String, replacements: [TextReplacement]
) throws -> String {
    let originalLines = editLinesWithEndings(originalContent), baseLines = editLinesWithEndings(baseContent)
    guard originalLines.count == baseLines.count else {
        throw DurableToolError(message: "Cannot preserve unchanged lines because the base content has a different line count.")
    }
    var spans: [Range<Int>] = [], offset = 0
    for line in baseLines { let end = offset + line.utf16.count; spans.append(offset..<end); offset = end }
    struct Group { var start: Int; var end: Int; var replacements: [TextReplacement] }
    var groups: [Group] = []
    for replacement in replacements.sorted(by: { $0.matchIndex < $1.matchIndex }) {
        guard let start = spans.firstIndex(where: { $0.contains(replacement.matchIndex) }) else {
            throw DurableToolError(message: "Replacement range is outside the base content.")
        }
        var end = start
        while end < spans.count && spans[end].upperBound < replacement.matchIndex + replacement.matchLength { end += 1 }
        guard end < spans.count else { throw DurableToolError(message: "Replacement range is outside the base content.") }
        if let last = groups.indices.last, start < groups[last].end {
            groups[last].end = max(groups[last].end, end + 1); groups[last].replacements.append(replacement)
        } else { groups.append(.init(start: start, end: end + 1, replacements: [replacement])) }
    }
    var result = "", lineIndex = 0
    for group in groups {
        result += originalLines[lineIndex..<group.start].joined()
        let start = spans[group.start].lowerBound, end = spans[group.end - 1].upperBound
        result += applyTextReplacements(editSlice(baseContent, start, end), replacements: group.replacements, offset: start)
        lineIndex = group.end
    }
    return result + originalLines[lineIndex...].joined()
}

private func editOccurrences(_ content: String, _ oldText: String) -> Int {
    let base = normalizeForFuzzyMatch(content), target = normalizeForFuzzyMatch(oldText), size = target.utf16.count
    // JavaScript split("") returns UTF-16 units; its length minus one is used upstream.
    if size == 0 { return max(0, base.utf16.count - 1) }
    var count = 0, offset = 0
    while let index = editExactIndex(base, target, from: offset) { count += 1; offset = index + size }
    return count
}

/// Matches all edits in the original content. Rejects absent, duplicate, or overlapping targets.
internal func applyEditsToNormalizedContent(_ normalizedContent: String, edits: [Edit], path: String) throws -> AppliedEditsResult {
    let edits = edits.map { Edit(oldText: normalizeToLF($0.oldText), newText: normalizeToLF($0.newText)) }
    for (index, edit) in edits.enumerated() where edit.oldText.isEmpty {
        throw DurableToolError(message: edits.count == 1 ? "oldText must not be empty in \(path)." : "edits[\(index)].oldText must not be empty in \(path).")
    }
    let fuzzy = edits.contains { fuzzyFindText(normalizedContent, oldText: $0.oldText).usedFuzzyMatch }
    let replacementBase = fuzzy ? normalizeForFuzzyMatch(normalizedContent) : normalizedContent
    var matches: [(index: Int, replacement: TextReplacement)] = []
    for (index, edit) in edits.enumerated() {
        let match = fuzzyFindText(replacementBase, oldText: edit.oldText)
        guard match.found else {
            throw DurableToolError(message: edits.count == 1
                ? "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."
                : "Could not find edits[\(index)] in \(path). The oldText must match exactly including all whitespace and newlines.")
        }
        let count = editOccurrences(replacementBase, edit.oldText)
        guard count <= 1 else {
            throw DurableToolError(message: edits.count == 1
                ? "Found \(count) occurrences of the text in \(path). The text must be unique. Please provide more context to make it unique."
                : "Found \(count) occurrences of edits[\(index)] in \(path). Each oldText must be unique. Please provide more context to make it unique.")
        }
        matches.append((index, .init(matchIndex: match.index, matchLength: match.matchLength, newText: edit.newText)))
    }
    matches.sort { $0.replacement.matchIndex < $1.replacement.matchIndex }
    for index in matches.indices.dropFirst() {
        let previous = matches[index - 1], current = matches[index]
        if previous.replacement.matchIndex + previous.replacement.matchLength > current.replacement.matchIndex {
            throw DurableToolError(message: "edits[\(previous.index)] and edits[\(current.index)] overlap in \(path). Merge them into one edit or target disjoint regions.")
        }
    }
    let replacements = matches.map(\.replacement)
    let result = try fuzzy
        ? applyReplacementsPreservingUnchangedLines(normalizedContent, baseContent: replacementBase, replacements: replacements)
        : applyTextReplacements(replacementBase, replacements: replacements)
    guard !editExactEqual(normalizedContent, result) else {
        throw DurableToolError(message: edits.count == 1
            ? "No changes made to \(path). The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."
            : "No changes made to \(path). The replacements produced identical content.")
    }
    return .init(baseContent: normalizedContent, newContent: result)
}

// The path choice and component order follow jsdiff 8.0.4 diffLines. In particular,
// a tie uses the removal path. This controls repeated-line patch alignment.
private enum EditDiffKind { case same, added, removed }
private final class EditDiffComponent {
    let count: Int
    let kind: EditDiffKind
    let previous: EditDiffComponent?
    init(_ count: Int, _ kind: EditDiffKind, _ previous: EditDiffComponent?) {
        self.count = count; self.kind = kind; self.previous = previous
    }
}
private struct EditDiffPath { var oldPosition: Int; var last: EditDiffComponent? }
private struct EditDiffPart { var kind: EditDiffKind; var value: String }
private func editDiffParts(_ oldContent: String, _ newContent: String) -> [EditDiffPart] {
    let old = editLinesWithEndings(oldContent), new = editLinesWithEndings(newContent)
    func common(_ path: inout EditDiffPath, _ diagonal: Int) -> Int {
        var newPosition = path.oldPosition - diagonal, count = 0
        while newPosition + 1 < new.count && path.oldPosition + 1 < old.count && editExactEqual(old[path.oldPosition + 1], new[newPosition + 1]) {
            newPosition += 1; path.oldPosition += 1; count += 1
        }
        if count > 0 { path.last = .init(count, .same, path.last) }
        return newPosition
    }
    func parts(_ last: EditDiffComponent?) -> [EditDiffPart] {
        var components: [EditDiffComponent] = [], next = last
        while let component = next { components.append(component); next = component.previous }
        var oldPosition = 0, newPosition = 0
        return components.reversed().map { component in
            let value: String
            if component.kind == .removed {
                value = old[oldPosition..<(oldPosition + component.count)].joined(); oldPosition += component.count
            } else {
                value = new[newPosition..<(newPosition + component.count)].joined(); newPosition += component.count
                if component.kind == .same { oldPosition += component.count }
            }
            return .init(kind: component.kind, value: value)
        }
    }
    var initial = EditDiffPath(oldPosition: -1), newPosition = common(&initial, 0)
    if initial.oldPosition + 1 >= old.count && newPosition + 1 >= new.count { return parts(initial.last) }
    var best: [Int: EditDiffPath] = [0: initial], minimum = -(old.count + new.count), maximum = old.count + new.count
    for length in 1...(old.count + new.count) {
        var diagonal = max(minimum, -length)
        while diagonal <= min(maximum, length) {
            let remove = best[diagonal - 1], add = best[diagonal + 1]
            if remove != nil { best[diagonal - 1] = nil }
            let canAdd = add.map { let position = $0.oldPosition - diagonal; return position >= 0 && position < new.count } ?? false
            let canRemove = remove.map { $0.oldPosition + 1 < old.count } ?? false
            if !canAdd && !canRemove { best[diagonal] = nil; diagonal += 2; continue }
            let kind: EditDiffKind, source: EditDiffPath
            if !canRemove || (canAdd && remove!.oldPosition < add!.oldPosition) { kind = .added; source = add! }
            else { kind = .removed; source = remove! }
            let last = source.last
            let component = last?.kind == kind ? EditDiffComponent(last!.count + 1, kind, last!.previous) : EditDiffComponent(1, kind, last)
            var path = EditDiffPath(oldPosition: source.oldPosition + (kind == .removed ? 1 : 0), last: component)
            newPosition = common(&path, diagonal)
            if path.oldPosition + 1 >= old.count && newPosition + 1 >= new.count { return parts(path.last) }
            best[diagonal] = path
            if path.oldPosition + 1 >= old.count { maximum = min(maximum, diagonal - 1) }
            if newPosition + 1 >= new.count { minimum = max(minimum, diagonal + 1) }
            diagonal += 2
        }
    }
    return []
}

/// Generates the display diff with line numbers and context.
internal func generateDiffString(_ oldContent: String, newContent: String, contextLines: Int = 4) -> EditDiffResult {
    let parts = editDiffParts(oldContent, newContent), context = max(0, contextLines)
    let width = String(max(oldContent.components(separatedBy: "\n").count, newContent.components(separatedBy: "\n").count)).count
    var output: [String] = [], oldLine = 1, newLine = 1, lastWasChange = false, first: Int?
    func number(_ value: Int) -> String { let value = String(value); return String(repeating: " ", count: width - value.count) + value }
    func showContext(_ lines: ArraySlice<String>) {
        for line in lines { output.append(" \(number(oldLine)) \(line)"); oldLine += 1; newLine += 1 }
    }
    func skip(_ count: Int) {
        if count > 0 { output.append(" \(String(repeating: " ", count: width)) ..."); oldLine += count; newLine += count }
    }
    for (index, part) in parts.enumerated() {
        var lines = part.value.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        if part.kind != .same {
            if first == nil { first = newLine }
            for line in lines {
                if part.kind == .added { output.append("+\(number(newLine)) \(line)"); newLine += 1 }
                else { output.append("-\(number(oldLine)) \(line)"); oldLine += 1 }
            }
            lastWasChange = true
        } else {
            let trailing = index < parts.count - 1 && parts[index + 1].kind != .same
            if lastWasChange && trailing {
                if lines.count <= context * 2 { showContext(lines[...]) }
                else { showContext(lines.prefix(context)); skip(lines.count - context * 2); showContext(lines.suffix(context)) }
            } else if lastWasChange {
                showContext(lines.prefix(context)); skip(lines.count - min(lines.count, context))
            } else if trailing {
                let skipped = max(0, lines.count - context); skip(skipped); showContext(lines.dropFirst(skipped))
            } else { oldLine += lines.count; newLine += lines.count }
            lastWasChange = false
        }
    }
    return .init(diff: output.joined(separator: "\n"), firstChangedLine: first)
}

/// Generates the same file headers and unified hunks as jsdiff createTwoFilesPatch.
internal func generateUnifiedPatch(_ path: String, oldContent: String, newContent: String, contextLines: Int = 4) -> String {
    var parts = editDiffParts(oldContent, newContent)
    parts.append(.init(kind: .same, value: ""))
    let context = max(0, contextLines)
    var output = ["--- \(path)", "+++ \(path)"], current: [String] = []
    var oldStart = 0, newStart = 0, oldLine = 1, newLine = 1, previousLines: [String] = []
    for (index, part) in parts.enumerated() {
        let lines = part.value.isEmpty ? [] : editLinesWithEndings(part.value)
        if part.kind != .same {
            if oldStart == 0 {
                oldStart = oldLine; newStart = newLine
                current = previousLines.suffix(context).map { " " + $0 }
                oldStart -= current.count; newStart -= current.count
            }
            current += lines.map { (part.kind == .added ? "+" : "-") + $0 }
            if part.kind == .added { newLine += lines.count } else { oldLine += lines.count }
        } else {
            if oldStart != 0 {
                if lines.count <= context * 2 && index < parts.count - 2 { current += lines.map { " " + $0 } }
                else {
                    let size = min(lines.count, context)
                    current += lines.prefix(size).map { " " + $0 }
                    let oldCount = oldLine - oldStart + size, newCount = newLine - newStart + size
                    output.append("@@ -\(oldCount == 0 ? oldStart - 1 : oldStart),\(oldCount) +\(newCount == 0 ? newStart - 1 : newStart),\(newCount) @@")
                    for line in current {
                        if line.utf16.last == 10 { output.append(editSlice(line, 0, line.utf16.count - 1)) }
                        else { output.append(line); output.append("\\ No newline at end of file") }
                    }
                    oldStart = 0; newStart = 0; current = []
                }
            }
            oldLine += lines.count; newLine += lines.count
        }
        previousLines = lines
    }
    return output.joined(separator: "\n") + "\n"
}
