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

public func copyToClipboard(_ text: String) throws {
    emitOsc52(text)
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif os(Windows)
    try? runClipboardCommand(command: "clip", args: [], input: text)
#elseif os(Linux)
    if isWaylandSession() {
        if !runClipboardCommandAsync(command: "wl-copy", args: [], input: text) {
            try? runClipboardCommand(command: "xclip", args: ["-selection", "clipboard"], input: text)
            try? runClipboardCommand(command: "xsel", args: ["--clipboard", "--input"], input: text)
        }
    } else {
        try? runClipboardCommand(command: "xclip", args: ["-selection", "clipboard"], input: text)
        try? runClipboardCommand(command: "xsel", args: ["--clipboard", "--input"], input: text)
    }
#elseif os(macOS)
    if NSClassFromString("NSApplication") != nil {
        NSPasteboard.general.setString(text, forType: .string)
    } else {
        try? runClipboardCommand(command: "/usr/bin/pbcopy", args: [], input: text)
    }
#endif
}

private func emitOsc52(_ text: String) {
    let encoded = Data(text.utf8).base64EncodedString()
    guard let data = "\u{001B}]52;c;\(encoded)\u{0007}".data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
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
#if canImport(AppKit)
    guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
        return nil
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return rep.representation(using: .png, properties: [:])
#elseif canImport(UIKit)
    return UIPasteboard.general.image?.pngData()
#elseif os(Linux)
    return readLinuxClipboardImagePngData()
#else
    return nil
#endif
}

/// Read plain text from the system clipboard. Returns nil when empty or unavailable.
/// Used as a fallback when a clipboard-paste finds no image.
public func readClipboardText() -> String? {
#if canImport(AppKit)
    let text = NSPasteboard.general.string(forType: .string)
    return (text?.isEmpty == false) ? text : nil
#elseif canImport(UIKit)
    let text = UIPasteboard.general.string
    return (text?.isEmpty == false) ? text : nil
#elseif os(Linux)
    let data: Data?
    if isWaylandSession() {
        data = runClipboardCommandBinary(command: "wl-paste", args: ["--no-newline"])
            ?? runClipboardCommandBinary(command: "xclip", args: ["-selection", "clipboard", "-o"])
    } else {
        data = runClipboardCommandBinary(command: "xclip", args: ["-selection", "clipboard", "-o"])
            ?? runClipboardCommandBinary(command: "xsel", args: ["--clipboard", "--output"])
    }
    guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
    return text
#else
    return nil
#endif
}

#if os(Linux)
private func linuxClipboardHasImage() -> Bool {
    readLinuxClipboardImagePngData() != nil
}

private func readLinuxClipboardImagePngData() -> Data? {
    if isWaylandSession() {
        if let data = runClipboardCommandBinary(command: "wl-paste", args: ["--type", "image/png"]) {
            return data
        }
    }

    return runClipboardCommandBinary(command: "xclip", args: ["-selection", "clipboard", "-t", "image/png", "-o"])
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

private func runClipboardCommandBinary(command: String, args: [String]) -> Data? {
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
        return nil
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0, !data.isEmpty else { return nil }
    return data
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
