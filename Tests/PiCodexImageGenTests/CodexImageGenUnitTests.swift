import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftCodingAgent

@Suite("PiCodexImageGen units")
struct CodexImageGenUnitTests {
    // MARK: Auth

    @Test func accountIdComesFromTheChatGPTClaim() throws {
        #expect(try extractChatGPTAccountId(makeJWT()) == testAccountId)
        #expect(throws: CodexImageError.self) { try extractChatGPTAccountId(makeJWT(accountId: nil)) }
        #expect(throws: CodexImageError.self) { try extractChatGPTAccountId(makeJWT(accountId: "bad id!")) }
        #expect(throws: CodexImageError.self) { try extractChatGPTAccountId("not-a-jwt") }
        #expect(throws: CodexImageError.self) { try extractChatGPTAccountId("a b.c.d") }
    }

    @Test func responsesURLFollowsTheCodexSuffixRule() {
        #expect(codexResponsesURL(baseUrl: nil)?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(codexResponsesURL(baseUrl: "https://chatgpt.com/backend-api/")?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(codexResponsesURL(baseUrl: "https://proxy.example/codex")?.absoluteString == "https://proxy.example/codex/responses")
        #expect(codexResponsesURL(baseUrl: "file:///etc") == nil)
    }

    @Test func onlyOpenAICodexIsAChatGPTSession() {
        #expect(isChatGPTModel(chatGPTModel))
        #expect(!isChatGPTModel(anthropicModel))
        #expect(!isChatGPTModel(nil))
    }

    @Test func protectedHeadersReplaceModelHeaders() throws {
        let auth = CodexImageAuth(token: "tok", accountId: "acct", responsesURL: URL(string: "https://x.invalid")!,
                                  extraHeaders: ["Authorization": "Bearer other", "X-Extra": "1"], routingModel: "m")
        let headers = buildCodexHeaders(auth: auth)
        #expect(headers["authorization"] == "Bearer tok")
        #expect(headers["chatgpt-account-id"] == "acct")
        #expect(headers["originator"] == "pi")
        #expect(headers["accept"] == "text/event-stream")
        #expect(headers["x-extra"] == "1")
    }

    // MARK: Request body

    @Test func requestBodyMatchesTheJSContract() {
        let body = buildCodexRequestBody(prompt: "fox", background: "transparent", model: "gpt-x", outputFormat: .webp,
                                         sessionId: "s1", inputImages: [InputImage(data: "AAAA", mimeType: "image/png")])
        #expect(body["model"] as? String == "gpt-x")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["prompt_cache_key"] as? String == "s1")
        #expect(body["parallel_tool_calls"] as? Bool == false)
        let tool = (body["tools"] as? [[String: Any]])?.first
        #expect(tool?["output_format"] as? String == "webp")
        #expect(tool?["background"] as? String == "transparent")
        let content = ((body["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]]
        #expect(content?.count == 2)
        #expect(content?.last?["image_url"] as? String == "data:image/png;base64,AAAA")
        let noBackground = buildCodexRequestBody(prompt: "p", background: nil, model: "m", outputFormat: .png, sessionId: "s", inputImages: [])
        #expect((noBackground["tools"] as? [[String: Any]])?.first?["background"] == nil)
    }

    // MARK: Retry helpers

    @Test func retryAfterIsBoundedAndParsed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(parseRetryAfter("2", now: now) == 2000)
        #expect(parseRetryAfter("120", now: now) == codexMaxRetryDelayMs)
        #expect(parseRetryAfter(nil, now: now) == nil)
        #expect(parseRetryAfter("soon", now: now) == nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(parseRetryAfter(formatter.string(from: now.addingTimeInterval(5)), now: now) == 5000)
        #expect(parseRetryAfter(formatter.string(from: now.addingTimeInterval(-5)), now: now) == nil)
        #expect(retryDelayMs(attempt: 1, retryAfter: nil, random: { 0 }) == 900)
        #expect(retryDelayMs(attempt: 3, retryAfter: nil, random: { 0.5 }) == 4000)
        #expect(retryDelayMs(attempt: 1, retryAfter: "1", random: { 0 }) == 1000)
    }

    // MARK: SSE

    private func parse(_ body: Data, headers: [String: String] = [:], progress: LockedState<[String]>? = nil) async throws -> ParsedCodexResponse {
        try await parseCodexSse(ProviderHTTPResponse(statusCode: 200, headers: headers, body: body), secrets: ["tok", testAccountId]) { stage in
            progress?.withLock { $0.append(stage) }
        }
    }

    @Test func parsesACompletedImageStream() async throws {
        let progress = LockedState<[String]>([])
        let parsed = try await parse(completedStream(extra: ["size": "1024x1024", "quality": "high", "model": "gpt-image-2",
                                                            "output_format": "png", "revised_prompt": "a fox eyJabc.def"]),
                                     headers: ["X-Request-Id": "req_1"], progress: progress)
        let image = try #require(parsed.image)
        #expect(image.id == "ig_1")
        #expect(image.result == pngBytes.base64EncodedString())
        #expect(image.reported == ReportedImage(model: "gpt-image-2", size: "1024x1024", quality: "high", outputFormat: "png"))
        #expect(image.revisedPrompt == "a fox [redacted]")
        #expect(parsed.responseId == "resp_1")
        #expect(parsed.requestId == "req_1")
        #expect(progress.withLock { $0 } == ["in_progress", "generating"])
        let usage = parsed.usage?.value as? [String: Any]
        #expect(usage?["input_tokens"] as? Int == 5)
        #expect(usage?["secret"] == nil)
    }

    @Test func imageInTheCompletedOutputIsAccepted() async throws {
        let parsed = try await parse(sse([["type": "response.completed", "response": ["id": "r", "output": [imageItem()]]]]))
        #expect(parsed.image != nil)
    }

    @Test func streamFailuresAreClassifiedAndNotRetried() async throws {
        await #expect(throws: CodexRequestError.self) {
            _ = try await parse(sse([["type": "response.failed", "response": ["error": ["code": "usage_limit_reached"]]]]))
        }
        do {
            _ = try await parse(sse([["type": "error", "error": ["code": "moderation_blocked"]]]))
            Issue.record("expected failure")
        } catch let error as CodexRequestError {
            #expect(error.diagnostics.category == .moderation)
            #expect(error.message.contains("Code: moderation_blocked."))
        }
        await #expect(throws: CodexImageError.self) { _ = try await parse(sse([["type": "response.incomplete"]])) }
        await #expect(throws: CodexImageError.self) {
            _ = try await parse(sse([["type": "response.output_item.done", "item": imageItem()]]))
        }
        await #expect(throws: CodexImageError.self) {
            _ = try await parse(sse([
                ["type": "response.output_item.done", "item": imageItem()],
                ["type": "response.output_item.done", "item": imageItem(id: "ig_2")],
            ]))
        }
        await #expect(throws: CodexImageError.self) { _ = try await parse(Data("data: {not json\n\n".utf8)) }
    }

    @Test func textOnlyResponseKeepsBoundedRedactedText() async throws {
        let parsed = try await parse(sse([
            ["type": "response.output_text.delta", "delta": "no image for tok and \(testAccountId)"],
            ["type": "response.completed", "response": ["id": "r"]],
        ]))
        #expect(parsed.image == nil)
        #expect(parsed.text == "no image for [redacted] and [redacted]")
    }

    @Test func oversizedResponsesAreRejected() async throws {
        await #expect(throws: CodexImageError.self) {
            _ = try await parse(completedStream(), headers: ["Content-Length": String(codexMaxResponseBytes + 1)])
        }
    }

    // MARK: HTTP failures

    private func failure(_ status: Int, _ body: [String: Any]? = nil, headers: [String: String] = [:]) async -> HTTPFailure {
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data("<html>".utf8)
        return await codexHTTPFailure(ProviderHTTPResponse(statusCode: status, headers: headers, body: data), secrets: ["tok"])
    }

    @Test func httpFailuresDecideRetry() async {
        #expect(await failure(429).retry)
        #expect(await failure(503).retry)
        #expect(!(await failure(429, ["error": ["code": "insufficient_quota"]]).retry))
        #expect(await failure(429, ["error": ["code": "insufficient_quota"]]).diagnostics.category == .quota)
        #expect(!(await failure(400).retry))
        #expect(await failure(401).diagnostics.category == .authentication)
        #expect(await failure(400, ["error": ["code": "unsupported_parameter"]]).diagnostics.category == .unsupportedFeature)
        let challenge = await failure(403, headers: ["cf-mitigated": "challenge"])
        #expect(!challenge.retry)
        #expect(challenge.message.contains("Cloudflare"))
        #expect(await failure(500, ["error": ["code": "tok"]]).diagnostics.code == nil)
    }

    // MARK: Image data

    @Test func imageDataIsStrictlyDecoded() throws {
        #expect(try decodeImageData(pngBytes.base64EncodedString()) == pngBytes)
        #expect(try decodeImageData(jpegBytes.base64EncodedString(), format: .jpeg) == jpegBytes)
        #expect(throws: CodexImageError.self) { try decodeImageData(pngBytes.base64EncodedString(), format: .jpeg) }
        #expect(throws: CodexImageError.self) { try decodeImageData("not base64!") }
        #expect(throws: CodexImageError.self) { try decodeImageData(Data("hello world!".utf8).base64EncodedString()) }
        #expect(try detectOutputFormat(jpegBytes) == .jpeg)
        #expect(throws: CodexImageError.self) { try detectOutputFormat(Data("GIF89a".utf8)) }
    }

    @Test func referencedImagesAreBoundedRegularFiles() throws {
        let dir = makeTempDir()
        try pngBytes.write(to: URL(fileURLWithPath: dir + "/a.png"))
        let images = try resolveInputImages(paths: ["a.png", "@a.png"], count: nil, cwd: dir, recent: [])
        #expect(images.count == 2)
        #expect(images[0] == InputImage(data: pngBytes.base64EncodedString(), mimeType: "image/png"))
        #expect(throws: CodexImageError.self) { try resolveInputImages(paths: [dir], count: nil, cwd: dir, recent: []) }
        #expect(throws: CodexImageError.self) { try resolveInputImages(paths: ["a.png"], count: 1, cwd: dir, recent: []) }
        #expect(throws: CodexImageError.self) {
            try resolveInputImages(paths: Array(repeating: "a.png", count: 6), count: nil, cwd: dir, recent: [])
        }
        try Data("text".utf8).write(to: URL(fileURLWithPath: dir + "/b.txt"))
        #expect(throws: CodexImageError.self) { try resolveInputImages(paths: ["b.txt"], count: nil, cwd: dir, recent: []) }
    }

    @Test func recentImagesAreNewestFirstThenReturnedInOrder() throws {
        let one = ImageContent(data: "1", mimeType: "image/png")
        let two = ImageContent(data: "2", mimeType: "image/png")
        let sources: [ConversationImageSource] = [
            .blocks([.image(one), .text(TextContent(text: "x"))]),
            .artifact(path: "/tmp/a.png", mimeType: "image/png"),
            .blocks([.image(two)]),
        ]
        #expect(selectRecentImages(sources, count: 2) == [.artifact(path: "/tmp/a.png", mimeType: "image/png"),
                                                          .inline(InputImage(data: "2", mimeType: "image/png"))])
        #expect(selectRecentImages(sources, count: 5).count == 3)
        #expect(throws: CodexImageError.self) {
            try resolveInputImages(paths: [], count: 2, cwd: "/", recent: [.inline(InputImage(data: "x", mimeType: "image/png"))])
        }
        let valid = [RecentImage.inline(InputImage(data: pngBytes.base64EncodedString(), mimeType: "image/png"))]
        #expect(try resolveInputImages(paths: [], count: 1, cwd: "/", recent: valid).count == 1)
    }

    // MARK: Save modes

    @Test func saveModesResolveDirectories() throws {
        #expect(try resolveSaveConfig(save: nil, saveDir: nil, cwd: "/w", sessionId: "s/1", agentDir: "/a")
                == SaveConfig(mode: .global, outputDir: "/a/generated-images/s_1"))
        #expect(try resolveSaveConfig(save: "project", saveDir: nil, cwd: "/w", sessionId: "s", agentDir: "/a")
                == SaveConfig(mode: .project, outputDir: "/w/.pi/generated-images/s"))
        #expect(try resolveSaveConfig(save: "custom", saveDir: "out", cwd: "/w", sessionId: "s", agentDir: "/a")
                == SaveConfig(mode: .custom, outputDir: "/w/out/s"))
        #expect(try resolveSaveConfig(save: "none", saveDir: nil, cwd: "/w", sessionId: "s", agentDir: "/a") == SaveConfig(mode: .none))
        #expect(throws: CodexImageError.self) { try resolveSaveConfig(save: "custom", saveDir: " ", cwd: "/w", sessionId: "s") }
        #expect(throws: CodexImageError.self) { try resolveSaveConfig(save: "cloud", saveDir: nil, cwd: "/w", sessionId: "s") }
        #expect(sanitizePathPart("a.b__", fallback: "f") == "a_b")
        #expect(sanitizePathPart("...", fallback: "f") == "f")
    }

    @Test func savedImagesNeverOverwrite() async throws {
        let dir = makeTempDir() + "/nested"
        let path = try await saveImage(pngBytes, format: .png, outputDir: dir, imageCallId: "ig_1")
        #expect(path == dir + "/ig_1.png")
        #expect(FileManager.default.contents(atPath: path) == pngBytes)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        await #expect(throws: CodexImageError.self) {
            _ = try await saveImage(pngBytes, format: .png, outputDir: dir, imageCallId: "ig_1")
        }
    }

    // MARK: Artifacts

    @Test func reservationCommitPublishAndManifest() throws {
        let root = makeTempDir()
        let reservation = try ArtifactReservation.reserve(fileExtension: "png", root: root)
        let artifact = try reservation.commit(jpegBytes, mimeType: "image/jpeg")
        #expect(artifact.path.hasSuffix("original.jpg"))
        #expect(throws: CodexImageError.self) { try reservation.commit(jpegBytes, mimeType: "image/jpeg") }
        let record = ArtifactRecord(artifact: artifact, toolCallId: "call_1")
        try reservation.publish(record)
        reservation.dispose()
        // The unused requested-format file is removed; the original stays.
        #expect(!FileManager.default.fileExists(atPath: reservation.path))
        #expect(FileManager.default.contents(atPath: artifact.path) == jpegBytes)
        let anchor = ArtifactReservationRecord(path: reservation.path, mimeType: "image/png", toolCallId: "call_1")
        #expect(readArtifactManifest(anchor) == record)
        #expect(readArtifactManifest(ArtifactReservationRecord(path: reservation.path, mimeType: "image/png", toolCallId: "other")) == nil)
    }

    @Test func uncommittedReservationIsRemoved() throws {
        let root = makeTempDir()
        let reservation = try ArtifactReservation.reserve(fileExtension: "webp", root: root)
        let dir = (reservation.path as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: dir))
        reservation.dispose()
        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(throws: CodexImageError.self) { try ArtifactReservation.reserve(fileExtension: "gif", root: root) }
    }

    @Test func artifactRecordsAreValidated() {
        let good: [String: Any] = ["artifact": ["path": "/tmp/x.png", "mimeType": "image/png", "byteCount": 10], "toolCallId": "c"]
        #expect(artifactRecord(good) != nil)
        var relative = good
        relative["artifact"] = ["path": "x.png", "mimeType": "image/png", "byteCount": 10]
        #expect(artifactRecord(relative) == nil)
        var gif = good
        gif["artifact"] = ["path": "/tmp/x.gif", "mimeType": "image/gif", "byteCount": 10]
        #expect(artifactRecord(gif) == nil)
        var huge = good
        huge["artifact"] = ["path": "/tmp/x.png", "mimeType": "image/png", "byteCount": codexMaxImageBytes + 1]
        #expect(artifactRecord(huge) == nil)
        #expect(artifactReservation(["path": "/tmp/x.png", "mimeType": "image/png", "toolCallId": "c"]) != nil)
    }

    @Test func branchArtifactsDeduplicateByPath() {
        let session = SessionManager.inMemory(makeTempDir())
        let a: [String: Any] = ["artifact": ["path": "/tmp/a.png", "mimeType": "image/png", "byteCount": 1], "toolCallId": "1"]
        let b: [String: Any] = ["artifact": ["path": "/tmp/b.png", "mimeType": "image/png", "byteCount": 1], "toolCallId": "2"]
        _ = session.appendCustomEntry(artifactEntryType, a)
        _ = session.appendCustomEntry(artifactEntryType, b)
        _ = session.appendCustomEntry(artifactEntryType, a)
        _ = session.appendCustomEntry("other", a)
        #expect(branchArtifacts(session.getBranch()).map(\.artifact.path) == ["/tmp/b.png", "/tmp/a.png"])
    }

    // MARK: Admission

    @Test func admissionLimitsActiveAndQueuedWork() async throws {
        let admission = ImageAdmission(maxActive: 1, maxQueued: 1, maxAccounts: 1)
        let first = try await admission.admit(account: "a", token: CancellationToken())
        let waiting = Task { try await admission.admit(account: "a", token: CancellationToken()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await #expect(throws: CodexImageError.self) { _ = try await admission.admit(account: "a", token: CancellationToken()) }
        await #expect(throws: CodexImageError.self) { _ = try await admission.admit(account: "b", token: CancellationToken()) }
        await first.release()
        let second = try await waiting.value
        await second.release()
        await second.release()
        #expect(await admission.accountCount == 0)
    }

    @Test func cancelledQueuedWorkLeavesTheQueue() async throws {
        let admission = ImageAdmission(maxActive: 1, maxQueued: 2)
        let first = try await admission.admit(account: "a", token: CancellationToken())
        let token = CancellationToken()
        let waiting = Task { try await admission.admit(account: "a", token: token) }
        try await Task.sleep(nanoseconds: 50_000_000)
        token.cancel()
        await #expect(throws: CodexImageError.self) { _ = try await waiting.value }
        await first.release()
        #expect(await admission.accountCount == 0)
    }
}
