import Foundation

/// A named document for tool discovery.
public struct SearchDocument: Sendable, Equatable {
    /// The name returned when the document matches.
    public let name: String
    /// The text used for token counts and scoring.
    public let text: String

    /// Creates a search document.
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

private let searchStopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it",
    "of", "on", "or", "that", "the", "this", "to", "with",
]

private func singularSearchTerm(_ term: String) -> String {
    if term.count > 4 && term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
    if term.count > 4 && ["ches", "shes", "sses", "xes", "zes"].contains(where: term.hasSuffix) {
        return String(term.dropLast(2))
    }
    if term.count > 3 && term.hasSuffix("s") && !term.hasSuffix("ss") { return String(term.dropLast()) }
    return term
}

/// Splits camel case and ASCII terms, removes stop words, and applies simple singular forms.
public func tokenize(_ text: String) -> [String] {
    // Upstream splits ASCII case boundaries before Unicode lowercase conversion.
    // Lowercase can introduce ASCII letters, for example U+0130 and U+212A.
    var separated = text
    for pattern in ["([a-z0-9])([A-Z])", "([A-Z]+)([A-Z][a-z])"] {
        separated = separated.replacingOccurrences(of: pattern, with: "$1 $2", options: .regularExpression)
    }
    return separated.lowercased().components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
        .filter { !$0.isEmpty && !searchStopWords.contains($0) }
        .map(singularSearchTerm)
}

/// Returns positive BM25 matches, best first. Equal scores retain document order.
public func rankDocuments(_ query: String, documents: [SearchDocument], limit: Int) -> [String] {
    let k1 = 1.2
    let b = 0.75
    var seen: Set<String> = []
    let terms = tokenize(query).filter { seen.insert($0).inserted }
    guard !terms.isEmpty, !documents.isEmpty, limit > 0 else { return [] }
    let counts = documents.map { document in
        tokenize(document.text).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    }
    let lengths = counts.map { $0.values.reduce(0, +) }
    let average = Double(lengths.reduce(0, +)) / Double(documents.count)
    let averageLength = average == 0 ? 1 : average
    let idf = Dictionary(uniqueKeysWithValues: terms.map { term in
        let frequency = counts.filter { $0[term] != nil }.count
        return (term, log(1 + (Double(documents.count - frequency) + 0.5) / (Double(frequency) + 0.5)))
    })
    var matches: [(index: Int, name: String, score: Double)] = []
    for (index, document) in documents.enumerated() {
        var score = 0.0
        for term in terms {
            guard let count = counts[index][term] else { continue }
            let norm = k1 * (1 - b + b * Double(lengths[index]) / averageLength)
            score += (idf[term] ?? 0) * (Double(count) * (k1 + 1) / (Double(count) + norm))
        }
        if score > 0 { matches.append((index, document.name, score)) }
    }
    return matches.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        .prefix(limit).map(\.name)
}
