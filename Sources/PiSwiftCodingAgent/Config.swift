import Foundation

public let APP_NAME = "pi"
public let CONFIG_DIR_NAME = ".pi"
public let PACKAGE_NAME = "@earendil-works/pi-coding-agent"
public let VERSION = "0.0.0"
public let ENV_CODING_AGENT = "\(APP_NAME.uppercased())_CODING_AGENT"
public let ENV_AGENT_DIR = "\(APP_NAME.uppercased())_CODING_AGENT_DIR"
public let ENV_CODING_AGENT_SESSION_DIR = "\(APP_NAME.uppercased())_CODING_AGENT_SESSION_DIR"
public let ENV_PACKAGE_DIR = "PI_PACKAGE_DIR"
/// Child processes use this standard marker to identify the Pi coding agent.
public let ENV_AI_AGENT = "AI_AGENT"
public let AI_AGENT_VALUE = APP_NAME

public func getPackageDir() -> String {
    if let override = ProcessInfo.processInfo.environment[ENV_PACKAGE_DIR], !override.isEmpty {
        if override == "~" {
            return getHomeDir()
        }
        if override.hasPrefix("~/") {
            return URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(override.dropFirst(2))).path
        }
        return override
    }
    return FileManager.default.currentDirectoryPath
}

public func getThemesDir() -> String {
    (getPackageDir() as NSString).appendingPathComponent("theme")
}

public func getExportTemplateDir() -> String {
    (getPackageDir() as NSString).appendingPathComponent("export-html")
}

public func getPackageJsonPath() -> String {
    (getPackageDir() as NSString).appendingPathComponent("package.json")
}

public func getReadmePath() -> String {
    (getPackageDir() as NSString).appendingPathComponent("README.md")
}

public func getDocsPath() -> String {
    (getPackageDir() as NSString).appendingPathComponent("docs")
}

public func getExamplesPath() -> String {
    (getPackageDir() as NSString).appendingPathComponent("examples")
}

public func getChangelogPath() -> String {
    (getPackageDir() as NSString).appendingPathComponent("CHANGELOG.md")
}

public func getAgentDir() -> String {
    if let override = ProcessInfo.processInfo.environment[ENV_AGENT_DIR], !override.isEmpty {
        return override
    }

#if os(macOS)
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("agent").path
#else
    // App data (best general-purpose location)
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return "/tmp"
    }
    return appSupport.appendingPathComponent("agent").path()
#endif
}

public func getHomeDir() -> String {
#if os(macOS)
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.path
#else
    // App data (best general-purpose location)
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return "/tmp"
    }
    return appSupport.path()
#endif
}

public func getCustomThemesDir() -> String {
    (getAgentDir() as NSString).appendingPathComponent("themes")
}

public func getModelsPath() -> String {
    (getAgentDir() as NSString).appendingPathComponent("models.json")
}

public func getAuthPath() -> String {
    (getAgentDir() as NSString).appendingPathComponent("auth.json")
}

public func getSettingsPath() -> String {
    (getAgentDir() as NSString).appendingPathComponent("settings.json")
}

public func getToolsDir() -> String {
    (getAgentDir() as NSString).appendingPathComponent("tools")
}

public func getCommandsDir() -> String {
    (getAgentDir() as NSString).appendingPathComponent("commands")
}

public func getPromptsDir() -> String {
    (getAgentDir() as NSString).appendingPathComponent("prompts")
}

public func getAgentsDir() -> String {
    (getAgentDir() as NSString).appendingPathComponent("agents")
}

public func getSessionsDir() -> String {
    (getAgentDir() as NSString).appendingPathComponent("sessions")
}

public func getDebugLogPath() -> String {
    (getAgentDir() as NSString).appendingPathComponent("\(APP_NAME)-debug.log")
}
