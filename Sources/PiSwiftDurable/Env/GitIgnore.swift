import Foundation

/// The pattern rules of ignore 0.4.33 and globset 0.4.20.
/// Parsing and byte matching use explicit stacks, without recursive backtracking.
internal struct GitIgnoreRule: Sendable {
    let negated: Bool
    private let directoryOnly: Bool
    private let tokens: [Token]

    private enum Token: Sendable {
        case literal(UInt8), any, star, recursiveStar, directories, directoryBody
        case characterClass(Set<UInt8>), split([Int]), jump(Int)
    }
    private enum GlobToken {
        case literal(Unicode.Scalar), any, star, prefix, suffix, between
        case characterClass(Set<UInt8>), alternates([Token])
    }

    init?(_ line: String) {
        guard !line.hasPrefix("#") else { return nil }
        var scalars = Array(line.unicodeScalars)
        // ignore::add_line preserves the entire line only for this exact suffix.
        if !line.hasSuffix("\\ ") {
            while scalars.last?.properties.isWhitespace == true { scalars.removeLast() }
        }
        guard !scalars.isEmpty else { return nil }
        var absolute = false, negated = false
        if scalars.starts(with: ["\\", "!"]) || scalars.starts(with: ["\\", "#"]) {
            scalars.removeFirst()
        } else {
            if scalars.first == "!" { negated = true; scalars.removeFirst() }
            if scalars.first == "/" { absolute = true; scalars.removeFirst() }
        }
        self.negated = negated
        directoryOnly = scalars.last == "/"
        if directoryOnly {
            scalars.removeLast()
            if scalars.last == "\\" { scalars.removeLast() }
        }
        if !absolute && !scalars.contains("/") && scalars != ["*", "*"] {
            scalars.insert(contentsOf: ["*", "*", "/"], at: 0)
        }
        if scalars.suffix(3) == ["/", "*", "*"] { scalars += ["/", "*"] }
        guard let parsed = Self.parse(scalars) else { return nil }
        tokens = Self.compile(parsed, entirePattern: true)
    }

    private static func parse(_ pattern: [Unicode.Scalar]) -> [GlobToken]? {
        var branches: [[GlobToken]] = [[]], alternates: [Int] = [], index = 0, unclosedClass = false
        while index < pattern.count {
            let scalar = pattern[index], last = branches.count - 1
            switch scalar {
            case "\\":
                index += 1
                guard index < pattern.count else { return nil }
                branches[last].append(.literal(pattern[index]))
            case "?": branches[last].append(.any)
            case "*":
                if index + 1 == pattern.count || pattern[index + 1] != "*" {
                    branches[last].append(.star); break
                }
                let previous = index == 0 ? nil : pattern[index - 1]
                index += 1
                let next = index + 1 < pattern.count ? pattern[index + 1] : nil
                if branches[last].isEmpty {
                    if next == nil || next == "/" {
                        branches[last].append(.prefix)
                        if next != nil { index += 1 }
                    } else { branches[last] += [.star, .star] }
                } else if previous != "/" && !(branches.count > 1 && (previous == "," || previous == "{")) {
                    branches[last] += [.star, .star]
                } else if next == nil || next == "/" || (branches.count > 1 && (next == "," || next == "}")) {
                    if next == "/" { index += 1 }
                    let old = branches[last].removeLast()
                    switch old {
                    case .prefix, .suffix: branches[last].append(old)
                    default: branches[last].append(next == nil || next == "," || next == "}" ? .suffix : .between)
                    }
                } else { branches[last] += [.star, .star] }
            case "[" where !unclosedClass:
                if let parsed = characterClass(pattern, start: index) {
                    guard parsed.valid else { return nil }
                    branches[last].append(.characterClass(parsed.bytes)); index = parsed.end
                } else {
                    // globset rolls back and makes all later '[' characters literal.
                    branches[last].append(.literal("[")); unclosedClass = true
                }
            case "{": alternates.append(branches.count); branches.append([])
            case "}":
                guard let start = alternates.popLast() else { return nil }
                let parts = branches[start...].map { compile($0) }.filter { !$0.isEmpty }
                branches.removeSubrange(start...)
                branches[branches.count - 1].append(.alternates(combine(parts)))
            case "," where !alternates.isEmpty: branches.append([])
            default: branches[last].append(.literal(scalar))
            }
            index += 1
        }
        guard branches.count == 1, alternates.isEmpty else { return nil }
        return branches[0]
    }

    private static func compile(_ parsed: [GlobToken], entirePattern: Bool = false) -> [Token] {
        if entirePattern, parsed.count == 1, case .prefix = parsed[0] { return [.recursiveStar] }
        var result: [Token] = []
        for token in parsed {
            switch token {
            case .literal(let scalar): result += String(scalar).utf8.map { .literal($0) }
            case .any: result.append(.any)
            case .star: result.append(.star)
            case .prefix: result += [.directories, .directoryBody]
            case .suffix: result += [.literal(47), .recursiveStar]
            case .between: result += [.literal(47), .directories, .directoryBody]
            case .characterClass(let values): result.append(.characterClass(values))
            case .alternates(let tokens): result += tokens
            }
        }
        return result
    }

    /// Branch offsets are relative. Nested alternatives need no recursive objects.
    private static func combine(_ branches: [[Token]]) -> [Token] {
        guard !branches.isEmpty else { return [] }
        var result: [Token] = [.split([])], starts: [Int] = [], ends: [Int] = []
        for branch in branches {
            starts.append(result.count); result += branch
            ends.append(result.count); result.append(.jump(0))
        }
        result[0] = .split(starts)
        for end in ends { result[end] = .jump(result.count - end) }
        return result
    }

    func matches(_ path: [UInt8], isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }
        var states = [Bool](repeating: false, count: tokens.count + 1)
        states[0] = true
        func closure(_ states: inout [Bool]) {
            for index in tokens.indices where states[index] {
                switch tokens[index] {
                case .star, .recursiveStar: states[index + 1] = true
                case .directories: states[index + 2] = true
                case .split(let offsets): for offset in offsets { states[index + offset] = true }
                case .jump(let offset): states[index + offset] = true
                default: break
                }
            }
        }
        closure(&states)
        for byte in path {
            var next = [Bool](repeating: false, count: states.count)
            for index in tokens.indices where states[index] {
                switch tokens[index] {
                case .literal(let value): if byte == value { next[index + 1] = true }
                case .any: if byte != 47 { next[index + 1] = true }
                case .star: if byte != 47 { next[index] = true }
                case .recursiveStar: next[index] = true
                case .directories: next[index + 1] = true
                case .directoryBody:
                    next[index] = true
                    if byte == 47 { next[index - 1] = true }
                case .characterClass(let values): if values.contains(byte) { next[index + 1] = true }
                case .split, .jump: break
                }
            }
            closure(&next); states = next
            if !states.contains(true) { return false }
        }
        return states[tokens.count]
    }

    private static func characterClass(_ pattern: [Unicode.Scalar], start: Int) -> (bytes: Set<UInt8>, end: Int, valid: Bool)? {
        var index = start + 1, inverted = false, ranges: [(Unicode.Scalar, Unicode.Scalar)] = []
        if index < pattern.count && (pattern[index] == "!" || pattern[index] == "^") { inverted = true; index += 1 }
        var first = true, inRange = false
        while index < pattern.count {
            let scalar = pattern[index]
            if scalar == "]" && !first {
                if inRange { ranges.append(("-", "-")) }
                var values: Set<UInt8> = []
                for (low, high) in ranges {
                    let from = Array(String(low).utf8), to = Array(String(high).utf8)
                    if low == high { values.formUnion(from) }
                    else {
                        // globset emits UTF-8 escapes inside a non-Unicode regex class.
                        guard from.last! <= to.first! else { return ([], index, false) }
                        values.formUnion(from.dropLast()); values.formUnion(from.last!...to.first!); values.formUnion(to.dropFirst())
                    }
                }
                if inverted { values = Set(UInt8.min...UInt8.max).subtracting(values) }
                return (values, index, true)
            }
            if scalar == "-" && !first && !inRange { inRange = true }
            else if inRange {
                let low = ranges[ranges.count - 1].0
                guard scalar >= low else { return ([], index, false) }
                ranges[ranges.count - 1].1 = scalar; inRange = false
            } else { ranges.append((scalar, scalar)) }
            first = false; index += 1
        }
        return nil
    }
}

internal enum GitIgnore {
    static func rules(_ text: String) -> [GitIgnoreRule] {
        var text = text
        while text.hasPrefix("\u{feff}") { text.removeFirst() }
        let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        return lines.enumerated().compactMap { index, bytes in
            let line = index < lines.count - 1 && bytes.last == 13 ? bytes.dropLast() : bytes[...]
            return GitIgnoreRule(String(decoding: line, as: UTF8.self))
        }
    }

    /// Last matching line wins. Nil means that this source has no match.
    static func match(_ rules: [GitIgnoreRule], path: [UInt8], isDirectory: Bool) -> Bool? {
        for rule in rules.reversed() where rule.matches(path, isDirectory: isDirectory) { return !rule.negated }
        return nil
    }
}
