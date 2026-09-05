import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func storageModel(maxTokens: Int = 8000) -> Model {
    Model(id: "summary", name: "Summary", api: .openAICompletions, provider: "summary-tests",
          baseUrl: "https://example.invalid", reasoning: true, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 32000, maxTokens: maxTokens)
}

private func storageResponse(_ reason: StopReason = .stop, tool: Bool = false) -> AssistantMessage {
    let model = storageModel()
    return AssistantMessage(content: tool ? [.toolCall(ToolCall(id: "t", name: "read", arguments: [:]))] : [.text(TextContent(text: "summary"))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 5, output: 3, cacheRead: 2, cacheWrite: 1, reasoning: 1, totalTokens: 11),
        stopReason: reason, errorMessage: reason == .error ? "provider unavailable" : nil)
}

private func storageStream(_ response: AssistantMessage) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: response.stopReason, message: response))
    stream.end(response)
    return stream
}

private func storagePreparation(split: Bool = false, history: Bool = true) -> CompactionPreparation {
    CompactionPreparation(firstKeptEntryId: "kept", messagesToSummarize: history ? [.user(UserMessage(content: .text("history")))] : [],
        turnPrefixMessages: split ? [.user(UserMessage(content: .text("prefix")))] : [], isSplitTurn: split,
        tokensBefore: 500, fileOps: createFileOps(), settings: CompactionSettings(enabled: true, reserveTokens: 10000, keepRecentTokens: 100))
}

private func storageTempDir() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-storage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite struct StorageAndSummaryV085Tests {
    @Test func failureReasons() {
        #expect(getSummarizationFailure(storageResponse(.error), label: "Branch summarization") == "Branch summarization failed: provider unavailable")
        #expect(getSummarizationFailure(storageResponse(.length), label: "Summarization") == "Summarization failed: generation hit the token cap and the summary is incomplete")
        #expect(getSummarizationFailure(storageResponse(), label: "Summarization") == nil)
    }

    @Test(arguments: [false, true]) func rejectPartialHistoryAndPrefix(split: Bool) async throws {
        do {
            _ = try await compact(storagePreparation(split: split, history: !split), storageModel(), "key",
                streamFn: { _, _, _ in storageStream(storageResponse(.length)) })
            Issue.record("A partial summary must fail")
        } catch {
            let label = split ? "Turn prefix summarization" : "Summarization"
            #expect(error.localizedDescription == "\(label) failed: generation hit the token cap and the summary is incomplete")
        }
    }

    @Test(arguments: [false, true]) func rejectSummaryToolCalls(split: Bool) async throws {
        do {
            _ = try await compact(storagePreparation(split: split, history: !split), storageModel(), "key",
                streamFn: { _, _, _ in storageStream(storageResponse(.toolUse, tool: true)) })
            Issue.record("A summary tool call must fail")
        } catch {
            #expect(error.localizedDescription == "\(split ? "Turn prefix summarization" : "Summarization") attempted to call a tool")
        }
    }

    @Test func standaloneRoutingThinkingAndSplitUsage() async throws {
        let calls = LockedState<[(Context, SimpleStreamOptions)]>([])
        let result = try await compact(storagePreparation(split: true), storageModel(maxTokens: 3000), "key",
            thinkingLevel: .medium,
            streamFn: { _, context, options in
                calls.withLock { $0.append((context, options)) }
                return storageStream(storageResponse())
            }, sessionId: "caller-route")
        let captured = calls.withLock { $0 }
        #expect(captured.count == 2)
        for (context, options) in captured {
            #expect(context.tools == nil || context.tools?.isEmpty == true)
            #expect(context.messages.count == 1)
            #expect(options.sessionId == "caller-route")
            #expect(options.cacheRetention == CacheRetention.none)
            #expect(options.toolChoice == nil)
            #expect(options.maxTokens == 3000)
            #expect(options.reasoning == .medium)
        }
        #expect(result.usage?.totalTokens == 22)
        #expect(result.usage?.reasoning == 2)
        #expect(result.summary.contains("**Turn Context (split turn):**"))
    }

    @Test func preservesCallerToolChoiceAndAllocatesRouting() async throws {
        let captured = LockedState<[SimpleStreamOptions]>([])
        let stream: StreamFn = { _, _, options in
            captured.withLock { $0.append(options) }
            return storageStream(storageResponse())
        }
        for _ in 0..<2 {
            _ = try await completeSummarization(model: storageModel(), context: Context(messages: []),
                options: SimpleStreamOptions(cacheRetention: .long, toolChoice: .auto), streamFn: stream)
        }
        let options = captured.withLock { $0 }
        #expect(options[0].sessionId != options[1].sessionId)
        #expect(options.allSatisfy { $0.sessionId != nil && $0.cacheRetention == CacheRetention.none })
        if case .auto = options[0].toolChoice {} else { Issue.record("Caller tool choice was changed") }
    }

    @Test func summaryRetriesUseSameRouting() async throws {
        let optionsSeen = LockedState<[SimpleStreamOptions]>([])
        let response = try await completeSummarization(model: storageModel(), context: Context(messages: []), options: SimpleStreamOptions(),
            streamFn: { _, _, options in
                let count = optionsSeen.withLock { $0.append(options); return $0.count }
                var response = storageResponse(count == 1 ? .error : .stop)
                if count == 1 { response.errorMessage = "503 service unavailable" }
                return storageStream(response)
            }, retry: RetryPolicy(enabled: true, maxRetries: 1, baseDelayMs: 0))
        #expect(response.stopReason == .stop)
        let seen = optionsSeen.withLock { $0 }
        #expect(seen.count == 2)
        #expect(seen.first?.sessionId == seen.last?.sessionId)
    }

    @Test(arguments: [0, 1000, 8000]) func branchOutputCap(limit: Int) async throws {
        let session = SessionManager.inMemory()
        session.appendMessage(.user(UserMessage(content: .text("branch"))))
        let seen = LockedState<SimpleStreamOptions?>(nil)
        let result = await generateBranchSummary(session.getEntries(), GenerateBranchSummaryOptions(
            model: storageModel(maxTokens: limit), apiKey: "key", signal: nil, customInstructions: nil, reserveTokens: 20000,
            streamFn: { _, _, options in seen.withLock { $0 = options }; return storageStream(storageResponse()) }))
        #expect(result.summary == "summary")
        #expect(seen.withLock { $0?.maxTokens } == (limit > 0 ? min(4096, limit) : 4096))
        #expect(seen.withLock { $0?.toolChoice } == nil)
    }

    @Test(arguments: [StopReason.length, .toolUse, .aborted]) func rejectsInvalidBranch(reason: StopReason) async throws {
        let session = SessionManager.inMemory()
        session.appendMessage(.user(UserMessage(content: .text("branch"))))
        let result = await generateBranchSummary(session.getEntries(), GenerateBranchSummaryOptions(
            model: storageModel(), apiKey: "key", signal: nil, customInstructions: nil, reserveTokens: nil,
            streamFn: { _, _, _ in storageStream(storageResponse(reason, tool: reason == .toolUse)) }))
        #expect(result.summary == nil)
        if reason == .aborted { #expect(result.aborted == true) }
        else { #expect(result.error?.hasPrefix("Branch summarization") == true) }
    }

    @Test func preloadedTreeIdentityLabelsAndAppend() throws {
        let source = SessionManager.inMemory("/workspace", options: NewSessionOptions(id: "identity"))
        let root = source.appendMessage(.user(UserMessage(content: .text("root"))))
        let left = source.appendMessage(.user(UserMessage(content: .text("left"))))
        try source.branch(root)
        let right = source.appendMessage(.user(UserMessage(content: .text("right"))))
        let label = try source.appendLabelChange(right, "marked")
        let entries = [FileEntry.session(try #require(source.getHeader()))] + source.getEntries().map(FileEntry.entry)
        let restored = SessionManager.inMemory("/other", entries: entries)
        #expect(restored.getSessionId() == "identity")
        #expect(restored.getEntries().map(\.id) == source.getEntries().map(\.id))
        #expect(restored.getBranch(left).map(\.id) == [root, left])
        #expect(restored.getLabel(right) == "marked")
        #expect(restored.getLeafId() == label)
        let next = restored.appendMessage(.user(UserMessage(content: .text("next"))))
        #expect(restored.getEntry(next)?.parentId == label)
        #expect(restored.getSessionFile() == nil)
    }

    @Test func headerlessOptionsAndOldMigration() throws {
        let entry = SessionEntry.message(SessionMessageEntry(id: "original", parentId: "keep", timestamp: "2026-01-01T00:00:00Z", message: .user(UserMessage(content: .text("hello")))))
        let headerless = SessionManager.inMemory("/workspace", options: NewSessionOptions(parentSession: "parent", id: "chosen"), entries: [.entry(entry)])
        #expect(headerless.getSessionId() == "chosen")
        #expect(headerless.getHeader()?.parentSession == "parent")
        #expect(headerless.getEntry("original")?.parentId == "keep")
        let old = SessionHeader(version: 1, id: "old", timestamp: "2026-01-01T00:00:00Z", cwd: "/workspace")
        let restored = SessionManager.inMemory(entries: [.entry(entry), .session(old)])
        #expect(restored.getHeader()?.version == CURRENT_SESSION_VERSION)
        #expect(restored.getSessionId() == "old")
        #expect(restored.getEntry("original")?.parentId == nil)
    }

    @Test func branchSummaryRetainsSource() throws {
        let session = SessionManager.inMemory()
        let destination = session.appendMessage(.user(UserMessage(content: .text("destination"))))
        let source = session.appendMessage(.user(UserMessage(content: .text("source"))))
        let id = try session.branchWithSummary(destination, "summary")
        guard case .branchSummary(let summary) = session.getEntry(id) else { Issue.record("Missing summary"); return }
        #expect(summary.fromId == source)
        #expect(summary.parentId == destination)
    }

    @Test(arguments: [false, true]) func forkRechainsLabelBoundary(persist: Bool) throws {
        let directory = try storageTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = persist ? SessionManager.create(directory.path, directory.path) : SessionManager.inMemory()
        let first = session.appendMessage(.user(UserMessage(content: .text("before"))))
        let boundary = try session.appendLabelChange(first, "label")
        let kept = session.appendMessage(.user(UserMessage(content: .text("kept"))))
        let compact = session.appendCompaction("summary", boundary, 500)
        _ = session.createBranchedSession(compact)
        guard case .compaction(let entry) = session.getEntry(compact) else { Issue.record("Missing compaction"); return }
        #expect(entry.firstKeptEntryId == kept)
        #expect(session.getEntry(kept)?.parentId == first)
        #expect(session.buildSessionContext().messages.count == 2)
        if persist {
            let reopened = try SessionManager.openValidated(try #require(session.getSessionFile()))
            #expect(reopened.buildSessionContext().messages.count == 2)
        }
    }

    @Test(arguments: ["", "{torn"], [false, true]) func repairsFinalNewline(fragment: String, bom: Bool) throws {
        let directory = try storageTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.jsonl")
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"test\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"cwd\":\"/test\"}"
        let input = (bom ? "\u{FEFF}" : "") + header + (fragment.isEmpty ? "" : "\n" + fragment)
        try input.write(to: path, atomically: false, encoding: .utf8)
        #expect(loadEntriesFromFile(path.path).count == 1)
        #expect(try Data(contentsOf: path) == Data((input + "\n").utf8))
        #expect(isValidSessionFile(path.path))
    }

    @Test func invalidSessionDoesNotChangeFile() throws {
        let directory = try storageTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("invalid.jsonl")
        let input = "{\"hello\":\"world\"}"
        try input.write(to: path, atomically: false, encoding: .utf8)
        #expect(loadEntriesFromFile(path.path).isEmpty)
        do {
            _ = try SessionManager.openValidated(path.path)
            Issue.record("Invalid file must throw")
        } catch {
            #expect(error.localizedDescription == "Session file is not a valid \(APP_NAME) session: \(path.path)")
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == input)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["invalid.jsonl"])
    }

    @Test func exportsOnlyBranchAndTrailingRecordsWithoutMutation() throws {
        let directory = try storageTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionManager.inMemory("/workspace", options: NewSessionOptions(id: "export-id"))
        let root = session.appendMessage(.user(UserMessage(content: .text("root"))))
        _ = session.appendMessage(.user(UserMessage(content: .text("not exported"))))
        try session.branch(root)
        let leaf = session.appendMessage(.user(UserMessage(content: .text("leaf"))))
        let snapshot = session.getEntries().map(\.id)
        let path = try exportSessionToJsonl(session, outputPath: directory.appendingPathComponent("nested/export.jsonl").path) { parent, timestamp in
            #expect(parent == leaf)
            return [["type": AnyCodable("custom"), "id": AnyCodable("export-only"), "parentId": AnyCodable(try #require(parent)), "timestamp": AnyCodable(timestamp), "customType": AnyCodable("share")]]
        }
        let loaded = try SessionManager.openValidated(path)
        #expect(loaded.getSessionId() == "export-id")
        #expect(loaded.getEntries().map(\.id) == [root, leaf, "export-only"])
        #expect(loaded.getEntry(root)?.parentId == nil)
        #expect(loaded.getEntry(leaf)?.parentId == root)
        #expect(session.getEntries().map(\.id) == snapshot)
        #expect(session.getLeafId() == leaf)
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasSuffix("\n"))
    }

    @Test func summaryUsageSurvivesExport() throws {
        let directory = try storageTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionManager.inMemory()
        let kept = session.appendMessage(.user(UserMessage(content: .text("kept"))))
        let usage = storageResponse().usage
        let compactID = session.appendCompaction("summary", kept, 50, usage: usage)
        let branchID = session.appendBranchSummary(kept, "branch", usage: usage)
        let path = try exportSessionToJsonl(session, outputPath: directory.appendingPathComponent("usage.jsonl").path)
        let loaded = try SessionManager.openValidated(path)
        guard case .compaction(let compaction) = loaded.getEntry(compactID),
              case .branchSummary(let branch) = loaded.getEntry(branchID) else {
            Issue.record("Missing summaries"); return
        }
        #expect(compaction.usage?.totalTokens == 11)
        #expect(branch.usage?.reasoning == 1)
    }

    @Test func branchMessageMayOmitSource() {
        let message = makeBranchSummaryAgentMessage(BranchSummaryMessage(summary: "summary", timestamp: 1))
        guard case .custom(let custom) = message else { Issue.record("Missing custom message"); return }
        let payload = custom.payload?.value as? [String: Any]
        #expect(payload?["fromId"] == nil)
        #expect(convertToLlm([message]).count == 1)
    }
}
