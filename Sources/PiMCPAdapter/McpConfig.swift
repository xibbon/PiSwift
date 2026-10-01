import Foundation
import PiSwiftMCP

// MARK: - Import Sources

private let importPaths: [String: String] = {
    let home = NSHomeDirectory()
    return [
        "cursor": (home as NSString).appendingPathComponent(".cursor/mcp.json"),
        "claude-code": (home as NSString).appendingPathComponent(".claude/claude_desktop_config.json"),
        "claude-desktop": (home as NSString).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
        "codex": (home as NSString).appendingPathComponent(".codex/config.json"),
        "windsurf": (home as NSString).appendingPathComponent(".windsurf/mcp.json"),
    ]
}()

// MARK: - Config Loading

public func loadMcpConfig(overridePath: String? = nil, cwd: String? = nil) -> McpConfig {
    let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath

    // 1. Load base config
    let basePath = overridePath ?? defaultConfigPath()
    var config = loadConfigFile(basePath) ?? McpConfig()

    // 2. Merge imports
    if let imports = config.imports {
        for importSource in imports {
            mergeImportedServers(into: &config, source: importSource, cwd: resolvedCwd)
        }
    }

    // 3. Merge project-local config
    let projectPath = (resolvedCwd as NSString).appendingPathComponent(".pi/mcp.json")
    if let projectConfig = loadConfigFile(projectPath) {
        for (name, entry) in projectConfig.mcpServers {
            config.mcpServers[name] = entry
        }
        if let settings = projectConfig.settings {
            if config.settings == nil {
                config.settings = settings
            } else {
                if let prefix = settings.toolPrefix { config.settings?.toolPrefix = prefix }
                if let timeout = settings.idleTimeout { config.settings?.idleTimeout = timeout }
                if let dt = settings.directTools { config.settings?.directTools = dt }
            }
        }
    }

    return config
}

public func getServerProvenance(overridePath: String? = nil, cwd: String? = nil) -> [String: ServerProvenance] {
    let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath
    var provenance: [String: ServerProvenance] = [:]

    let basePath = overridePath ?? defaultConfigPath()
    if let baseConfig = loadConfigFile(basePath) {
        for name in baseConfig.mcpServers.keys {
            provenance[name] = ServerProvenance(source: "config", path: basePath)
        }

        if let imports = baseConfig.imports {
            for importSource in imports {
                let importedServers = getImportedServerNames(source: importSource, cwd: resolvedCwd)
                for name in importedServers where provenance[name] == nil {
                    let path = resolveImportPath(importSource, cwd: resolvedCwd) ?? importSource
                    provenance[name] = ServerProvenance(source: importSource, path: path)
                }
            }
        }
    }

    let projectPath = (resolvedCwd as NSString).appendingPathComponent(".pi/mcp.json")
    if let projectConfig = loadConfigFile(projectPath) {
        for name in projectConfig.mcpServers.keys {
            provenance[name] = ServerProvenance(source: "project", path: projectPath)
        }
    }

    return provenance
}

// MARK: - Internals

func defaultConfigPath() -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return (agentDir as NSString).appendingPathComponent("mcp.json")
}

private func loadConfigFile(_ path: String) -> McpConfig? {
    guard FileManager.default.fileExists(atPath: path),
          let data = FileManager.default.contents(atPath: path) else {
        return nil
    }
    do {
        return try JSONDecoder().decode(McpConfig.self, from: data)
    } catch {
        return nil
    }
}

private func mergeImportedServers(into config: inout McpConfig, source: String, cwd: String) {
    guard let path = resolveImportPath(source, cwd: cwd) else { return }
    guard let data = FileManager.default.contents(atPath: path) else { return }

    do {
        let importedDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let serversDict: [String: Any]?

        // Different sources store servers under different keys
        if let servers = importedDict["mcpServers"] as? [String: Any] {
            serversDict = servers
        } else if let servers = importedDict["mcp-servers"] as? [String: Any] {
            serversDict = servers
        } else if source == "codex" {
            // Codex wraps in mcp.servers
            if let mcp = importedDict["mcp"] as? [String: Any],
               let servers = mcp["servers"] as? [String: Any] {
                serversDict = servers
            } else {
                serversDict = nil
            }
        } else if source == "vscode" {
            // VS Code wraps in servers
            if let servers = importedDict["servers"] as? [String: Any] {
                serversDict = servers
            } else {
                serversDict = nil
            }
        } else {
            serversDict = nil
        }

        guard let servers = serversDict else { return }

        let serversData = try JSONSerialization.data(withJSONObject: servers)
        let decoded = try JSONDecoder().decode([String: ServerEntry].self, from: serversData)

        for (name, entry) in decoded where config.mcpServers[name] == nil {
            config.mcpServers[name] = entry
        }
    } catch {
        // Silently skip malformed imports
    }
}

private func getImportedServerNames(source: String, cwd: String) -> [String] {
    guard let path = resolveImportPath(source, cwd: cwd),
          let data = FileManager.default.contents(atPath: path),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return []
    }

    if let servers = dict["mcpServers"] as? [String: Any] { return Array(servers.keys) }
    if let servers = dict["mcp-servers"] as? [String: Any] { return Array(servers.keys) }
    if source == "codex", let mcp = dict["mcp"] as? [String: Any], let servers = mcp["servers"] as? [String: Any] {
        return Array(servers.keys)
    }
    if source == "vscode", let servers = dict["servers"] as? [String: Any] { return Array(servers.keys) }
    return []
}

private func resolveImportPath(_ source: String, cwd: String) -> String? {
    if source == "vscode" {
        let path = (cwd as NSString).appendingPathComponent(".vscode/mcp.json")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    if let known = importPaths[source] {
        return FileManager.default.fileExists(atPath: known) ? known : nil
    }
    // Treat as file path
    let expanded = NSString(string: source).expandingTildeInPath
    return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
}
