import Testing
import Foundation
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("Metadata Cache")
struct MetadataCacheTests {
    @Test("Compute server hash is deterministic")
    func hashDeterministic() {
        let entry = ServerEntry(command: "npx", args: ["-y", "test-server"])
        let h1 = computeServerHash(entry)
        let h2 = computeServerHash(entry)
        #expect(h1 == h2)
        #expect(!h1.isEmpty)
    }

    @Test("Different configs produce different hashes")
    func hashDiffers() {
        let e1 = ServerEntry(command: "npx", args: ["-y", "server-a"])
        let e2 = ServerEntry(command: "npx", args: ["-y", "server-b"])
        #expect(computeServerHash(e1) != computeServerHash(e2))
    }

    @Test("Runtime-only fields don't affect hash")
    func hashIgnoresRuntimeFields() {
        let e1 = ServerEntry(command: "npx", args: ["-y", "test"], lifecycle: "lazy", idleTimeout: 5, debug: true)
        let e2 = ServerEntry(command: "npx", args: ["-y", "test"], lifecycle: "eager", idleTimeout: 30, debug: false)
        #expect(computeServerHash(e1) == computeServerHash(e2))
    }

    @Test("Cache validity with matching hash and fresh timestamp")
    func cacheValid() {
        let definition = ServerEntry(command: "echo")
        let entry = ServerCacheEntry(
            configHash: computeServerHash(definition),
            tools: [CachedTool(name: "test")],
            resources: [],
            cachedAt: Date().timeIntervalSince1970 * 1000
        )
        #expect(isServerCacheValid(entry, definition) == true)
    }

    @Test("Cache invalid with wrong hash")
    func cacheInvalidHash() {
        let definition = ServerEntry(command: "echo")
        let entry = ServerCacheEntry(
            configHash: "wrong-hash",
            tools: [],
            resources: [],
            cachedAt: Date().timeIntervalSince1970 * 1000
        )
        #expect(isServerCacheValid(entry, definition) == false)
    }

    @Test("Cache invalid when expired (>7 days)")
    func cacheExpired() {
        let definition = ServerEntry(command: "echo")
        let eightDaysAgo = (Date().timeIntervalSince1970 - 8 * 24 * 60 * 60) * 1000
        let entry = ServerCacheEntry(
            configHash: computeServerHash(definition),
            tools: [],
            resources: [],
            cachedAt: eightDaysAgo
        )
        #expect(isServerCacheValid(entry, definition) == false)
    }

    @Test("Reconstruct tool metadata applies prefix")
    func reconstructMetadata() {
        let entry = ServerCacheEntry(
            configHash: "abc",
            tools: [
                CachedTool(name: "query", description: "Run a query", inputSchema: AnyCodable(["type": "object"])),
                CachedTool(name: "list", description: "List items"),
            ],
            resources: [],
            cachedAt: Date().timeIntervalSince1970 * 1000
        )

        let metadata = reconstructToolMetadata(serverName: "my-server", entry: entry, prefix: "server", exposeResources: false)
        #expect(metadata.count == 2)
        #expect(metadata[0].name == "my_server_query")
        #expect(metadata[0].originalName == "query")
        #expect(metadata[0].description == "Run a query")
        #expect(metadata[1].name == "my_server_list")
    }

    @Test("Reconstruct includes resources when enabled")
    func reconstructWithResources() {
        let entry = ServerCacheEntry(
            configHash: "abc",
            tools: [CachedTool(name: "tool1")],
            resources: [CachedResource(uri: "file:///test", name: "test-file", description: "A test file")],
            cachedAt: Date().timeIntervalSince1970 * 1000
        )

        let metadata = reconstructToolMetadata(serverName: "srv", entry: entry, prefix: "server", exposeResources: true)
        #expect(metadata.count == 2)
        #expect(metadata[1].name == "srv_read_test_file")
        #expect(metadata[1].resourceUri == "file:///test")
    }

    @Test("cached metadata applies current include and exclude rules")
    func cachedMetadataUsesFilters() {
        let entry = ServerCacheEntry(
            configHash: "abc",
            tools: [CachedTool(name: "keep"), CachedTool(name: "remove")],
            resources: [],
            cachedAt: Date().timeIntervalSince1970 * 1000
        )
        let definition = ServerEntry(includeTools: ["keep", "remove"], excludeTools: ["remove"])
        let metadata = reconstructToolMetadata(
            serverName: "demo",
            entry: entry,
            prefix: "server",
            exposeResources: true,
            definition: definition
        )
        #expect(metadata.map(\.originalName) == ["keep"])
    }

    @Test("tool visibility settings invalidate cached metadata")
    func visibilitySettingsChangeHash() {
        let baseline = ServerEntry(command: "demo")
        let filtered = ServerEntry(command: "demo", includeTools: ["search"], excludeTools: ["delete"])
        #expect(computeServerHash(baseline) != computeServerHash(filtered))
    }

    @Test("MetadataCache Codable round-trip")
    func cacheRoundTrip() throws {
        let cache = MetadataCache(servers: [
            "test": ServerCacheEntry(
                configHash: "hash123",
                tools: [CachedTool(name: "t1", description: "Tool 1")],
                resources: [CachedResource(uri: "res://1", name: "r1")],
                cachedAt: 1000000
            ),
        ])

        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(MetadataCache.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.servers.count == 1)
        #expect(decoded.servers["test"]?.tools.count == 1)
        #expect(decoded.servers["test"]?.tools[0].name == "t1")
        #expect(decoded.servers["test"]?.resources.count == 1)
    }

    @Test("legacy cache entries decode without prompt metadata")
    func decodesLegacyEntry() throws {
        let data = Data(#"{"configHash":"hash","tools":[],"resources":[],"cachedAt":1}"#.utf8)
        let entry = try JSONDecoder().decode(ServerCacheEntry.self, from: data)
        #expect(entry.prompts.isEmpty)
    }
}
