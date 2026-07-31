import Testing
@testable import PiMCPAdapter

@Suite("MCP Metadata Store")
struct McpMetadataStoreTests {
    @Test("in-memory store keeps only adapter metadata")
    func savesAndLoadsMetadata() async {
        let store = InMemoryMcpMetadataStore()
        let cache = MetadataCache(servers: [
            "demo": ServerCacheEntry(
                configHash: "hash",
                tools: [CachedTool(name: "lookup")],
                resources: [],
                cachedAt: 1
            ),
        ])

        await store.save(cache)
        let restored = await store.load()
        #expect(restored?.servers["demo"]?.tools.map(\.name) == ["lookup"])
    }
}
