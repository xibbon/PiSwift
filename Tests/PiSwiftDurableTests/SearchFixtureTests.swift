import Foundation
import Testing
import PiSwiftDurable

@Suite("PiSwiftDurableTests.SearchFixtures")
struct SearchFixtureTests {
    private struct Fixture: Decodable {
        let tag: String
        let tokens: [TokenCase]
        let rankings: [RankingCase]
    }

    private struct TokenCase: Decodable {
        let text: String
        let expected: [String]
    }

    private struct Document: Decodable {
        let name: String
        let text: String
    }

    private struct RankingCase: Decodable {
        let set: String
        let query: String
        let limit: Int
        let documents: [Document]
        let expected: [String]
    }

    @Test func searchMatchesTheUnmodifiedUpstreamTag() throws {
        let url = try #require(Bundle.module.url(forResource: "search-v130", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.tag == "v1.3.0")
        #expect(fixture.tokens.count == 9)
        #expect(fixture.rankings.count == 20)
        for item in fixture.tokens {
            #expect(tokenize(item.text) == item.expected, "Token input: \(item.text)")
        }
        for item in fixture.rankings {
            let documents = item.documents.map { SearchDocument(name: $0.name, text: $0.text) }
            #expect(rankDocuments(item.query, documents: documents, limit: item.limit) == item.expected,
                    "Ranking set: \(item.set), query: \(item.query), limit: \(item.limit)")
        }
    }
}
