import Foundation

public struct FileSlashCommand: Sendable {
    public var name: String
    public var description: String
    public var content: String
    public var source: String

    public init(name: String, description: String, content: String, source: String) {
        self.name = name
        self.description = description
        self.content = content
        self.source = source
    }
}

public func parseCommandArgs(_ argsString: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inQuote: Character? = nil

    for char in argsString {
        if let quote = inQuote {
            if char == quote {
                inQuote = nil
            } else {
                current.append(char)
            }
        } else if char == "\"" || char == "'" {
            inQuote = char
        } else if char == " " || char == "\t" {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }

    if !current.isEmpty {
        args.append(current)
    }

    return args
}

public func substituteArgs(_ content: String, _ args: [String]) -> String {
    var result = content
    let allArgs = args.joined(separator: " ")

    let pattern = #"\$\{(\d+):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return result
    }

    func stringValue(_ match: NSTextCheckingResult, _ index: Int) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: result) else {
            return nil
        }
        return String(result[swiftRange])
    }

    let range = NSRange(location: 0, length: result.utf16.count)
    let matches = regex.matches(in: result, options: [], range: range)
    for match in matches.reversed() {
        guard let replaceRange = Range(match.range(at: 0), in: result) else { continue }

        let replacement: String
        if let defaultNum = stringValue(match, 1), let defaultValue = stringValue(match, 2) {
            let index = (Int(defaultNum) ?? 0) - 1
            let value = args.indices.contains(index) ? args[index] : ""
            replacement = value.isEmpty ? defaultValue : value
        } else if let sliceStart = stringValue(match, 3) {
            let rawStart = (Int(sliceStart) ?? 1) - 1
            let start = max(0, rawStart)
            if start >= args.count {
                replacement = ""
            } else if let sliceLength = stringValue(match, 4), let length = Int(sliceLength) {
                let end = min(args.count, start + max(0, length))
                replacement = args[start..<end].joined(separator: " ")
            } else {
                replacement = args[start...].joined(separator: " ")
            }
        } else if let simple = stringValue(match, 5) {
            if simple == "ARGUMENTS" || simple == "@" {
                replacement = allArgs
            } else {
                let index = (Int(simple) ?? 0) - 1
                replacement = args.indices.contains(index) ? args[index] : ""
            }
        } else {
            continue
        }

        result.replaceSubrange(replaceRange, with: replacement)
    }

    return result
}

private func loadCommandsFromDir(_ dir: String, source: String, subdir: String = "") -> [FileSlashCommand] {
    var commands: [FileSlashCommand] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
        return commands
    }

    for entry in entries {
        let name = entry.lastPathComponent
        let subdirName = subdir.isEmpty ? name : "\(subdir):\(name)"
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDir = values?.isDirectory ?? false
        let isSymlink = values?.isSymbolicLink ?? false

        if isDir {
            commands.append(contentsOf: loadCommandsFromDir(entry.path, source: source, subdir: subdirName))
            continue
        }

        if !(entry.pathExtension.lowercased() == "md") {
            continue
        }

        if !isSymlink && !FileManager.default.isReadableFile(atPath: entry.path) {
            continue
        }

        guard let rawContent = try? String(contentsOfFile: entry.path, encoding: .utf8) else {
            continue
        }

        let parsed = parseFrontmatter(rawContent)
        let baseName = entry.deletingPathExtension().lastPathComponent

        let sourceStr: String = {
            if source == "user" {
                return subdir.isEmpty ? "(user)" : "(user:\(subdir))"
            }
            return subdir.isEmpty ? "(project)" : "(project:\(subdir))"
        }()

        var description = parsed.frontmatter["description"] ?? ""
        if description.isEmpty {
            if let firstLine = parsed.body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = String(firstLine)
                description = line.count > 60 ? String(line.prefix(60)) + "..." : line
            }
        }

        description = description.isEmpty ? sourceStr : "\(description) \(sourceStr)"

        commands.append(FileSlashCommand(name: baseName, description: description, content: parsed.body, source: sourceStr))
    }

    return commands
}

public struct LoadSlashCommandsOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?

    public init(cwd: String? = nil, agentDir: String? = nil) {
        self.cwd = cwd
        self.agentDir = agentDir
    }
}

public func loadSlashCommands(_ options: LoadSlashCommandsOptions = LoadSlashCommandsOptions()) -> [FileSlashCommand] {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = options.agentDir ?? getCommandsDir()

    var commands: [FileSlashCommand] = []

    let globalCommandsDir = options.agentDir != nil
        ? URL(fileURLWithPath: resolvedAgentDir).appendingPathComponent("commands").path
        : resolvedAgentDir
    commands.append(contentsOf: loadCommandsFromDir(globalCommandsDir, source: "user"))

    let projectCommandsDir = URL(fileURLWithPath: resolvedCwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("commands").path
    commands.append(contentsOf: loadCommandsFromDir(projectCommandsDir, source: "project"))

    return commands
}

public func expandSlashCommand(_ text: String, _ fileCommands: [FileSlashCommand]) -> String {
    guard text.hasPrefix("/") else { return text }
    let spaceIndex = text.firstIndex(of: " ")
    let commandName: String
    let argsString: String
    if let spaceIndex {
        commandName = String(text[text.index(after: text.startIndex)..<spaceIndex])
        argsString = String(text[text.index(after: spaceIndex)...])
    } else {
        commandName = String(text.dropFirst())
        argsString = ""
    }

    if let command = fileCommands.first(where: { $0.name == commandName }) {
        let args = parseCommandArgs(argsString)
        return substituteArgs(command.content, args)
    }

    return text
}
