import Foundation
import PiSwiftAI

public let DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000

public struct CompactionSettingsOverrides: Sendable {
    public var enabled: Bool?
    public var reserveTokens: Int?
    public var keepRecentTokens: Int?

    public init(enabled: Bool? = nil, reserveTokens: Int? = nil, keepRecentTokens: Int? = nil) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
    }
}

public struct BranchSummarySettings: Sendable {
    public var reserveTokens: Int?
    public var skipPrompt: Bool?
}

public struct ProviderRetrySettings: Sendable {
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?

    public init(timeoutMs: Int? = nil, maxRetries: Int? = nil, maxRetryDelayMs: Int? = nil) {
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
    }
}

public struct RetrySettings: Sendable {
    public var enabled: Bool?
    public var maxRetries: Int?
    public var baseDelayMs: Int?
    public var provider: ProviderRetrySettings?

    public init(
        enabled: Bool? = nil,
        maxRetries: Int? = nil,
        baseDelayMs: Int? = nil,
        provider: ProviderRetrySettings? = nil
    ) {
        self.enabled = enabled
        self.maxRetries = maxRetries
        self.baseDelayMs = baseDelayMs
        self.provider = provider
    }
}

public struct SkillsSettings: Sendable {
    public init(
        enabled: Bool? = nil,
        enableCodexUser: Bool? = nil,
        enableClaudeUser: Bool? = nil,
        enableClaudeProject: Bool? = nil,
        enablePiUser: Bool? = nil,
        enablePiProject: Bool? = nil,
        enableSkillCommands: Bool? = nil,
        customDirectories: [String]? = nil,
        ignoredSkills: [String]? = nil,
        includeSkills: [String]? = nil
    ) {
        self.enabled = enabled
        self.enableCodexUser = enableCodexUser
        self.enableClaudeUser = enableClaudeUser
        self.enableClaudeProject = enableClaudeProject
        self.enablePiUser = enablePiUser
        self.enablePiProject = enablePiProject
        self.enableSkillCommands = enableSkillCommands
        self.customDirectories = customDirectories
        self.ignoredSkills = ignoredSkills
        self.includeSkills = includeSkills
    }
    
    public var enabled: Bool?
    public var enableCodexUser: Bool?
    public var enableClaudeUser: Bool?
    public var enableClaudeProject: Bool?
    public var enablePiUser: Bool?
    public var enablePiProject: Bool?
    public var enableSkillCommands: Bool?
    public var customDirectories: [String]?
    public var ignoredSkills: [String]?
    public var includeSkills: [String]?
}

public struct TerminalSettings: Sendable {
    public var showImages: Bool?
    /// v0.68.1: configurable inline tool image width (cells). Default 60.
    public var imageWidthCells: Int?
    /// v0.70.0: opt-in OSC 9;4 progress indicator during streaming/compaction.
    /// Default `false` — emit progress only when explicitly enabled.
    public var showTerminalProgress: Bool?
}

/// v0.70.3: opt-out warnings (currently used for the Anthropic third-party-usage billing
/// notice on subscription auth).
public struct WarningsSettings: Sendable {
    public var anthropicExtraUsage: Bool?

    public init(anthropicExtraUsage: Bool? = nil) {
        self.anthropicExtraUsage = anthropicExtraUsage
    }
}

public struct ImageSettings: Sendable {
    public var autoResize: Bool?
    public var blockImages: Bool?
}

public struct MarkdownSettings: Sendable {
    public var codeBlockIndent: String?
    public var mermaidEnabled: Bool?
    public var mermaidRenderWhileStreaming: Bool?
    public var latexEnabled: Bool?

    public init(
        codeBlockIndent: String? = nil,
        mermaidEnabled: Bool? = nil,
        mermaidRenderWhileStreaming: Bool? = nil,
        latexEnabled: Bool? = nil
    ) {
        self.codeBlockIndent = codeBlockIndent
        self.mermaidEnabled = mermaidEnabled
        self.mermaidRenderWhileStreaming = mermaidRenderWhileStreaming
        self.latexEnabled = latexEnabled
    }
}

public enum DefaultProjectTrust: String, Sendable {
    case ask
    case always
    case never
}

public struct ThinkingBudgetsSettings: Sendable {
    public var minimal: Int?
    public var low: Int?
    public var medium: Int?
    public var high: Int?

    public init(minimal: Int? = nil, low: Int? = nil, medium: Int? = nil, high: Int? = nil) {
        self.minimal = minimal
        self.low = low
        self.medium = medium
        self.high = high
    }
}

public struct Settings: Sendable {
    public var lastChangelogVersion: String?
    public var defaultProvider: String?
    public var defaultModel: String?
    public var defaultThinkingLevel: String?
    public var transport: Transport?
    public var steeringMode: String?
    public var followUpMode: String?
    public var theme: String?
    public var defaultProjectTrust: DefaultProjectTrust?
    public var compaction: CompactionSettingsOverrides?
    public var branchSummary: BranchSummarySettings?
    public var retry: RetrySettings?
    public var hideThinkingBlock: Bool?
    /// Whether significant prompt-cache misses should be surfaced by a presentation layer.
    /// Defaults to false.
    public var showCacheMissNotices: Bool?
    public var shellPath: String?
    public var shellCommandPrefix: String?
    public var quietStartup: Bool?
    public var collapseChangelog: Bool?
    public var packages: [PackageSource]?
    public var extensions: [String]?
    public var skillPaths: [String]?
    public var prompts: [String]?
    public var themes: [String]?
    public var enableSkillCommands: Bool?
    public var hooks: [String]?
    public var customTools: [String]?
    public var skills: SkillsSettings?
    public var terminal: TerminalSettings?
    public var images: ImageSettings?
    public var enabledModels: [String]?
    public var doubleEscapeAction: String?
    public var editorPaddingX: Int?
    public var outputPad: Int?
    public var autocompleteMaxVisible: Int?
    public var showHardwareCursor: Bool?
    public var tuiMode: String?
    public var fullscreenScrollbar: String?
    public var mouseWheelStep: Int?
    public var markdown: MarkdownSettings?
    public var thinkingBudgets: ThinkingBudgetsSettings?
    public var treeFilterMode: String?
    public var promptSnippetsEnabled: Bool?
    /// v0.79.4: per-project trust decisions keyed by standardized cwd path.
    public var projectTrust: [String: Bool]?
    /// v0.70.3: per-warning opt-outs. Currently controls the Anthropic third-party-usage
    /// billing notice when subscription auth is active.
    public var warnings: WarningsSettings?
    /// v0.67.1: install telemetry ping. Defaults to true (interactive mode); set false to
    /// disable. Also disabled by env vars `PI_OFFLINE=1` / `PI_TELEMETRY=0`.
    public var enableInstallTelemetry: Bool?
    /// Opt-in analytics data sharing. Defaults to false; enabling generates a tracking ID.
    public var enableAnalytics: Bool?
    public var trackingId: String?
    /// v0.63.0 / v0.68.1: portable session directory. `~` expansion handled at resolution time.
    public var sessionDir: String?
    /// v0.62.0: command used for npm package lookup/install operations. Argv-style (e.g.,
    /// `["mise", "exec", "node@20", "--", "npm"]`). When nil, falls back to `["npm"]`.
    /// Lets users wrap npm with version managers (mise/nvm/asdf/pnpm) without breaking
    /// pi's package install flow.
    public var npmCommand: [String]?
    /// HTTP header/body idle timeout in milliseconds. Defaults to 300 seconds; 0 disables it.
    public var httpIdleTimeoutMs: Int?
    /// WebSocket connect/open handshake timeout in milliseconds. Nil uses provider defaults.
    public var websocketConnectTimeoutMs: Int?

    public init() {}
}

public struct SettingsError: Sendable {
    public var scope: String
    public var message: String

    public init(scope: String, message: String) {
        self.scope = scope
        self.message = message
    }
}

public final class SettingsManager: Sendable {
    private struct State: Sendable {
        var settingsPath: String?
        var projectSettingsPath: String?
        var globalSettings: Settings
        var projectSettings: Settings
        var settings: Settings
        var inMemoryProjectSettings: Settings
        var modifiedFields: Set<String>
        var modifiedNestedFields: [String: Set<String>]
        var modifiedProjectFields: Set<String>
        var modifiedProjectNestedFields: [String: Set<String>]
        var globalSettingsLoadError: String?
        var projectSettingsLoadError: String?
        var errors: [SettingsError]
    }

    private let state: LockedState<State>
    private let persist: Bool
    private let writeQueue = DispatchQueue(label: "pi.settings.write.queue")

    private var settingsPath: String? {
        get { state.withLock { $0.settingsPath } }
        set { state.withLock { $0.settingsPath = newValue } }
    }

    private var projectSettingsPath: String? {
        get { state.withLock { $0.projectSettingsPath } }
        set { state.withLock { $0.projectSettingsPath = newValue } }
    }

    private var globalSettings: Settings {
        get { state.withLock { $0.globalSettings } }
        set { state.withLock { $0.globalSettings = newValue } }
    }

    private var settings: Settings {
        get { state.withLock { $0.settings } }
        set { state.withLock { $0.settings = newValue } }
    }

    private var inMemoryProjectSettings: Settings {
        get { state.withLock { $0.inMemoryProjectSettings } }
        set { state.withLock { $0.inMemoryProjectSettings = newValue } }
    }

    private var modifiedFields: Set<String> {
        get { state.withLock { $0.modifiedFields } }
        set { state.withLock { $0.modifiedFields = newValue } }
    }

    private var modifiedNestedFields: [String: Set<String>] {
        get { state.withLock { $0.modifiedNestedFields } }
        set { state.withLock { $0.modifiedNestedFields = newValue } }
    }

    private var modifiedProjectFields: Set<String> {
        get { state.withLock { $0.modifiedProjectFields } }
        set { state.withLock { $0.modifiedProjectFields = newValue } }
    }

    private var modifiedProjectNestedFields: [String: Set<String>] {
        get { state.withLock { $0.modifiedProjectNestedFields } }
        set { state.withLock { $0.modifiedProjectNestedFields = newValue } }
    }

    private var globalSettingsLoadError: String? {
        get { state.withLock { $0.globalSettingsLoadError } }
        set { state.withLock { $0.globalSettingsLoadError = newValue } }
    }

    private var projectSettingsLoadError: String? {
        get { state.withLock { $0.projectSettingsLoadError } }
        set { state.withLock { $0.projectSettingsLoadError = newValue } }
    }

    private var errors: [SettingsError] {
        get { state.withLock { $0.errors } }
        set { state.withLock { $0.errors = newValue } }
    }

    private var projectSettings: Settings {
        get { state.withLock { $0.projectSettings } }
        set { state.withLock { $0.projectSettings = newValue } }
    }

    private init(
        settingsPath: String?,
        projectSettingsPath: String?,
        initial: Settings,
        initialProject: Settings,
        persist: Bool,
        loadError: String? = nil,
        projectLoadError: String? = nil,
        initialErrors: [SettingsError] = []
    ) {
        self.persist = persist
        self.state = LockedState(State(
            settingsPath: settingsPath,
            projectSettingsPath: projectSettingsPath,
            globalSettings: initial,
            projectSettings: initialProject,
            settings: initial,
            inMemoryProjectSettings: Settings(),
            modifiedFields: Set<String>(),
            modifiedNestedFields: [:],
            modifiedProjectFields: Set<String>(),
            modifiedProjectNestedFields: [:],
            globalSettingsLoadError: loadError,
            projectSettingsLoadError: projectLoadError,
            errors: initialErrors
        ))
        self.settings = mergeSettings(globalSettings, initialProject)
    }

    public static func create(
        _ cwd: String = FileManager.default.currentDirectoryPath,
        _ agentDir: String = getAgentDir(),
        projectTrusted: Bool = true
    ) -> SettingsManager {
        let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
        let projectSettingsPath = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json").path
        var loadError: String?
        var projectLoadError: String?
        var errors: [SettingsError] = []
        let globalSettings: Settings
        do {
            globalSettings = try loadFromFile(settingsPath)
        } catch {
            loadError = error.localizedDescription
            errors.append(SettingsError(scope: "global", message: error.localizedDescription))
            globalSettings = Settings()
        }
        let projectSettings: Settings
        if projectTrusted {
            do {
                projectSettings = try loadFromFile(projectSettingsPath)
            } catch {
                projectLoadError = error.localizedDescription
                errors.append(SettingsError(scope: "project", message: error.localizedDescription))
                projectSettings = Settings()
            }
        } else {
            projectSettings = Settings()
        }
        return SettingsManager(
            settingsPath: settingsPath,
            projectSettingsPath: projectSettingsPath,
            initial: globalSettings,
            initialProject: projectSettings,
            persist: true,
            loadError: loadError,
            projectLoadError: projectLoadError,
            initialErrors: errors
        )
    }

    public static func inMemory(_ settings: Settings = Settings()) -> SettingsManager {
        SettingsManager(settingsPath: nil, projectSettingsPath: nil, initial: settings, initialProject: Settings(), persist: false)
    }

    public func applyOverrides(_ overrides: Settings) {
        settings = mergeSettings(settings, overrides)
    }

    private func markModified(_ field: String, _ nestedKey: String? = nil) {
        state.withLock { state in
            state.modifiedFields.insert(field)
            if let nestedKey {
                var nested = state.modifiedNestedFields[field] ?? Set<String>()
                nested.insert(nestedKey)
                state.modifiedNestedFields[field] = nested
            }
        }
    }

    private func markProjectModified(_ field: String, _ nestedKey: String? = nil) {
        state.withLock { state in
            state.modifiedProjectFields.insert(field)
            if let nestedKey {
                var nested = state.modifiedProjectNestedFields[field] ?? Set<String>()
                nested.insert(nestedKey)
                state.modifiedProjectNestedFields[field] = nested
            }
        }
    }

    public func getGlobalSettings() -> Settings {
        globalSettings
    }

    public func getProjectSettings() -> Settings {
        projectSettings
    }

    public func getProjectTrust(_ cwd: String) -> Bool? {
        guard let trust = globalSettings.projectTrust else { return nil }
        var currentPath = normalizeProjectTrustPath(cwd)
        while true {
            if let decision = trust[currentPath] {
                return decision
            }
            let parentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
            if parentPath == currentPath {
                return nil
            }
            currentPath = parentPath
        }
    }

    public func setProjectTrust(_ cwd: String, trusted: Bool) {
        var trust = globalSettings.projectTrust ?? [:]
        trust[normalizeProjectTrustPath(cwd)] = trusted
        globalSettings.projectTrust = trust
        markModified("projectTrust")
        save()
    }

    public func clearProjectTrust(_ cwd: String) {
        var trust = globalSettings.projectTrust ?? [:]
        trust.removeValue(forKey: normalizeProjectTrustPath(cwd))
        globalSettings.projectTrust = trust.isEmpty ? nil : trust
        markModified("projectTrust")
        save()
    }

    public func applyProjectTrustUpdates(_ updates: [ProjectTrustUpdate]) {
        guard !updates.isEmpty else { return }
        var trust = globalSettings.projectTrust ?? [:]
        for update in updates {
            let path = normalizeProjectTrustPath(update.path)
            if let decision = update.decision {
                trust[path] = decision
            } else {
                trust.removeValue(forKey: path)
            }
        }
        globalSettings.projectTrust = trust.isEmpty ? nil : trust
        markModified("projectTrust")
        save()
    }

    public func getLastChangelogVersion() -> String? {
        settings.lastChangelogVersion
    }

    public func setLastChangelogVersion(_ version: String) {
        globalSettings.lastChangelogVersion = version
        markModified("lastChangelogVersion")
        save()
    }

    public func getDefaultProvider() -> String? {
        settings.defaultProvider
    }

    public func getDefaultModel() -> String? {
        settings.defaultModel
    }

    public func setDefaultProvider(_ provider: String) {
        globalSettings.defaultProvider = provider
        markModified("defaultProvider")
        save()
    }

    public func setDefaultModel(_ model: String) {
        globalSettings.defaultModel = model
        markModified("defaultModel")
        save()
    }

    public func setDefaultModelAndProvider(_ provider: String, _ model: String) {
        globalSettings.defaultProvider = provider
        globalSettings.defaultModel = model
        markModified("defaultProvider")
        markModified("defaultModel")
        save()
    }

    public func getSteeringMode() -> String {
        settings.steeringMode ?? "one-at-a-time"
    }

    public func setSteeringMode(_ mode: String) {
        globalSettings.steeringMode = mode
        markModified("steeringMode")
        save()
    }

    public func getFollowUpMode() -> String {
        settings.followUpMode ?? "one-at-a-time"
    }

    public func setFollowUpMode(_ mode: String) {
        globalSettings.followUpMode = mode
        markModified("followUpMode")
        save()
    }

    public func getTransport() -> Transport {
        settings.transport ?? .auto
    }

    public func setTransport(_ transport: Transport) {
        globalSettings.transport = transport
        markModified("transport")
        save()
    }

    public func getDefaultProjectTrust() -> DefaultProjectTrust {
        globalSettings.defaultProjectTrust ?? .ask
    }

    public func setDefaultProjectTrust(_ defaultProjectTrust: DefaultProjectTrust) {
        globalSettings.defaultProjectTrust = defaultProjectTrust
        markModified("defaultProjectTrust")
        save()
    }

    public func getTheme() -> String? {
        settings.theme
    }

    public func setTheme(_ theme: String) {
        globalSettings.theme = theme
        markModified("theme")
        save()
    }

    public func getDefaultThinkingLevel() -> String? {
        settings.defaultThinkingLevel
    }

    public func setDefaultThinkingLevel(_ level: String) {
        globalSettings.defaultThinkingLevel = level
        markModified("defaultThinkingLevel")
        save()
    }

    public func getCompactionEnabled() -> Bool {
        settings.compaction?.enabled ?? true
    }

    public func setCompactionEnabled(_ enabled: Bool) {
        if globalSettings.compaction == nil { globalSettings.compaction = CompactionSettingsOverrides() }
        globalSettings.compaction?.enabled = enabled
        markModified("compaction", "enabled")
        save()
    }

    public func getCompactionSettingsOverrides() -> CompactionSettingsOverrides {
        let compaction = settings.compaction ?? CompactionSettingsOverrides()
        return CompactionSettingsOverrides(
            enabled: compaction.enabled ?? true,
            reserveTokens: compaction.reserveTokens ?? 16384,
            keepRecentTokens: compaction.keepRecentTokens ?? 20000
        )
    }

    public func getCompactionSettings() -> CompactionSettings {
        let overrides = getCompactionSettingsOverrides()
        return CompactionSettings(
            enabled: overrides.enabled ?? true,
            reserveTokens: overrides.reserveTokens ?? 16384,
            keepRecentTokens: overrides.keepRecentTokens ?? 20000
        )
    }

    public func getBranchSummarySettings() -> BranchSummarySettings {
        let branch = settings.branchSummary ?? BranchSummarySettings()
        return BranchSummarySettings(reserveTokens: branch.reserveTokens ?? 16384, skipPrompt: branch.skipPrompt)
    }

    public func getRetrySettings() -> RetrySettings {
        let retry = settings.retry ?? RetrySettings()
        return RetrySettings(
            enabled: retry.enabled ?? true,
            maxRetries: retry.maxRetries ?? 3,
            baseDelayMs: retry.baseDelayMs ?? 2000,
            provider: retry.provider
        )
    }

    public func getProviderRetrySettings() -> ProviderRetrySettings {
        let provider = settings.retry?.provider ?? ProviderRetrySettings()
        return ProviderRetrySettings(
            timeoutMs: provider.timeoutMs,
            maxRetries: provider.maxRetries,
            maxRetryDelayMs: provider.maxRetryDelayMs ?? 60_000
        )
    }

    public func setRetryEnabled(_ enabled: Bool) {
        if globalSettings.retry == nil { globalSettings.retry = RetrySettings() }
        globalSettings.retry?.enabled = enabled
        markModified("retry", "enabled")
        save()
    }

    public func getHideThinkingBlock() -> Bool {
        settings.hideThinkingBlock ?? false
    }

    public func getShowCacheMissNotices() -> Bool {
        settings.showCacheMissNotices ?? false
    }

    public func setHideThinkingBlock(_ hide: Bool) {
        globalSettings.hideThinkingBlock = hide
        markModified("hideThinkingBlock")
        save()
    }

    public func setShowCacheMissNotices(_ show: Bool) {
        globalSettings.showCacheMissNotices = show
        markModified("showCacheMissNotices")
        save()
    }

    public func getShellPath() -> String? {
        settings.shellPath.map { ($0 as NSString).expandingTildeInPath }
    }

    public func setShellPath(_ path: String?) {
        globalSettings.shellPath = path
        markModified("shellPath")
        save()
    }

    public func getShellCommandPrefix() -> String? {
        settings.shellCommandPrefix
    }

    public func setShellCommandPrefix(_ prefix: String?) {
        globalSettings.shellCommandPrefix = prefix
        markModified("shellCommandPrefix")
        save()
    }

    public func getQuietStartup() -> Bool {
        settings.quietStartup ?? false
    }

    public func setQuietStartup(_ quiet: Bool) {
        globalSettings.quietStartup = quiet
        markModified("quietStartup")
        save()
    }

    public func getCollapseChangelog() -> Bool {
        settings.collapseChangelog ?? false
    }

    public func setCollapseChangelog(_ collapse: Bool) {
        globalSettings.collapseChangelog = collapse
        markModified("collapseChangelog")
        save()
    }

    public func getHooks() -> [String] {
        settings.hooks ?? []
    }

    public func setHooks(_ paths: [String]) {
        globalSettings.hooks = paths
        markModified("hooks")
        save()
    }

    public func getCustomTools() -> [String] {
        settings.customTools ?? []
    }

    public func setCustomTools(_ paths: [String]) {
        globalSettings.customTools = paths
        markModified("customTools")
        save()
    }

    public func getPackages() -> [PackageSource] {
        settings.packages ?? []
    }

    public func setPackages(_ packages: [PackageSource]) {
        globalSettings.packages = packages
        markModified("packages")
        save()
    }

    public func setProjectPackages(_ packages: [PackageSource]) {
        var projectSettings = self.projectSettings
        projectSettings.packages = packages
        markProjectModified("packages")
        saveProjectSettings(projectSettings)
    }

    public func getExtensionPaths() -> [String] {
        settings.extensions ?? []
    }

    public func setExtensionPaths(_ paths: [String]) {
        globalSettings.extensions = paths
        markModified("extensions")
        save()
    }

    public func setProjectExtensionPaths(_ paths: [String]) {
        var projectSettings = self.projectSettings
        projectSettings.extensions = paths
        markProjectModified("extensions")
        saveProjectSettings(projectSettings)
    }

    public func getSkillPaths() -> [String] {
        settings.skillPaths ?? []
    }

    public func setSkillPaths(_ paths: [String]) {
        globalSettings.skillPaths = paths
        markModified("skills")
        save()
    }

    public func setProjectSkillPaths(_ paths: [String]) {
        var projectSettings = self.projectSettings
        projectSettings.skillPaths = paths
        markProjectModified("skills")
        saveProjectSettings(projectSettings)
    }

    public func getPromptTemplatePaths() -> [String] {
        settings.prompts ?? []
    }

    public func setPromptTemplatePaths(_ paths: [String]) {
        globalSettings.prompts = paths
        markModified("prompts")
        save()
    }

    public func setProjectPromptTemplatePaths(_ paths: [String]) {
        var projectSettings = self.projectSettings
        projectSettings.prompts = paths
        markProjectModified("prompts")
        saveProjectSettings(projectSettings)
    }

    public func getThemePaths() -> [String] {
        settings.themes ?? []
    }

    public func setThemePaths(_ paths: [String]) {
        globalSettings.themes = paths
        markModified("themes")
        save()
    }

    public func setProjectThemePaths(_ paths: [String]) {
        var projectSettings = self.projectSettings
        projectSettings.themes = paths
        markProjectModified("themes")
        saveProjectSettings(projectSettings)
    }

    public func getSkillsSettings() -> SkillsSettings {
        let skills = settings.skills ?? SkillsSettings()
        return SkillsSettings(
            enabled: skills.enabled ?? true,
            enableCodexUser: skills.enableCodexUser ?? true,
            enableClaudeUser: skills.enableClaudeUser ?? true,
            enableClaudeProject: skills.enableClaudeProject ?? true,
            enablePiUser: skills.enablePiUser ?? true,
            enablePiProject: skills.enablePiProject ?? true,
            enableSkillCommands: skills.enableSkillCommands ?? true,
            customDirectories: skills.customDirectories ?? [],
            ignoredSkills: skills.ignoredSkills ?? [],
            includeSkills: skills.includeSkills ?? []
        )
    }

    public func getEnableSkillCommands() -> Bool {
        settings.enableSkillCommands ?? settings.skills?.enableSkillCommands ?? true
    }

    public func setEnableSkillCommands(_ enabled: Bool) {
        globalSettings.enableSkillCommands = enabled
        markModified("enableSkillCommands")
        save()
    }

    public func getEnabledModels() -> [String]? {
        settings.enabledModels
    }

    public func setEnabledModels(_ patterns: [String]?) {
        globalSettings.enabledModels = patterns
        markModified("enabledModels")
        save()
    }

    public func getDoubleEscapeAction() -> String {
        settings.doubleEscapeAction ?? "tree"
    }

    public func setDoubleEscapeAction(_ action: String) {
        globalSettings.doubleEscapeAction = action
        markModified("doubleEscapeAction")
        save()
    }

    public func getAutocompleteMaxVisible() -> Int {
        settings.autocompleteMaxVisible ?? 5
    }

    public func setAutocompleteMaxVisible(_ maxVisible: Int) {
        globalSettings.autocompleteMaxVisible = max(3, min(20, maxVisible))
        markModified("autocompleteMaxVisible")
        save()
    }

    public func getEditorPaddingX() -> Int {
        settings.editorPaddingX ?? 0
    }

    public func setEditorPaddingX(_ padding: Int) {
        globalSettings.editorPaddingX = max(0, min(3, padding))
        markModified("editorPaddingX")
        save()
    }

    public func getOutputPad() -> Int {
        settings.outputPad == 0 ? 0 : 1
    }

    public func setOutputPad(_ padding: Int) {
        globalSettings.outputPad = padding == 0 ? 0 : 1
        markModified("outputPad")
        save()
    }

    public func getShowHardwareCursor() -> Bool {
        if let show = settings.showHardwareCursor { return show }
        return ProcessInfo.processInfo.environment["PI_HARDWARE_CURSOR"] == "1"
    }

    public func setShowHardwareCursor(_ enabled: Bool) {
        globalSettings.showHardwareCursor = enabled
        markModified("showHardwareCursor")
        save()
    }

    public func getTuiMode() -> String {
        settings.tuiMode == "fullscreen" ? "fullscreen" : "regular"
    }

    public func setTuiMode(_ mode: String) {
        globalSettings.tuiMode = mode == "fullscreen" ? "fullscreen" : "regular"
        markModified("tuiMode")
        save()
    }

    public func getFullscreenScrollbar() -> String {
        guard let mode = settings.fullscreenScrollbar,
              mode == "always" || mode == "hidden" else {
            return "auto"
        }
        return mode
    }

    public func setFullscreenScrollbar(_ mode: String) {
        globalSettings.fullscreenScrollbar = mode == "always" || mode == "hidden" ? mode : "auto"
        markModified("fullscreenScrollbar")
        save()
    }

    public func getMouseWheelStep() -> Int {
        max(1, settings.mouseWheelStep ?? 1)
    }

    public func setMouseWheelStep(_ step: Int) {
        globalSettings.mouseWheelStep = max(1, step)
        markModified("mouseWheelStep")
        save()
    }

    public func getCodeBlockIndent() -> String {
        settings.markdown?.codeBlockIndent ?? "  "
    }

    public func getMermaidEnabled() -> Bool {
        settings.markdown?.mermaidEnabled ?? true
    }

    public func setMermaidEnabled(_ enabled: Bool) {
        if globalSettings.markdown == nil { globalSettings.markdown = MarkdownSettings() }
        globalSettings.markdown?.mermaidEnabled = enabled
        markModified("markdown", "mermaidEnabled")
        save()
    }

    public func getMermaidRenderWhileStreaming() -> Bool {
        settings.markdown?.mermaidRenderWhileStreaming ?? true
    }

    public func setMermaidRenderWhileStreaming(_ enabled: Bool) {
        if globalSettings.markdown == nil { globalSettings.markdown = MarkdownSettings() }
        globalSettings.markdown?.mermaidRenderWhileStreaming = enabled
        markModified("markdown", "mermaidRenderWhileStreaming")
        save()
    }

    public func getLatexEnabled() -> Bool {
        settings.markdown?.latexEnabled ?? false
    }

    public func setLatexEnabled(_ enabled: Bool) {
        if globalSettings.markdown == nil { globalSettings.markdown = MarkdownSettings() }
        globalSettings.markdown?.latexEnabled = enabled
        markModified("markdown", "latexEnabled")
        save()
    }

    public func getTerminalSettings() -> TerminalSettings {
        settings.terminal ?? TerminalSettings()
    }

    public func getShowImages() -> Bool {
        settings.terminal?.showImages ?? true
    }

    public func setShowImages(_ show: Bool) {
        if globalSettings.terminal == nil { globalSettings.terminal = TerminalSettings() }
        globalSettings.terminal?.showImages = show
        markModified("terminal", "showImages")
        save()
    }

    /// v0.68.1: configurable inline tool image width (cells). Default 60.
    public func getImageWidthCells() -> Int {
        settings.terminal?.imageWidthCells ?? 60
    }

    public func setImageWidthCells(_ cells: Int) {
        if globalSettings.terminal == nil { globalSettings.terminal = TerminalSettings() }
        globalSettings.terminal?.imageWidthCells = cells
        markModified("terminal", "imageWidthCells")
        save()
    }

    /// v0.70.0: OSC 9;4 progress indicator is opt-in. Default false.
    public func getShowTerminalProgress() -> Bool {
        settings.terminal?.showTerminalProgress ?? false
    }

    public func setShowTerminalProgress(_ show: Bool) {
        if globalSettings.terminal == nil { globalSettings.terminal = TerminalSettings() }
        globalSettings.terminal?.showTerminalProgress = show
        markModified("terminal", "showTerminalProgress")
        save()
    }

    /// v0.70.3: per-warning opt-outs. Returns true (warning enabled) by default.
    public func getAnthropicExtraUsageWarning() -> Bool {
        settings.warnings?.anthropicExtraUsage ?? true
    }

    public func setAnthropicExtraUsageWarning(_ enabled: Bool) {
        if globalSettings.warnings == nil { globalSettings.warnings = WarningsSettings() }
        globalSettings.warnings?.anthropicExtraUsage = enabled
        markModified("warnings", "anthropicExtraUsage")
        save()
    }

    /// v0.67.1: install telemetry ping. Default true.
    public func getInstallTelemetryEnabled() -> Bool {
        // Env-var overrides (PI_OFFLINE, PI_TELEMETRY=0) take precedence.
        let env = ProcessInfo.processInfo.environment
        if env["PI_OFFLINE"] == "1" { return false }
        if env["PI_TELEMETRY"] == "0" { return false }
        return settings.enableInstallTelemetry ?? true
    }

    public func setInstallTelemetryEnabled(_ enabled: Bool) {
        globalSettings.enableInstallTelemetry = enabled
        markModified("enableInstallTelemetry")
        save()
    }

    public func getEnableAnalytics() -> Bool {
        settings.enableAnalytics ?? false
    }

    public func getTrackingId() -> String? {
        settings.trackingId
    }

    public func setEnableAnalytics(_ enabled: Bool) {
        globalSettings.enableAnalytics = enabled
        markModified("enableAnalytics")
        if enabled && globalSettings.trackingId == nil {
            globalSettings.trackingId = UUID().uuidString.lowercased()
            markModified("trackingId")
        }
        save()
    }

    /// v0.63.0 / v0.68.1: portable session directory. `~` expansion happens in
    /// `getDefaultSessionDir()`; this returns the raw stored value.
    public func getSessionDir() -> String? {
        settings.sessionDir
    }

    public func setSessionDir(_ dir: String?) {
        globalSettings.sessionDir = dir
        markModified("sessionDir")
        save()
    }

    /// v0.62.0: configurable npm command for package lookup/install operations.
    /// Returns nil when unset (callers should fall back to `["npm"]`).
    public func getNpmCommand() -> [String]? {
        settings.npmCommand
    }

    public func setNpmCommand(_ command: [String]?) {
        globalSettings.npmCommand = command
        markModified("npmCommand")
        save()
    }

    public func getHttpIdleTimeoutMs() -> Int {
        settings.httpIdleTimeoutMs ?? DEFAULT_HTTP_IDLE_TIMEOUT_MS
    }

    public func setHttpIdleTimeoutMs(_ timeoutMs: Int) {
        globalSettings.httpIdleTimeoutMs = max(0, timeoutMs)
        markModified("httpIdleTimeoutMs")
        save()
    }

    public func getWebSocketConnectTimeoutMs() -> Int? {
        settings.websocketConnectTimeoutMs
    }

    public func setWebSocketConnectTimeoutMs(_ timeoutMs: Int?) {
        globalSettings.websocketConnectTimeoutMs = timeoutMs.map { max(0, $0) }
        markModified("websocketConnectTimeoutMs")
        save()
    }

    public func getAutoResizeImages() -> Bool {
        settings.images?.autoResize ?? true
    }

    public func setAutoResizeImages(_ enabled: Bool) {
        if globalSettings.images == nil { globalSettings.images = ImageSettings() }
        globalSettings.images?.autoResize = enabled
        markModified("images", "autoResize")
        save()
    }

    public func getBlockImages() -> Bool {
        settings.images?.blockImages ?? false
    }

    public func setBlockImages(_ blocked: Bool) {
        if globalSettings.images == nil { globalSettings.images = ImageSettings() }
        globalSettings.images?.blockImages = blocked
        if settings.images == nil { settings.images = ImageSettings() }
        settings.images?.blockImages = blocked
        markModified("images", "blockImages")
        save()
    }

    public func getThinkingBudgets() -> ThinkingBudgets? {
        guard let budgets = settings.thinkingBudgets else { return nil }
        var result: ThinkingBudgets = [:]
        if let minimal = budgets.minimal { result[.minimal] = minimal }
        if let low = budgets.low { result[.low] = low }
        if let medium = budgets.medium { result[.medium] = medium }
        if let high = budgets.high { result[.high] = high }
        return result.isEmpty ? nil : result
    }

    private static func loadFromFile(_ path: String) throws -> Settings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return Settings()
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else {
            return Settings()
        }
        return SettingsManager.decodeSettings(dict)
    }

    private static func loadRawJson(_ path: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [:]
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [String: Any] ?? [:]
    }

    private static func parseNonNegativeMilliseconds(_ value: Any?) -> Int? {
        switch value {
        case let int as Int where int >= 0:
            return int
        case let double as Double where double.isFinite && double >= 0:
            return Int(double.rounded(.down))
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed.lowercased() == "disabled" { return 0 }
            guard let double = Double(trimmed), double.isFinite, double >= 0 else { return nil }
            return Int(double.rounded(.down))
        default:
            return nil
        }
    }

    private func loadProjectSettings() -> Settings {
        if !persist {
            return inMemoryProjectSettings
        }
        guard let projectPath = projectSettingsPath else {
            return Settings()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: projectPath)) else {
            return Settings()
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            guard let dict = json as? [String: Any] else {
                return Settings()
            }
            return SettingsManager.decodeSettings(dict)
        } catch {
            errors.append(SettingsError(scope: "project", message: error.localizedDescription))
            return Settings()
        }
    }

    private func saveProjectSettings(_ settings: Settings) {
        if !persist {
            inMemoryProjectSettings = settings
            projectSettings = settings
            self.settings = mergeSettings(globalSettings, settings)
            return
        }
        if projectSettingsLoadError != nil {
            projectSettings = settings
            self.settings = mergeSettings(globalSettings, settings)
            return
        }
        guard let projectPath = projectSettingsPath else { return }
        let dir = URL(fileURLWithPath: projectPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modifiedProjectSnapshot = modifiedProjectFields
        let modifiedProjectNestedSnapshot = modifiedProjectNestedFields

        writeQueue.sync {
            do {
                let currentJson = try SettingsManager.loadRawJson(projectPath)
                let encoded = encodeSettingsToJson(settings)
                var merged = currentJson

                for field in modifiedProjectSnapshot {
                    if let nestedKeys = modifiedProjectNestedSnapshot[field] {
                        let baseNested = merged[field] as? [String: Any] ?? [:]
                        let nextNested = encoded[field] as? [String: Any] ?? [:]
                        var updated = baseNested
                        for nestedKey in nestedKeys {
                            if let value = nextNested[nestedKey] {
                                updated[nestedKey] = value
                            } else {
                                updated.removeValue(forKey: nestedKey)
                            }
                        }
                        if updated.isEmpty {
                            merged.removeValue(forKey: field)
                        } else {
                            merged[field] = updated
                        }
                    } else if encoded.keys.contains(field) {
                        merged[field] = encoded[field]
                    } else {
                        merged.removeValue(forKey: field)
                    }
                }

                projectSettings = SettingsManager.decodeSettings(merged)
                if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: projectPath))
                }

                state.withLock { state in
                    for field in modifiedProjectSnapshot {
                        state.modifiedProjectFields.remove(field)
                        if let nestedSnapshot = modifiedProjectNestedSnapshot[field] {
                            if var currentNested = state.modifiedProjectNestedFields[field] {
                                for nested in nestedSnapshot {
                                    currentNested.remove(nested)
                                }
                                if currentNested.isEmpty {
                                    state.modifiedProjectNestedFields.removeValue(forKey: field)
                                } else {
                                    state.modifiedProjectNestedFields[field] = currentNested
                                }
                            }
                        }
                    }
                }
            } catch {
                errors.append(SettingsError(scope: "project", message: error.localizedDescription))
            }
        }

        self.settings = mergeSettings(globalSettings, projectSettings)
    }

    private static func decodeSettings(_ json: [String: Any]) -> Settings {
        var settings = Settings()
        if let queueMode = json["queueMode"] as? String, json["steeringMode"] == nil {
            settings.steeringMode = queueMode
        }
        settings.lastChangelogVersion = json["lastChangelogVersion"] as? String
        settings.defaultProvider = json["defaultProvider"] as? String
        settings.defaultModel = json["defaultModel"] as? String
        settings.defaultThinkingLevel = json["defaultThinkingLevel"] as? String
        if let transport = json["transport"] as? String, let parsed = Transport(rawValue: transport) {
            settings.transport = parsed
        } else if settings.transport == nil, let websockets = json["websockets"] as? Bool {
            settings.transport = websockets ? .websocket : .sse
        }
        settings.steeringMode = json["steeringMode"] as? String ?? settings.steeringMode
        settings.followUpMode = json["followUpMode"] as? String
        settings.theme = json["theme"] as? String
        if let trust = json["defaultProjectTrust"] as? String {
            settings.defaultProjectTrust = DefaultProjectTrust(rawValue: trust)
        }
        settings.hideThinkingBlock = json["hideThinkingBlock"] as? Bool
        settings.showCacheMissNotices = json["showCacheMissNotices"] as? Bool
        settings.shellPath = json["shellPath"] as? String
        settings.shellCommandPrefix = json["shellCommandPrefix"] as? String
        settings.quietStartup = json["quietStartup"] as? Bool
        settings.collapseChangelog = json["collapseChangelog"] as? Bool
        if let packages = json["packages"] as? [Any] {
            settings.packages = decodePackageSources(packages)
        }
        settings.extensions = json["extensions"] as? [String]
        settings.prompts = json["prompts"] as? [String]
        settings.themes = json["themes"] as? [String]
        settings.enableSkillCommands = json["enableSkillCommands"] as? Bool
        settings.hooks = json["hooks"] as? [String]
        settings.customTools = json["customTools"] as? [String]
        settings.enabledModels = json["enabledModels"] as? [String]
        settings.doubleEscapeAction = json["doubleEscapeAction"] as? String
        if let padding = json["editorPaddingX"] as? Int {
            settings.editorPaddingX = max(0, min(3, padding))
        }
        settings.outputPad = json["outputPad"] as? Int
        settings.autocompleteMaxVisible = json["autocompleteMaxVisible"] as? Int
        settings.showHardwareCursor = json["showHardwareCursor"] as? Bool
        if let mode = json["tuiMode"] as? String {
            settings.tuiMode = mode
        }
        if let mode = json["fullscreenScrollbar"] as? String {
            settings.fullscreenScrollbar = mode
        }
        if let step = json["mouseWheelStep"] as? Int {
            settings.mouseWheelStep = max(1, step)
        }
        settings.treeFilterMode = json["treeFilterMode"] as? String
        settings.promptSnippetsEnabled = json["promptSnippetsEnabled"] as? Bool
        settings.projectTrust = json["projectTrust"] as? [String: Bool]

        if let compaction = json["compaction"] as? [String: Any] {
            settings.compaction = CompactionSettingsOverrides(
                enabled: compaction["enabled"] as? Bool,
                reserveTokens: compaction["reserveTokens"] as? Int,
                keepRecentTokens: compaction["keepRecentTokens"] as? Int
            )
        }

        if let branch = json["branchSummary"] as? [String: Any] {
            settings.branchSummary = BranchSummarySettings(reserveTokens: branch["reserveTokens"] as? Int, skipPrompt: branch["skipPrompt"] as? Bool)
        }

        if let retry = json["retry"] as? [String: Any] {
            let provider = (retry["provider"] as? [String: Any]).map {
                ProviderRetrySettings(
                    timeoutMs: $0["timeoutMs"] as? Int,
                    maxRetries: $0["maxRetries"] as? Int,
                    maxRetryDelayMs: $0["maxRetryDelayMs"] as? Int
                )
            }
            settings.retry = RetrySettings(
                enabled: retry["enabled"] as? Bool,
                maxRetries: retry["maxRetries"] as? Int,
                baseDelayMs: retry["baseDelayMs"] as? Int,
                provider: provider
            )
        }

        if let skillArray = json["skills"] as? [String] {
            settings.skillPaths = skillArray
        } else if let skills = json["skills"] as? [String: Any] {
            let enableSkillCommands = skills["enableSkillCommands"] as? Bool
            if settings.enableSkillCommands == nil, let enableSkillCommands {
                settings.enableSkillCommands = enableSkillCommands
            }
            if settings.skillPaths == nil, let custom = skills["customDirectories"] as? [String], !custom.isEmpty {
                settings.skillPaths = custom
            }
            settings.skills = SkillsSettings(
                enabled: skills["enabled"] as? Bool,
                enableCodexUser: skills["enableCodexUser"] as? Bool,
                enableClaudeUser: skills["enableClaudeUser"] as? Bool,
                enableClaudeProject: skills["enableClaudeProject"] as? Bool,
                enablePiUser: skills["enablePiUser"] as? Bool,
                enablePiProject: skills["enablePiProject"] as? Bool,
                enableSkillCommands: enableSkillCommands,
                customDirectories: skills["customDirectories"] as? [String],
                ignoredSkills: skills["ignoredSkills"] as? [String],
                includeSkills: skills["includeSkills"] as? [String]
            )
        }

        if let terminal = json["terminal"] as? [String: Any] {
            settings.terminal = TerminalSettings(
                showImages: terminal["showImages"] as? Bool,
                imageWidthCells: terminal["imageWidthCells"] as? Int,
                showTerminalProgress: terminal["showTerminalProgress"] as? Bool
            )
        }

        if let warnings = json["warnings"] as? [String: Any] {
            settings.warnings = WarningsSettings(
                anthropicExtraUsage: warnings["anthropicExtraUsage"] as? Bool
            )
        }

        if let telemetry = json["enableInstallTelemetry"] as? Bool {
            settings.enableInstallTelemetry = telemetry
        }

        if let analytics = json["enableAnalytics"] as? Bool {
            settings.enableAnalytics = analytics
        }

        settings.trackingId = json["trackingId"] as? String

        if let dir = json["sessionDir"] as? String, !dir.isEmpty {
            settings.sessionDir = dir
        }

        if let npmCmd = json["npmCommand"] as? [String], !npmCmd.isEmpty {
            settings.npmCommand = npmCmd
        }

        settings.httpIdleTimeoutMs = parseNonNegativeMilliseconds(json["httpIdleTimeoutMs"])
        settings.websocketConnectTimeoutMs = parseNonNegativeMilliseconds(json["websocketConnectTimeoutMs"])

        if let markdown = json["markdown"] as? [String: Any] {
            settings.markdown = MarkdownSettings(
                codeBlockIndent: markdown["codeBlockIndent"] as? String,
                mermaidEnabled: markdown["mermaidEnabled"] as? Bool,
                mermaidRenderWhileStreaming: markdown["mermaidRenderWhileStreaming"] as? Bool,
                latexEnabled: markdown["latexEnabled"] as? Bool
            )
        }

        if let images = json["images"] as? [String: Any] {
            settings.images = ImageSettings(
                autoResize: images["autoResize"] as? Bool,
                blockImages: images["blockImages"] as? Bool
            )
        }

        if let budgets = json["thinkingBudgets"] as? [String: Any] {
            settings.thinkingBudgets = ThinkingBudgetsSettings(
                minimal: budgets["minimal"] as? Int,
                low: budgets["low"] as? Int,
                medium: budgets["medium"] as? Int,
                high: budgets["high"] as? Int
            )
        }

        return settings
    }

    private static func decodePackageSources(_ array: [Any]) -> [PackageSource] {
        array.compactMap { decodePackageSource($0) }
    }

    private static func decodePackageSource(_ value: Any) -> PackageSource? {
        if let string = value as? String {
            return .simple(string)
        }
        if let dict = value as? [String: Any], let source = dict["source"] as? String {
            return .filtered(PackageFilterSource(
                source: source,
                extensions: dict["extensions"] as? [String],
                skills: dict["skills"] as? [String],
                prompts: dict["prompts"] as? [String],
                themes: dict["themes"] as? [String]
            ))
        }
        return nil
    }

    private func save() {
        if persist, let settingsPath {
            if globalSettingsLoadError != nil {
                settings = mergeSettings(globalSettings, projectSettings)
                return
            }

            let modifiedFieldsSnapshot = modifiedFields
            let modifiedNestedSnapshot = modifiedNestedFields
            let globalSettingsSnapshot = globalSettings

            writeQueue.sync {
                do {
                    let dir = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                    let currentJson = try SettingsManager.loadRawJson(settingsPath)
                    let encoded = encodeSettingsToJson(globalSettingsSnapshot)

                    var merged = currentJson
                    for field in modifiedFieldsSnapshot {
                        if let nestedKeys = modifiedNestedSnapshot[field] {
                            let baseNested = merged[field] as? [String: Any] ?? [:]
                            let nextNested = encoded[field] as? [String: Any] ?? [:]
                            var updated = baseNested
                            for nestedKey in nestedKeys {
                                if let value = nextNested[nestedKey] {
                                    updated[nestedKey] = value
                                } else {
                                    updated.removeValue(forKey: nestedKey)
                                }
                            }
                            if updated.isEmpty {
                                merged.removeValue(forKey: field)
                            } else {
                                merged[field] = updated
                            }
                        } else {
                            if encoded.keys.contains(field) {
                                merged[field] = encoded[field]
                            } else {
                                merged.removeValue(forKey: field)
                            }
                        }
                    }

                    globalSettings = SettingsManager.decodeSettings(merged)
                    if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted]) {
                        try? data.write(to: URL(fileURLWithPath: settingsPath))
                    }

                    state.withLock { state in
                        for field in modifiedFieldsSnapshot {
                            state.modifiedFields.remove(field)
                            if let nestedSnapshot = modifiedNestedSnapshot[field] {
                                if var currentNested = state.modifiedNestedFields[field] {
                                    for nested in nestedSnapshot {
                                        currentNested.remove(nested)
                                    }
                                    if currentNested.isEmpty {
                                        state.modifiedNestedFields.removeValue(forKey: field)
                                    } else {
                                        state.modifiedNestedFields[field] = currentNested
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    errors.append(SettingsError(scope: "global", message: error.localizedDescription))
                }
            }
        }
        settings = mergeSettings(globalSettings, projectSettings)
    }

    public func drainErrors() -> [SettingsError] {
        let drained = errors
        errors = []
        return drained
    }

    public func flush() async {
        writeQueue.sync {}
    }

    private func encodeSettingsToJson(_ settings: Settings) -> [String: Any] {
        var json: [String: Any] = [:]
        json["lastChangelogVersion"] = settings.lastChangelogVersion
        json["defaultProvider"] = settings.defaultProvider
        json["defaultModel"] = settings.defaultModel
        json["defaultThinkingLevel"] = settings.defaultThinkingLevel
        json["transport"] = settings.transport?.rawValue
        json["steeringMode"] = settings.steeringMode
        json["followUpMode"] = settings.followUpMode
        json["theme"] = settings.theme
        json["defaultProjectTrust"] = settings.defaultProjectTrust?.rawValue
        json["hideThinkingBlock"] = settings.hideThinkingBlock
        json["showCacheMissNotices"] = settings.showCacheMissNotices
        json["shellPath"] = settings.shellPath
        json["shellCommandPrefix"] = settings.shellCommandPrefix
        json["quietStartup"] = settings.quietStartup
        json["collapseChangelog"] = settings.collapseChangelog
        if let packages = settings.packages {
            json["packages"] = encodePackageSources(packages)
        }
        json["extensions"] = settings.extensions
        if let skillPaths = settings.skillPaths {
            json["skills"] = skillPaths
        }
        json["prompts"] = settings.prompts
        json["themes"] = settings.themes
        json["enableSkillCommands"] = settings.enableSkillCommands
        json["hooks"] = settings.hooks
        json["customTools"] = settings.customTools
        json["enabledModels"] = settings.enabledModels
        json["doubleEscapeAction"] = settings.doubleEscapeAction
        json["editorPaddingX"] = settings.editorPaddingX
        json["outputPad"] = settings.outputPad
        json["autocompleteMaxVisible"] = settings.autocompleteMaxVisible
        json["showHardwareCursor"] = settings.showHardwareCursor
        json["tuiMode"] = settings.tuiMode
        json["fullscreenScrollbar"] = settings.fullscreenScrollbar
        json["mouseWheelStep"] = settings.mouseWheelStep
        json["treeFilterMode"] = settings.treeFilterMode
        json["promptSnippetsEnabled"] = settings.promptSnippetsEnabled
        json["projectTrust"] = settings.projectTrust

        if let compaction = settings.compaction {
            json["compaction"] = [
                "enabled": compaction.enabled as Any,
                "reserveTokens": compaction.reserveTokens as Any,
                "keepRecentTokens": compaction.keepRecentTokens as Any,
            ]
        }

        if let branch = settings.branchSummary {
            json["branchSummary"] = [
                "reserveTokens": branch.reserveTokens as Any,
                "skipPrompt": branch.skipPrompt as Any,
            ]
        }

        if let retry = settings.retry {
            var retryJson: [String: Any] = [
                "enabled": retry.enabled as Any,
                "maxRetries": retry.maxRetries as Any,
                "baseDelayMs": retry.baseDelayMs as Any,
            ]
            if let provider = retry.provider {
                retryJson["provider"] = [
                    "timeoutMs": provider.timeoutMs as Any,
                    "maxRetries": provider.maxRetries as Any,
                    "maxRetryDelayMs": provider.maxRetryDelayMs as Any,
                ]
            }
            json["retry"] = retryJson
        }

        if settings.skillPaths == nil, let skills = settings.skills {
            json["skills"] = [
                "enabled": skills.enabled as Any,
                "enableCodexUser": skills.enableCodexUser as Any,
                "enableClaudeUser": skills.enableClaudeUser as Any,
                "enableClaudeProject": skills.enableClaudeProject as Any,
                "enablePiUser": skills.enablePiUser as Any,
                "enablePiProject": skills.enablePiProject as Any,
                "enableSkillCommands": skills.enableSkillCommands as Any,
                "customDirectories": skills.customDirectories as Any,
                "ignoredSkills": skills.ignoredSkills as Any,
                "includeSkills": skills.includeSkills as Any,
            ]
        }

        if let terminal = settings.terminal {
            var entry: [String: Any] = ["showImages": terminal.showImages as Any]
            if let widthCells = terminal.imageWidthCells {
                entry["imageWidthCells"] = widthCells
            }
            if let progress = terminal.showTerminalProgress {
                entry["showTerminalProgress"] = progress
            }
            json["terminal"] = entry
        }

        if let warnings = settings.warnings {
            json["warnings"] = [
                "anthropicExtraUsage": warnings.anthropicExtraUsage as Any,
            ]
        }

        if let telemetry = settings.enableInstallTelemetry {
            json["enableInstallTelemetry"] = telemetry
        }

        if let analytics = settings.enableAnalytics {
            json["enableAnalytics"] = analytics
        }

        if let trackingId = settings.trackingId {
            json["trackingId"] = trackingId
        }

        if let dir = settings.sessionDir {
            json["sessionDir"] = dir
        }

        if let npmCmd = settings.npmCommand {
            json["npmCommand"] = npmCmd
        }

        if let timeout = settings.httpIdleTimeoutMs {
            json["httpIdleTimeoutMs"] = timeout
        }

        if let timeout = settings.websocketConnectTimeoutMs {
            json["websocketConnectTimeoutMs"] = timeout
        }

        if let markdown = settings.markdown {
            json["markdown"] = [
                "codeBlockIndent": markdown.codeBlockIndent as Any,
                "mermaidEnabled": markdown.mermaidEnabled as Any,
                "mermaidRenderWhileStreaming": markdown.mermaidRenderWhileStreaming as Any,
                "latexEnabled": markdown.latexEnabled as Any,
            ]
        }

        if let images = settings.images {
            json["images"] = [
                "autoResize": images.autoResize as Any,
                "blockImages": images.blockImages as Any,
            ]
        }

        if let budgets = settings.thinkingBudgets {
            json["thinkingBudgets"] = [
                "minimal": budgets.minimal as Any,
                "low": budgets.low as Any,
                "medium": budgets.medium as Any,
                "high": budgets.high as Any,
            ]
        }

        return json
    }

    private func encodePackageSources(_ packages: [PackageSource]) -> [Any] {
        packages.map { source in
            switch source {
            case .simple(let value):
                return value
            case .filtered(let value):
                var dict: [String: Any] = ["source": value.source]
                if let extensions = value.extensions { dict["extensions"] = extensions }
                if let skills = value.skills { dict["skills"] = skills }
                if let prompts = value.prompts { dict["prompts"] = prompts }
                if let themes = value.themes { dict["themes"] = themes }
                return dict
            }
        }
    }

    private func mergeSettings(_ base: Settings, _ override: Settings) -> Settings {
        var result = base
        if override.lastChangelogVersion != nil { result.lastChangelogVersion = override.lastChangelogVersion }
        if override.defaultProvider != nil { result.defaultProvider = override.defaultProvider }
        if override.defaultModel != nil { result.defaultModel = override.defaultModel }
        if override.defaultThinkingLevel != nil { result.defaultThinkingLevel = override.defaultThinkingLevel }
        if override.transport != nil { result.transport = override.transport }
        if override.steeringMode != nil { result.steeringMode = override.steeringMode }
        if override.followUpMode != nil { result.followUpMode = override.followUpMode }
        if override.theme != nil { result.theme = override.theme }
        if let value = override.compaction {
            let baseValue = result.compaction ?? CompactionSettingsOverrides()
            result.compaction = CompactionSettingsOverrides(
                enabled: value.enabled ?? baseValue.enabled,
                reserveTokens: value.reserveTokens ?? baseValue.reserveTokens,
                keepRecentTokens: value.keepRecentTokens ?? baseValue.keepRecentTokens
            )
        }
        if let value = override.branchSummary {
            let baseValue = result.branchSummary ?? BranchSummarySettings()
            result.branchSummary = BranchSummarySettings(
                reserveTokens: value.reserveTokens ?? baseValue.reserveTokens,
                skipPrompt: value.skipPrompt ?? baseValue.skipPrompt
            )
        }
        if let retryOverride = override.retry {
            let baseRetry = result.retry ?? RetrySettings()
            var mergedRetry = RetrySettings(
                enabled: retryOverride.enabled ?? baseRetry.enabled,
                maxRetries: retryOverride.maxRetries ?? baseRetry.maxRetries,
                baseDelayMs: retryOverride.baseDelayMs ?? baseRetry.baseDelayMs,
                provider: baseRetry.provider
            )
            if let providerOverride = retryOverride.provider {
                let baseProvider = baseRetry.provider ?? ProviderRetrySettings()
                mergedRetry.provider = ProviderRetrySettings(
                    timeoutMs: providerOverride.timeoutMs ?? baseProvider.timeoutMs,
                    maxRetries: providerOverride.maxRetries ?? baseProvider.maxRetries,
                    maxRetryDelayMs: providerOverride.maxRetryDelayMs ?? baseProvider.maxRetryDelayMs
                )
            }
            result.retry = mergedRetry
        }
        if override.hideThinkingBlock != nil { result.hideThinkingBlock = override.hideThinkingBlock }
        if override.showCacheMissNotices != nil { result.showCacheMissNotices = override.showCacheMissNotices }
        if override.shellPath != nil { result.shellPath = override.shellPath }
        if override.shellCommandPrefix != nil { result.shellCommandPrefix = override.shellCommandPrefix }
        if override.quietStartup != nil { result.quietStartup = override.quietStartup }
        if override.collapseChangelog != nil { result.collapseChangelog = override.collapseChangelog }
        if override.packages != nil { result.packages = override.packages }
        if override.extensions != nil { result.extensions = override.extensions }
        if override.skillPaths != nil { result.skillPaths = override.skillPaths }
        if override.prompts != nil { result.prompts = override.prompts }
        if override.themes != nil { result.themes = override.themes }
        if override.enableSkillCommands != nil { result.enableSkillCommands = override.enableSkillCommands }
        if override.hooks != nil { result.hooks = override.hooks }
        if override.customTools != nil { result.customTools = override.customTools }
        if let value = override.skills {
            let baseValue = result.skills ?? SkillsSettings()
            result.skills = SkillsSettings(
                enabled: value.enabled ?? baseValue.enabled,
                enableCodexUser: value.enableCodexUser ?? baseValue.enableCodexUser,
                enableClaudeUser: value.enableClaudeUser ?? baseValue.enableClaudeUser,
                enableClaudeProject: value.enableClaudeProject ?? baseValue.enableClaudeProject,
                enablePiUser: value.enablePiUser ?? baseValue.enablePiUser,
                enablePiProject: value.enablePiProject ?? baseValue.enablePiProject,
                enableSkillCommands: value.enableSkillCommands ?? baseValue.enableSkillCommands,
                customDirectories: value.customDirectories ?? baseValue.customDirectories,
                ignoredSkills: value.ignoredSkills ?? baseValue.ignoredSkills,
                includeSkills: value.includeSkills ?? baseValue.includeSkills
            )
        }
        if let value = override.terminal {
            let baseValue = result.terminal ?? TerminalSettings()
            result.terminal = TerminalSettings(
                showImages: value.showImages ?? baseValue.showImages,
                imageWidthCells: value.imageWidthCells ?? baseValue.imageWidthCells,
                showTerminalProgress: value.showTerminalProgress ?? baseValue.showTerminalProgress
            )
        }
        if let value = override.images {
            let baseValue = result.images ?? ImageSettings()
            result.images = ImageSettings(
                autoResize: value.autoResize ?? baseValue.autoResize,
                blockImages: value.blockImages ?? baseValue.blockImages
            )
        }
        if override.enabledModels != nil { result.enabledModels = override.enabledModels }
        if override.doubleEscapeAction != nil { result.doubleEscapeAction = override.doubleEscapeAction }
        if override.editorPaddingX != nil { result.editorPaddingX = override.editorPaddingX }
        if override.outputPad != nil { result.outputPad = override.outputPad }
        if override.autocompleteMaxVisible != nil { result.autocompleteMaxVisible = override.autocompleteMaxVisible }
        if override.showHardwareCursor != nil { result.showHardwareCursor = override.showHardwareCursor }
        if override.tuiMode != nil { result.tuiMode = override.tuiMode }
        if override.fullscreenScrollbar != nil { result.fullscreenScrollbar = override.fullscreenScrollbar }
        if override.mouseWheelStep != nil { result.mouseWheelStep = override.mouseWheelStep }
        if let value = override.markdown {
            let baseValue = result.markdown ?? MarkdownSettings()
            result.markdown = MarkdownSettings(
                codeBlockIndent: value.codeBlockIndent ?? baseValue.codeBlockIndent,
                mermaidEnabled: value.mermaidEnabled ?? baseValue.mermaidEnabled,
                mermaidRenderWhileStreaming: value.mermaidRenderWhileStreaming ?? baseValue.mermaidRenderWhileStreaming,
                latexEnabled: value.latexEnabled ?? baseValue.latexEnabled
            )
        }
        if let value = override.thinkingBudgets {
            let baseValue = result.thinkingBudgets ?? ThinkingBudgetsSettings()
            result.thinkingBudgets = ThinkingBudgetsSettings(
                minimal: value.minimal ?? baseValue.minimal,
                low: value.low ?? baseValue.low,
                medium: value.medium ?? baseValue.medium,
                high: value.high ?? baseValue.high
            )
        }
        if override.treeFilterMode != nil { result.treeFilterMode = override.treeFilterMode }
        if override.promptSnippetsEnabled != nil { result.promptSnippetsEnabled = override.promptSnippetsEnabled }
        if let value = override.projectTrust {
            result.projectTrust = (result.projectTrust ?? [:]).merging(value) { _, new in new }
        }
        if let value = override.warnings {
            let baseValue = result.warnings ?? WarningsSettings()
            result.warnings = WarningsSettings(
                anthropicExtraUsage: value.anthropicExtraUsage ?? baseValue.anthropicExtraUsage
            )
        }
        if override.enableInstallTelemetry != nil { result.enableInstallTelemetry = override.enableInstallTelemetry }
        if override.enableAnalytics != nil { result.enableAnalytics = override.enableAnalytics }
        if override.trackingId != nil { result.trackingId = override.trackingId }
        if override.sessionDir != nil { result.sessionDir = override.sessionDir }
        if override.npmCommand != nil { result.npmCommand = override.npmCommand }
        if override.httpIdleTimeoutMs != nil { result.httpIdleTimeoutMs = override.httpIdleTimeoutMs }
        if override.websocketConnectTimeoutMs != nil { result.websocketConnectTimeoutMs = override.websocketConnectTimeoutMs }
        return result
    }
}

private func normalizeProjectTrustPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardized.path
}
