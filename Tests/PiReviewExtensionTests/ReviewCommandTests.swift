import Foundation
import Testing
import PiReviewExtension
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// Records what the extension told the user. Select and editor prompts take the
/// scripted answers in order, then answer nothing.
private final class RecordingUI: HookUIContext {
    let notices = LockedState<[String]>([])
    let selectOptions = LockedState<[[String]]>([])
    let answers = LockedState<[String]>([])
    nonisolated init() {}

    private func nextAnswer() -> String? {
        answers.withLock { answers in
            answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    func notify(_ message: String, _ type: HookNotificationType?) {
        notices.withLock { $0.append(message) }
    }
    func select(_ title: String, _ options: [String]) async -> String? {
        selectOptions.withLock { $0.append(options) }
        return nextAnswer()
    }
    func confirm(_ title: String, _ message: String) async -> Bool { false }
    func input(_ title: String, _ placeholder: String?) async -> String? { nil }
    func editor(_ title: String, _ prefill: String?) async -> String? { nextAnswer() }
    func setStatus(_ key: String, _ text: String?) {}
    func setWorkingMessage(_ message: String?) {}
    func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    func setFooter(_ factory: HookFooterFactory?) {}
    func setTitle(_ title: String) {}
    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? { nil }
    func pasteToEditor(_ text: String) {}
    func setEditorText(_ text: String) {}
    func getEditorText() -> String { "" }
    func setEditorComponent(_ factory: HookEditorComponentFactory?) {}
    func getAllThemes() -> [HookThemeInfo] { [] }
    func getTheme(_ name: String) -> Theme? { nil }
    func setTheme(_ theme: HookThemeInput) -> HookThemeResult { HookThemeResult(success: false) }
    func getToolsExpanded() -> Bool { false }
    func setToolsExpanded(_ expanded: Bool) {}
    var theme: Theme { Theme.fallback() }
}

private func run(_ command: String, _ args: [String], in dir: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + args
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_AUTHOR_NAME"] = "t"
    environment["GIT_AUTHOR_EMAIL"] = "t@t"
    environment["GIT_COMMITTER_NAME"] = "t"
    environment["GIT_COMMITTER_EMAIL"] = "t@t"
    process.environment = environment
    try process.run()
    process.waitUntilExit()
}

private func makeRepository() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.path
    try run("git", ["init", "-q"], in: path)
    try "let a = 1\n".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
    try run("git", ["add", "-A"], in: path)
    try run("git", ["commit", "-qm", "init"], in: path)
    try "let a = 2\n".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
    return path
}

/// A session with PiReview registered, a UI attached, and a stub model that
/// records every prompt it is sent.
private struct ReviewSession {
    let session: AgentSession
    let ui: RecordingUI
    let prompts: LockedState<[String]>
}

private func startReviewSession(
    in repository: String,
    sessionManager: SessionManager? = nil,
    options: PiReviewOptions = PiReviewOptions()
) async throws -> ReviewSession {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey(model.provider, "test-key")
    let result = await createAgentSession(CreateAgentSessionOptions(
        cwd: repository,
        agentDir: repository,
        authStorage: authStorage,
        modelRegistry: ModelRegistry(authStorage),
        model: model,
        projectTrusted: false,
        noTools: .all,
        inlineExtensions: [InlineExtension(name: "review") { api in
            PiReview.register(api, options: options)
        }],
        sessionManager: sessionManager ?? SessionManager.create(repository, repository),
        settingsManager: SettingsManager.inMemory()
    ))
    let session = result.session

    let prompts = LockedState<[String]>([])
    session.agent.streamFn = { model, context, _ in
        let text = context.messages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            switch user.content {
            case .text(let text):
                return text
            case .blocks(let blocks):
                return blocks.compactMap { block in
                    guard case .text(let content) = block else { return nil }
                    return content.text
                }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
        prompts.withLock { $0.append(text) }
        let stream = AssistantMessageEventStream()
        let reply = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
            stopReason: .stop
        )
        Task {
            stream.push(.start(partial: reply))
            stream.push(.done(reason: .stop, message: reply))
        }
        return stream
    }

    let ui = RecordingUI()
    let runner = try #require(session.hookRunner)
    runner.attachUI(ui, hasUI: true)
    return ReviewSession(session: session, ui: ui, prompts: prompts)
}

/// `/review` hands its turn to a detached task, so the command returns before the
/// run exists and `waitForIdle` has nothing to wait on yet.
private func runReview(_ review: ReviewSession, _ command: String = "/review uncommitted") async throws {
    try await review.session.prompt(command)
    let deadline = Date().addingTimeInterval(10)
    while review.prompts.withLock({ $0.isEmpty }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    await review.session.waitForIdle()
}

@Suite("PiReviewExtension command")
struct ReviewCommandTests {
    /// The whole host path: `hasUI`, the git gate, origin resolution, and the
    /// `appendEntryHandler` that persists `review-session`.
    @Test("review uncommitted reaches the model in a fresh session")
    func reviewUncommittedStartsATurn() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let review = try await startReviewSession(in: repository)
        defer { review.session.dispose() }
        #expect(!PiReview.isReviewActive(in: review.session.sessionManager))

        try await runReview(review)

        #expect(PiReview.isReviewActive(in: review.session.sessionManager))
        let notices = review.ui.notices.withLock { $0 }
        #expect(!notices.contains("Failed to determine review origin."))
        #expect(!notices.contains("Not a git repository"))
        #expect(!notices.contains("Review requires interactive mode"))
        #expect(notices.contains { $0.hasPrefix("Starting review:") })

        let customTypes = review.session.sessionManager.getEntries().compactMap { entry -> String? in
            guard case .custom(let custom) = entry else { return nil }
            return custom.customType
        }
        #expect(customTypes.contains("review-session"))
        #expect(review.prompts.withLock { $0 }.contains { $0.contains("# Review Guidelines") })
    }

    /// Review state used to live in one process-wide store, so an open review in
    /// one session refused /review in every other session of the process.
    @Test("an open review in one session does not block another")
    func reviewsInSeparateSessionsAreIndependent() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let first = try await startReviewSession(in: repository)
        defer { first.session.dispose() }
        let second = try await startReviewSession(in: repository)
        defer { second.session.dispose() }

        try await runReview(first)
        try await runReview(second)

        let secondNotices = second.ui.notices.withLock { $0 }
        #expect(!secondNotices.contains { $0.hasPrefix("Already in a review") })
        #expect(secondNotices.contains { $0.hasPrefix("Starting review:") })
    }

    /// Hosts that pick or drop paths quote the ones with spaces; both the command's
    /// arguments and the folder prompt used to split them apart.
    @Test("quoted folder paths keep their spaces", arguments: [
        ("/review folder \"My Scenes\" ui", [String]()),
        ("/review", ["Review a folder (or more) (snapshot, not diff)", "\"My Scenes\"\nui"]),
    ])
    func quotedFolderPathsKeepTheirSpaces(command: String, answers: [String]) async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let review = try await startReviewSession(in: repository)
        defer { review.session.dispose() }
        review.ui.answers.withLock { $0 = answers }

        try await runReview(review, command)

        let prompts = review.prompts.withLock { $0 }
        #expect(prompts.contains { $0.contains("following paths: My Scenes, ui.") })
    }

    /// Saved custom instructions live in the session, and nothing fires to load
    /// them into a new session's store unless /review does it itself.
    @Test("saved custom review instructions reach a new session's review")
    func savedCustomInstructionsAreLoaded() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let review = try await startReviewSession(in: repository)
        defer { review.session.dispose() }
        review.session.sessionManager.appendCustomEntry(
            "review-settings",
            ["customInstructions": "Pay special attention to save-file handling."]
        )

        try await runReview(review)

        let prompts = review.prompts.withLock { $0 }
        #expect(prompts.contains { $0.contains("Pay special attention to save-file handling.") })
    }

    /// A host whose unsaved work git cannot see turns PR mode off, since it runs
    /// `gh pr checkout` in the working copy.
    @Test("pull request review can be turned off by the host")
    func pullRequestReviewCanBeDisabled() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let review = try await startReviewSession(
            in: repository,
            options: PiReviewOptions(allowsPullRequests: false)
        )
        defer { review.session.dispose() }

        try await review.session.prompt("/review pr 1")
        try await review.session.prompt("/review")

        let notices = review.ui.notices.withLock { $0 }
        #expect(notices.contains("Pull request review is not available here."))
        let presets = try #require(review.ui.selectOptions.withLock { $0 }.first)
        #expect(!presets.contains { $0.hasPrefix("Review a pull request") })
        #expect(presets.contains { $0.hasPrefix("Review uncommitted changes") })
        let description = review.session.hookRunner?.getCommand("review")?.description ?? ""
        #expect(!description.contains("PR"))
    }

    /// A session rebuilt on the same file starts with an empty store; the persisted
    /// state must still refuse a nested review.
    @Test("a session reopened mid-review refuses a nested review")
    func reopenedSessionRefusesANestedReview() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let original = try await startReviewSession(in: repository)
        try await runReview(original)
        let sessionFile = try #require(original.session.sessionFile)
        original.session.dispose()

        let reopened = try await startReviewSession(
            in: repository,
            sessionManager: SessionManager.open(sessionFile, repository)
        )
        defer { reopened.session.dispose() }
        try await reopened.session.prompt("/review uncommitted")

        let notices = reopened.ui.notices.withLock { $0 }
        #expect(notices.contains { $0.hasPrefix("Already in a review") })
    }
}
