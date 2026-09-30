import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public enum ClipboardError: Error, CustomStringConvertible {
    case missingTool(String)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .missingTool(let message):
            return message
        case .copyFailed(let message):
            return message
        }
    }
}

public enum ClipboardCopyResult: Sendable, Equatable {
    case success
    case osc52SentUnverified
    case failure(String)
}

public enum ClipboardReadResult: Sendable, Equatable {
    case content(String)
    case empty
    case unavailable
    case error(String)
}

public enum ClipboardImageReadResult: Sendable, Equatable {
    case content(Data)
    case empty
    case unavailable
    case error(String)
}

public struct ClipboardImageBackend: Sendable {
    public var nativeRead: @Sendable () -> ClipboardImageReadResult
    public var command: @Sendable (String, [String]) -> ClipboardImageReadResult
    public var wslRead: @Sendable () -> ClipboardImageReadResult

    public init(nativeRead: @escaping @Sendable () -> ClipboardImageReadResult,
                command: @escaping @Sendable (String, [String]) -> ClipboardImageReadResult,
                wslRead: @escaping @Sendable () -> ClipboardImageReadResult = { .unavailable }) {
        self.nativeRead = nativeRead
        self.command = command
        self.wslRead = wslRead
    }
}

public func readClipboardImagePngData(platform: ClipboardPlatform, environment: [String: String], backend: ClipboardImageBackend) -> ClipboardImageReadResult {
    guard platform == .linux else { return backend.nativeRead() }
    var linuxResult: ClipboardImageReadResult = .unavailable
    if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty || environment["XDG_SESSION_TYPE"] == "wayland" {
        let wayland = backend.command("wl-paste", ["--type", "image/png"])
        if case .content = wayland { return wayland }
        if case .error = wayland { return wayland }
        linuxResult = wayland
    }
    if case .empty = linuxResult {
        // An empty Wayland clipboard must not expose stale X11 content.
    } else {
        linuxResult = backend.command("xclip", ["-selection", "clipboard", "-t", "image/png", "-o"])
        if case .content = linuxResult { return linuxResult }
    }
    if isWSL(environment) {
        let windows = backend.wslRead()
        if case .content = windows { return windows }
        if case .error = windows { return windows }
    }
    if case .unavailable = linuxResult { return backend.nativeRead() }
    return linuxResult
}

public enum ClipboardPlatform: Sendable { case macOS, linux, windows, mobile }

/// The closures let tests verify backend ordering without a terminal or display.
public struct ClipboardBackend: Sendable {
    public var nativeCopy: @Sendable (String) -> Bool
    public var nativeRead: @Sendable () -> ClipboardReadResult
    public var command: @Sendable (String, [String], String?) -> ClipboardReadResult
    public var emitOSC52: @Sendable (String) -> Bool

    public init(nativeCopy: @escaping @Sendable (String) -> Bool, nativeRead: @escaping @Sendable () -> ClipboardReadResult,
                command: @escaping @Sendable (String, [String], String?) -> ClipboardReadResult,
                emitOSC52: @escaping @Sendable (String) -> Bool) {
        self.nativeCopy = nativeCopy
        self.nativeRead = nativeRead
        self.command = command
        self.emitOSC52 = emitOSC52
    }
}

public func copyToClipboard(_ text: String) -> ClipboardCopyResult {
    copyToClipboard(text, platform: defaultClipboardPlatform(), environment: ProcessInfo.processInfo.environment, backend: systemClipboardBackend)
}

public func copyToClipboard(_ text: String, platform: ClipboardPlatform, environment: [String: String], backend: ClipboardBackend) -> ClipboardCopyResult {
    let remote = ["SSH_CONNECTION", "SSH_CLIENT", "MOSH_CONNECTION"].contains { !(environment[$0] ?? "").isEmpty }
    let display = !(environment["DISPLAY"] ?? "").isEmpty
    let wayland = !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty
    let termux = !(environment["TERMUX_VERSION"] ?? "").isEmpty
    var copied = platform != .linux && backend.nativeCopy(text)
    if !copied {
        var commands: [(String, [String])] = []
        switch platform {
        case .macOS: commands = [("pbcopy", [])]
        case .windows: commands = [("clip", [])]
        case .mobile: break
        case .linux:
            if termux { commands.append(("termux-clipboard-set", [])) }
            if wayland { commands.append(("wl-copy", [])) }
            if display {
                commands.append(("xclip", ["-selection", "clipboard"]))
                commands.append(("xsel", ["--clipboard", "--input"]))
            }
        }
        copied = commands.contains { command, args in
            if case .content = backend.command(command, args, text) { return true }
            return false
        }
    }
    if !copied && platform == .linux && isWSL(environment) {
        if !(environment["WT_SESSION"] ?? "").isEmpty && backend.emitOSC52(text) { return .osc52SentUnverified }
        copied = copyViaWindowsClipboard(text, backend: backend)
    }
    var remoteOSC52Sent = false
    if remote {
        remoteOSC52Sent = backend.emitOSC52(text)
    } else if !copied && platform == .linux && !display && !wayland && !termux {
        return backend.emitOSC52(text) ? .osc52SentUnverified : .failure("Clipboard unavailable: text exceeds the OSC 52 size limit")
    }
    if copied { return .success }
    if remoteOSC52Sent { return .osc52SentUnverified }
    if remote { return .failure("Clipboard unavailable: text exceeds the OSC 52 size limit") }
    if termux { return .failure("Clipboard unavailable: install the Termux:API app and `termux-api` package") }
    if wayland { return .failure("Clipboard unavailable: install `wl-clipboard` (`wl-copy`) or check Wayland access") }
    if display { return .failure("Clipboard unavailable: install `xclip` or `xsel`, or check X11 access") }
    return .failure("Clipboard unavailable")
}

private func emitOsc52(_ text: String) -> Bool {
    let encoded = Data(text.utf8).base64EncodedString()
    guard encoded.utf8.count <= 100_000,
          let data = "\u{001B}]52;c;\(encoded)\u{0007}".data(using: .utf8) else { return false }
    FileHandle.standardOutput.write(data)
    return true
}

public func clipboardHasImage() -> Bool {
#if canImport(AppKit)
    return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
#elseif canImport(UIKit)
    UIPasteboard.general.hasImages
#elseif os(Linux)
    return linuxClipboardHasImage()
#else
    return false
#endif
}

public func getClipboardImagePngData() -> Data? {
    if case .content(let data) = readClipboardImagePngData() { return data }
    return nil
}

/// Read file URLs copied in Finder. Returns nil when the pasteboard has no files.
public func readClipboardFilePaths() -> [String]? {
#if canImport(AppKit)
    return readClipboardFilePaths(from: .general)
#else
    return nil
#endif
}

#if canImport(AppKit)
func readClipboardFilePaths(from pasteboard: NSPasteboard) -> [String]? {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let paths = urls.filter(\.isFileURL).map(\.path)
    return paths.isEmpty ? nil : paths
}
#endif

public func readClipboardImagePngData() -> ClipboardImageReadResult {
#if canImport(AppKit)
    guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
        return .empty
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return .error("Clipboard image could not be decoded")
    }
    guard let png = rep.representation(using: .png, properties: [:]) else { return .error("Clipboard image could not be converted to PNG") }
    return .content(png)
#elseif canImport(UIKit)
    guard let image = UIPasteboard.general.image else { return .empty }
    guard let png = image.pngData() else { return .error("Clipboard image could not be converted to PNG") }
    return .content(png)
#elseif os(Linux)
    return readLinuxClipboardImagePngData()
#else
    return .unavailable
#endif
}

public func readClipboardText() -> ClipboardReadResult {
    readClipboardText(platform: defaultClipboardPlatform(), environment: ProcessInfo.processInfo.environment, backend: systemClipboardBackend)
}

public func readClipboardText(platform: ClipboardPlatform, environment: [String: String], backend: ClipboardBackend) -> ClipboardReadResult {
    var lastError: ClipboardReadResult?
    if platform == .linux {
        var commands: [(String, [String])] = []
        if !(environment["TERMUX_VERSION"] ?? "").isEmpty { commands.append(("termux-clipboard-get", [])) }
        if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty { commands.append(("wl-paste", ["--no-newline", "--type", "text"])) }
        if !(environment["DISPLAY"] ?? "").isEmpty {
            commands.append(("xclip", ["-selection", "clipboard", "-out"]))
            commands.append(("xsel", ["--clipboard", "--output"]))
        }
        for (command, args) in commands {
            let result = backend.command(command, args, nil)
            if case .content = result { return result }
            if case .empty = result { return result }
            if case .error = result { lastError = result }
        }
    }
    let native = backend.nativeRead()
    if case .unavailable = native { return lastError ?? .unavailable }
    return native
}

private func defaultClipboardPlatform() -> ClipboardPlatform {
    #if os(Linux)
    .linux
    #elseif os(Windows)
    .windows
    #elseif canImport(UIKit)
    .mobile
    #else
    .macOS
    #endif
}

private func isWSL(_ environment: [String: String]) -> Bool {
    if !(environment["WSL_DISTRO_NAME"] ?? "").isEmpty || !(environment["WSLENV"] ?? "").isEmpty { return true }
    #if os(Linux)
    return ((try? String(contentsOfFile: "/proc/version", encoding: .utf8)) ?? "").range(of: "microsoft|wsl", options: .regularExpression) != nil
    #else
    return false
    #endif
}

private func copyViaWindowsClipboard(_ text: String, backend: ClipboardBackend) -> Bool {
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pi-wsl-clip-\(UUID().uuidString).txt")
    do {
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .content(let path) = backend.command("wslpath", ["-w", file.path], nil) else { return false }
        let escaped = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "'", with: "''")
        guard !escaped.isEmpty else { return false }
        let script = "Set-Clipboard -Value ([System.IO.File]::ReadAllText('\(escaped)', [System.Text.Encoding]::UTF8))"
        let result = backend.command("powershell.exe", ["-NoProfile", "-Command", script], nil)
        if case .content = result { return true }
        if case .empty = result { return true }
        return false
    }
}

private let systemClipboardBackend = ClipboardBackend(
    nativeCopy: { text in
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        return true
        #elseif canImport(AppKit)
        return NSPasteboard.general.setString(text, forType: .string)
        #else
        return false
        #endif
    },
    nativeRead: {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string else { return .empty }
        return text.isEmpty ? .empty : .content(text)
        #elseif canImport(AppKit)
        guard let text = NSPasteboard.general.string(forType: .string) else { return .empty }
        return text.isEmpty ? .empty : .content(text)
        #else
        return .unavailable
        #endif
    },
    command: { command, args, input in
        #if !canImport(UIKit)
        if let input {
            do { try runClipboardCommand(command: command, args: args, input: input); return .content("") }
            catch { return .error(error.localizedDescription) }
        }
        return runClipboardReadCommand(command: command, args: args)
        #else
        return .unavailable
        #endif
    },
    emitOSC52: emitOsc52
)

#if !canImport(UIKit)
private func runClipboardReadCommand(command: String, args: [String]) -> ClipboardReadResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.contains("/") ? command : "/usr/bin/env")
    process.arguments = command.contains("/") ? args : [command] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return .unavailable }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return .unavailable }
    guard let text = String(data: data, encoding: .utf8) else { return .error("Clipboard text is not UTF-8") }
    return text.isEmpty ? .empty : .content(text)
}
#else
private func runClipboardReadCommand(command: String, args: [String]) -> ClipboardReadResult { .unavailable }
#endif

#if os(Linux)
private func linuxClipboardHasImage() -> Bool {
    if case .content = readLinuxClipboardImagePngData() { return true }
    return false
}

private func readLinuxClipboardImagePngData() -> ClipboardImageReadResult {
    readClipboardImagePngData(platform: .linux, environment: ProcessInfo.processInfo.environment,
                              backend: ClipboardImageBackend(nativeRead: { .unavailable },
                                                             command: { runClipboardCommandBinaryResult(command: $0, args: $1) },
                                                             wslRead: readWSLClipboardImageViaPowerShell))
}

private func readWSLClipboardImageViaPowerShell() -> ClipboardImageReadResult {
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pi-wsl-clip-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    guard case .content(let pathData) = runClipboardCommandBinaryResult(command: "wslpath", args: ["-w", file.path]),
          let path = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty else { return .unavailable }
    let escaped = path.replacingOccurrences(of: "'", with: "''")
    let script = [
        "Add-Type -AssemblyName System.Windows.Forms",
        "Add-Type -AssemblyName System.Drawing",
        "$path = '\(escaped)'",
        "$img = [System.Windows.Forms.Clipboard]::GetImage()",
        "if ($img) { $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'ok' } else { Write-Output 'empty' }",
    ].joined(separator: "; ")
    guard case .content(let output) = runClipboardCommandBinaryResult(command: "powershell.exe", args: ["-NoProfile", "-Command", script]),
          let status = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .unavailable }
    if status == "empty" { return .empty }
    guard status == "ok", let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { return .unavailable }
    return .content(bytes)
}

private func isWaylandSession() -> Bool {
    let env = ProcessInfo.processInfo.environment
    if let wayland = env["WAYLAND_DISPLAY"], !wayland.isEmpty {
        return true
    }
    if let session = env["XDG_SESSION_TYPE"], session.lowercased() == "wayland" {
        return true
    }
    return false
}

private func runClipboardCommandBinaryResult(command: String, args: [String]) -> ClipboardImageReadResult {
    let process = Process()
    if command.contains("/") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return .unavailable
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else { return .unavailable }
    return data.isEmpty ? .empty : .content(data)
}
#endif

#if !canImport(UIKit)
private func runClipboardCommand(command: String, args: [String], input: String) throws {
    let process = Process()
    if command.contains("/") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }

    let stdinPipe = Pipe()
    process.standardInput = stdinPipe

    do {
        try process.run()
    } catch {
        throw ClipboardError.copyFailed("Failed to launch clipboard command: \(command)")
    }

    if let data = input.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
    }
    try? stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        throw ClipboardError.copyFailed("Clipboard command failed: \(command)")
    }
}

private func runClipboardCommandAsync(command: String, args: [String], input: String) -> Bool {
    let process = Process()
    if command.contains("/") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }

    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return false
    }

    if let data = input.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
    }
    try? stdinPipe.fileHandleForWriting.close()
    return true
}
#endif
