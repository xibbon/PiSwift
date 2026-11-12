import Foundation

/// A named document for tool discovery.
public struct SearchDocument: Sendable, Equatable {
    public let name: String
    public let text: String
    /// Name, description, and instructions of its namespace.
    public let namespaceText: String
    public init(name: String, text: String, namespaceText: String = "") {
        self.name = name; self.text = text; self.namespaceText = namespaceText
    }
}

private struct SearchMatch: Sendable {
    let name: String
    let score: Double
    init(name: String, score: Double) { self.name = name; self.score = score }
}

private let searchStopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it",
    "of", "on", "or", "that", "the", "this", "to", "with"
]

private func asciiLower(_ scalar: Unicode.Scalar) -> Bool { (97...122).contains(scalar.value) }
private func asciiUpper(_ scalar: Unicode.Scalar) -> Bool { (65...90).contains(scalar.value) }
private func asciiDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }

private func stemToolSearchTerm(_ term: String) -> String {
    if term.count > 4 && term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
    if term.count > 4 && ["ches", "shes", "sses", "xes", "zes"].contains(where: term.hasSuffix) {
        return String(term.dropLast(2))
    }
    if term.count > 3 && term.hasSuffix("s") && !term.hasSuffix("ss") { return String(term.dropLast()) }
    return term
}

/// Segment Unicode words and split ASCII identifier boundaries.
public func tokenize(_ text: String) -> [String] {
    let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
    var separated = ""
    for index in scalars.indices {
        let scalar = scalars[index]
        let previous = index > 0 ? scalars[index - 1] : nil
        let next = index + 1 < scalars.count ? scalars[index + 1] : nil
        if asciiUpper(scalar), let previous,
           (asciiLower(previous) || asciiDigit(previous) ||
            (asciiUpper(previous) && next.map(asciiLower) == true)) {
            separated.append(" ")
        }
        separated.unicodeScalars.append(scalar)
    }
    let normalized = separated.lowercased()
    var filtered = ""
    for scalar in normalized.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            filtered.unicodeScalars.append(scalar)
        default:
            filtered.append(" ")
        }
    }
    let words: [String]
    if filtered.unicodeScalars.allSatisfy({ asciiLower($0) || asciiDigit($0) || $0 == " " }) {
        words = filtered.split(separator: " ").map(String.init)
    } else {
        var segments: [String] = []
        var previousEnd: String.Index?
        filtered.enumerateSubstrings(in: filtered.startIndex..<filtered.endIndex, options: .byWords) {
            substring, range, _, _ in
            guard let substring else { return }
            let ascii = substring.unicodeScalars.allSatisfy { asciiLower($0) || asciiDigit($0) }
            if ascii, previousEnd == range.lowerBound, let last = segments.last,
               last.unicodeScalars.allSatisfy({ asciiLower($0) || asciiDigit($0) }) {
                segments[segments.count - 1] += substring
            } else {
                segments.append(substring)
            }
            previousEnd = range.upperBound
        }
        words = segments
    }
    return words.filter { !searchStopWords.contains($0) }.map { word in
        word.unicodeScalars.allSatisfy { asciiLower($0) || asciiDigit($0) } ? stemToolSearchTerm(word) : word
    }
}

private func normalizeSearchName(_ name: String) -> String {
    String(String.UnicodeScalarView(name.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased().unicodeScalars.map { scalar in
            asciiLower(scalar) || asciiDigit(scalar) || scalar == "_" || scalar == "$" ? scalar : "_"
        }))
}

private struct IndexedSearchDocument {
    let name: String
    let nameTerms: Set<String>
    let localNameTerms: Set<String>
    let textCounts: [String: Int]
    let textLength: Int
    let namespaceTerms: Set<String>

    init(_ document: SearchDocument) {
        name = document.name
        nameTerms = Set(tokenize(document.name))
        localNameTerms = Set(tokenize(String(document.name.components(separatedBy: "__").last ?? "")))
        textCounts = tokenize(document.text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        textLength = textCounts.values.reduce(0, +)
        namespaceTerms = Set(tokenize(document.namespaceText))
    }
}

/// Okapi BM25 over the description, with separate name and namespace weights.
private struct Bm25Ranker {
    public let k1: Double
    public let b: Double

    init(k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    func rank(_ query: String, documents: [SearchDocument], limit: Int) -> [SearchMatch] {
        var seen: Set<String> = []
        let queryTerms = tokenize(query).filter { seen.insert($0).inserted }
        guard !queryTerms.isEmpty, !documents.isEmpty, limit > 0 else { return [] }
        let indexed = documents.map(IndexedSearchDocument.init)
        let average = Double(indexed.reduce(0) { $0 + $1.textLength }) / Double(indexed.count)
        let averageLength = average == 0 ? 1 : average
        let idf = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
            let frequency = indexed.filter {
                $0.nameTerms.contains(term) || $0.textCounts[term] != nil || $0.namespaceTerms.contains(term)
            }.count
            return (term, log(1 + (Double(documents.count - frequency) + 0.5) / (Double(frequency) + 0.5)))
        })
        let fullNameBonus = queryTerms.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        let exactQuery = normalizeSearchName(query)
        var matches: [(index: Int, match: SearchMatch, covered: Int, exact: Bool)] = []
        for (index, document) in indexed.enumerated() {
            var score = 0.0
            var covered = 0
            let norm = k1 * (1 - b + b * Double(document.textLength) / averageLength)
            for term in queryTerms {
                let count = Double(document.textCounts[term] ?? 0)
                let weight = (document.nameTerms.contains(term) ? 3.0 : 0.0)
                    + (document.namespaceTerms.contains(term) ? 0.5 : 0.0)
                    + count * (k1 + 1) / (count + norm)
                if weight > 0 { covered += 1 }
                score += (idf[term] ?? 0) * weight
            }
            guard score > 0 else { continue }
            if !document.localNameTerms.isEmpty && document.localNameTerms.isSubset(of: Set(queryTerms)) {
                score += fullNameBonus
            }
            let normalized = normalizeSearchName(document.name)
            let exact = normalized == exactQuery || normalized.hasSuffix("__" + exactQuery)
            matches.append((index, SearchMatch(name: document.name, score: score), covered, exact))
        }
        return matches.sorted {
            if $0.exact != $1.exact { return $0.exact }
            if $0.covered != $1.covered { return $0.covered > $1.covered }
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            return $0.index < $1.index
        }
            .prefix(limit).map(\.match)
    }
}

/// Returns ranked matching names. Exact names and term coverage take priority.
public func rankDocuments(_ query: String, documents: [SearchDocument], limit: Int) -> [String] {
    Bm25Ranker().rank(query, documents: documents, limit: limit).map(\.name)
}
