import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

@Suite("v1.5.2 C-TB")
struct CTBFocusedTests {
    // b5fc6dc84, ansi-utils.test.ts:112-134.
    @Test func stripsPrivateParameterCSISequencesWithTheirParameters() {
        #expect(stripAnsi("\u{1b}[<35;59;1Mstep 1") == "step 1")
        #expect(stripAnsi("a\u{1b}[>0;276;0cb") == "ab")
        #expect(stripAnsi("a\u{9b}<35;59;1Mb") == "ab")
    }

    @Test func keepsDigitsAfterBareESCKeypadModeSequences() {
        #expect(stripAnsi("\u{1b}[?1h\u{1b}=123 tests passed") == "123 tests passed")
        #expect(stripAnsi("\u{1b}[?1l\u{1b}>42 files") == "42 files")
    }

    @Test func holdsBackUnfinishedPrivateParameterCSISequences() {
        let split = splitIncompleteAnsiSuffix("x\u{1b}[<35;59")
        #expect(split.complete == "x")
        #expect(split.pending == "\u{1b}[<35;59")
        #expect(splitIncompleteAnsiSuffix("x\u{1b}=").pending.isEmpty)
    }

    // 9a1953961, changelog.test.ts:59-75.
    @Test func ignoresPrereleaseAndBuildSuffixesOfLastSeenVersion() {
        let entries = [
            ChangelogEntry(major: 0, minor: 1, patch: 5, content: "0.1.5"),
            ChangelogEntry(major: 0, minor: 1, patch: 4, content: "0.1.4"),
        ]
        #expect(getNewEntries(entries, lastVersion: "0.1.5-20261020.7").isEmpty)
        #expect(getNewEntries(entries, lastVersion: "0.1.5+build.3").isEmpty)
        #expect(getNewEntries(entries, lastVersion: "0.1.4-beta.1").map(\.content) == ["0.1.5"])
        #expect(getNewEntries([ChangelogEntry(major: 0, minor: 10, patch: 0, content: "0.10.0")], lastVersion: "0.9.0").count == 1)
        // changelog.test.ts:79-90 returns undefined; Swift's compatible array API returns [].
        #expect(getNewEntries(entries, lastVersion: "malformed").isEmpty)
    }

    // c8ec752cf, tools-manager.test.ts: unsupported architectures.
    @Test func unsupportedArchitecturesHaveNoDownloadAsset() {
        for platform in ["darwin", "linux", "win32"] {
            for architecture in ["arm", "ia32", "riscv64"] {
                #expect(toolDownloadAssetName("fd", version: "1", platform: platform, architecture: architecture) == nil)
                #expect(toolDownloadAssetName("rg", version: "1", platform: platform, architecture: architecture) == nil)
            }
        }
    }

    @Test func unsupportedArchitectureSkipsNetworkLookup() async {
        let statuses = LockedState<[String]>([])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-tools-\(UUID().uuidString)")
        let manager = ToolManager(toolsDirectory: directory.path, platform: "darwin", architecture: "arm", environment: [:], transport: { _, _ in
            Issue.record("Unsupported architecture must not use the network")
            throw URLError(.unsupportedURL)
        })
        #expect(await manager.ensureTool("fd", onStatus: { status in statuses.withLock { $0.append(status.message) } }) == nil)
        #expect(statuses.withLock { $0 } == ["fd not found. Automatic download is not supported on darwin/arm. Install fd with your system package manager."])
    }

    // 1be312b46, paths.ts:73-77. A sibling with the home prefix stays absolute.
    @Test func shortenHomePathChecksComponentBoundary() {
        #if !os(Windows)
        #expect(shortenHomePath("/Users/example", homeDir: "/Users/example") == "~")
        #expect(shortenHomePath("/Users/example/work", homeDir: "/Users/example") == "~/work")
        #expect(shortenHomePath("/Users/example-old/work", homeDir: "/Users/example") == "/Users/example-old/work")
        #expect(shortenHomePath("relative/work", homeDir: "/Users/example") == "relative/work")
        #endif
    }

    // v1.5.2 mime.ts: BMP validation, JPEG XL rejection and animated PNG rejection.
    @Test func detectsOnlySupportedImageHeaders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-mime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        func detect(_ bytes: [UInt8]) throws -> String? {
            let path = directory.appendingPathComponent(UUID().uuidString)
            try Data(bytes).write(to: path)
            return detectSupportedImageMimeType(fromFile: path.path)
        }
        var bmp = [UInt8](repeating: 0, count: 58)
        bmp[0] = 0x42; bmp[1] = 0x4D; bmp[2] = 58
        bmp[10] = 54; bmp[14] = 40; bmp[26] = 1; bmp[28] = 24
        #expect(try detect(bmp) == "image/bmp")
        bmp[26] = 2
        #expect(try detect(bmp) == nil)
        #expect(try detect([0xFF, 0xD8, 0xFF, 0xF7]) == nil)
        var png = [UInt8]([0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10])
        png += [0, 0, 0, 13] + Array("IHDR".utf8) + [UInt8](repeating: 0, count: 13) + [0, 0, 0, 0]
        png += [0, 0, 0, 0] + Array("acTL".utf8)
        #expect(try detect(png) == nil)
    }

    // b4b72a351, package-manager.test.ts: manifest changelog and convention cases.
    @Test func extensionChangelogTracksNewPackageVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-package-\(UUID().uuidString)")
        let extensionDir = root.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// extension".write(to: extensionDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "{\"name\":\"sample\",\"version\":\"1.0.0\",\"pi\":{\"changelogPath\":\"docs/CHANGES.md\"}}"
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false)
        try "## 1.0.0\nFirst\n".write(to: docs.appendingPathComponent("CHANGES.md"), atomically: true, encoding: .utf8)
        let settings = SettingsManager.inMemory()
        let manager = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: settings)
        let resolved = try await manager.resolveExtensionSources([root.path], options: .init(temporary: true))
        #expect(!resolved.extensions.isEmpty)
        #expect(resolved.extensions.first?.metadata.changelogPath == docs.appendingPathComponent("CHANGES.md").path)
        #expect(getExtensionChangelogUpdates(extensions: resolved.extensions, settings: settings).isEmpty)
        try "{\"name\":\"sample\",\"version\":\"1.1.0\",\"pi\":{\"changelogPath\":\"docs/CHANGES.md\"}}"
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "## 1.1.0\nUpdated\n\n## 1.0.0\nFirst\n".write(to: docs.appendingPathComponent("CHANGES.md"), atomically: true, encoding: .utf8)
        let updates = getExtensionChangelogUpdates(extensions: resolved.extensions, settings: settings)
        #expect(updates.count == 1)
        #expect(updates.first?.name == "sample")
        #expect(updates.first?.version == "1.1.0")
        #expect(updates.first?.markdown.contains("## sample 1.1.0") == true)
        let metadata = try #require(resolved.extensions.first?.metadata)
        let source = String(decoding: try JSONEncoder().encode(metadata.source), as: UTF8.self)
        let scope = String(decoding: try JSONEncoder().encode(metadata.scope), as: UTF8.self)
        let key = "{\"source\":\(source),\"scope\":\(scope)}"
        settings.setExtensionChangelogVersion(key, version: "malformed")
        #expect(getExtensionChangelogUpdates(extensions: resolved.extensions, settings: settings).isEmpty)
        #expect(settings.getExtensionChangelogVersion(key) == "1.1.0")
    }

    // b4b72a351, package-manager.test.ts: changelog convention, traversal and auto-discovery.
    @Test func packageChangelogConventionAndUnsafeManifestPath() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-changelog-path-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("extensions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try "// extension".write(to: root.appendingPathComponent("extensions/main.swift"), atomically: true, encoding: .utf8)
        try "## 1.0.0\nOutside\n".write(to: parent.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        let manager = DefaultPackageManager(cwd: parent.path, agentDir: parent.path, settingsManager: .inMemory())
        try "{\"name\":\"sample\",\"version\":\"1.0.0\",\"pi\":{\"changelogPath\":\"../outside.md\"}}"
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let unsafe = try await manager.resolveExtensionSources([root.path], options: .init(temporary: true))
        #expect(unsafe.extensions.contains { $0.path.hasSuffix("extensions/main.swift") })
        #expect(unsafe.extensions.first?.metadata.changelogPath == nil)
        try "## 1.0.0\nInside\n".write(to: root.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        try "{\"name\":\"sample\",\"version\":\"1.0.0\"}"
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let conventional = try await manager.resolveExtensionSources([root.path], options: .init(temporary: true))
        #expect(conventional.extensions.first?.metadata.changelogPath == root.appendingPathComponent("CHANGELOG.md").path)
    }

    // 6dfb54678, resource-loader.test.ts: a failed configured install reaches the host.
    @Test func resourceLoaderExposesConfiguredInstallFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-loader-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var settingsValue = Settings()
        settingsValue.npmCommand = ["/usr/bin/false"]
        let settings = SettingsManager.inMemory(settingsValue)
        settings.setPackages([.simple("npm:missing")])
        let loader = DefaultResourceLoader(.init(cwd: root.path, agentDir: root.path, settingsManager: settings))
        await loader.reload()
        #expect(loader.getExtensions().installFailures.contains { $0.source == "npm:missing" })
    }

    // 6dfb54678, package-manager.test.ts: a failed configured install does not stop startup.
    @Test func failedConfiguredPackageInstallIsReportedAndNextPackageLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-install-\(UUID().uuidString)")
        let local = root.appendingPathComponent("local")
        let extensions = local.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// local".write(to: extensions.appendingPathComponent("good.swift"), atomically: true, encoding: .utf8)
        let settings = SettingsManager.inMemory()
        settings.setProjectPackages([.simple("npm:missing"), .simple(local.path)])
        let manager = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: settings)
        manager.setCommandRunnerForTests { command, _, _ in
            if command == "npm" { throw URLError(.notConnectedToInternet) }
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        }
        let resolved = try await manager.resolve()
        #expect(resolved.installFailures.count == 1)
        #expect(resolved.installFailures.first?.source == "npm:missing")
        #expect(resolved.extensions.contains { $0.path.hasSuffix("good.swift") })
        // package-manager.test.ts: skipped missing sources have no install failure;
        // an explicit error action still fails resolution.
        let skipped = try await manager.resolve(onMissing: { _ in .skip })
        #expect(skipped.installFailures.isEmpty)
        do {
            _ = try await manager.resolve(onMissing: { _ in .error })
            Issue.record("Explicit missing-source error should throw")
        } catch {
            #expect(error.localizedDescription.contains("Missing source"))
        }
    }

    // 5f960a0e2 and 5fb9a0b11, package-manager.test.ts: npm prefix and flags.
    @Test func npmInstallUsesRealPrefixWithoutAuditOrFund() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-prefix-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = LockedState<[[String]]>([])
        let settings = SettingsManager.inMemory()
        let manager = DefaultPackageManager(cwd: alias.path, agentDir: alias.path, settingsManager: settings)
        manager.setCommandRunnerForTests { _, args, _ in
            calls.withLock { $0.append(args) }
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        }
        try await manager.install("npm:sample", options: .init(local: true))
        let args = try #require(calls.withLock { $0.last })
        #expect(args.contains("--no-audit") && args.contains("--no-fund"))
        let prefixIndex = try #require(args.firstIndex(of: "--prefix"))
        #expect(args[prefixIndex + 1].hasPrefix(real.path))
    }

    // 0d23d5345, 342514bdf, 806cdd68e: result and warning text.
    @Test func packageUpdateSummaryDistinguishesCheckedUnchangedAndOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-update-\(UUID().uuidString)")
        let packageDir = root.appendingPathComponent(".pi/npm/node_modules/sample")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{\"version\":\"1.0.0\"}".write(to: packageDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let settings = SettingsManager.inMemory()
        settings.setProjectPackages([.simple("npm:sample")])
        let manager = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: settings)
        manager.setCommandRunnerForTests { _, args, _ in
            ExecResult(stdout: args.contains("view") ? "1.0.0\n" : "", stderr: "", code: 0, killed: false)
        }
        #expect(try await manager.updateWithResult(nil).message == "Packages are already up to date")
        let warnings = LockedState<[String]>([])
        manager.setProgressCallback { event in
            if event.type == "progress", let message = event.message { warnings.withLock { $0.append(message) } }
        }
        manager.setCommandRunnerForTests { _, args, _ in
            ExecResult(stdout: args.contains("view") ? "2.0.0\n" : "", stderr: "", code: 0, killed: false)
        }
        #expect(try await manager.updateWithResult(nil).message == "No packages were updated, see the warnings above")
        #expect(warnings.withLock { $0 } == ["npm:sample is still 1.0.0 (registry reports 2.0.0); npm registry metadata may be stale, try again in a few minutes"])
        let offline = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: settings, offline: true)
        #expect(try await offline.updateWithResult(nil).message == "Skipped package updates (offline mode)")
    }

    // cd6a8f7f3, package-manager.test.ts:2995-3015.
    @Test func refreshesUnpinnedTemporaryNpmAndKeepsCachedCopyOnFailure() async throws {
        #if canImport(CryptoKit)
        let name = "ctb-refresh-\(UUID().uuidString.lowercased())"
        let hash = SHA256.hash(data: Data("npm-".utf8)).map { String(format: "%02x", $0) }.joined()
        let packageDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pi-extensions/npm/\(hash.prefix(8))/node_modules/\(name)")
        try FileManager.default.createDirectory(at: packageDir.appendingPathComponent("extensions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageDir) }
        try "{\"name\":\"\(name)\",\"version\":\"1.0.0\"}".write(to: packageDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "// cached".write(to: packageDir.appendingPathComponent("extensions/main.swift"), atomically: true, encoding: .utf8)
        let calls = LockedState<[[String]]>([])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-npm-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: .inMemory())
        manager.setCommandRunnerForTests { _, args, _ in
            calls.withLock { $0.append(args) }
            if args.first == "view" { return ExecResult(stdout: "1.1.0", stderr: "", code: 0, killed: false) }
            throw URLError(.notConnectedToInternet)
        }
        let resolved = try await manager.resolveExtensionSources(["npm:\(name)"], options: .init(temporary: true))
        #expect(calls.withLock { $0.contains { $0.contains("\(name)@latest") } })
        #expect(resolved.extensions.contains { $0.path.hasSuffix("extensions/main.swift") })
        // package-manager.test.ts:3017-3035: current and pinned sources do not refresh.
        calls.withLock { $0 = [] }
        manager.setCommandRunnerForTests { _, args, _ in
            calls.withLock { $0.append(args) }
            if args.first == "view" { return ExecResult(stdout: "1.0.0", stderr: "", code: 0, killed: false) }
            Issue.record("An up-to-date or pinned package must not install")
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        }
        _ = try await manager.resolveExtensionSources(["npm:\(name)"], options: .init(temporary: true))
        _ = try await manager.resolveExtensionSources(["npm:\(name)@1.0.0"], options: .init(temporary: true))
        #expect(calls.withLock { $0.filter { $0.first == "view" }.count } == 1)
        #endif
    }

    // 342514bdf and 806cdd68e, package-manager.ts:1210-1282.
    @Test func mixedUpdateEmitsOrderedResultsAfterChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-mixed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["changed", "same", "warned"] {
            let dir = root.appendingPathComponent(".pi/npm/node_modules/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{\"version\":\"1.0.0\"}".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        }
        let gitDir = root.appendingPathComponent(".pi/git/github.com/test/extension")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let settings = SettingsManager.inMemory()
        settings.setProjectPackages([.simple("git:github.com/test/extension"), .simple("npm:changed"), .simple("npm:same"), .simple("npm:warned")])
        let manager = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: settings)
        let gitHead = LockedState("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let events = LockedState<[ProgressEvent]>([])
        manager.setProgressCallback { event in events.withLock { $0.append(event) } }
        manager.setCommandRunnerForTests { command, args, cwd in
            if command == "git" {
                if args == ["rev-parse", "HEAD"] { return ExecResult(stdout: gitHead.withLock { $0 }, stderr: "", code: 0, killed: false) }
                if args == ["rev-parse", "@{upstream}"] { return ExecResult(stdout: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", stderr: "", code: 0, killed: false) }
                if args.first == "reset" { gitHead.withLock { $0 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } }
                return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
            }
            if args.first == "view" {
                let version = args.contains("same") ? "1.0.0" : args.contains("warned") ? "2.0.0" : "1.1.0"
                return ExecResult(stdout: version, stderr: "", code: 0, killed: false)
            }
            if args.contains("changed@latest") {
                let prefix = args.firstIndex(of: "--prefix").map { args[$0 + 1] } ?? cwd
                try "{\"version\":\"1.1.0\"}".write(to: URL(fileURLWithPath: prefix).appendingPathComponent("node_modules/changed/package.json"), atomically: true, encoding: .utf8)
            }
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        }
        let summary = try await manager.updateWithResult(nil)
        let all = events.withLock { $0 }
        let results = all.filter { $0.type == "result" }
        #expect(results.map(\.source) == ["npm:changed", "git:github.com/test/extension"])
        #expect(results.map(\.message) == ["npm:changed (project) 1.0.0 -> 1.1.0", "git:github.com/test/extension (project) aaaaaaa -> bbbbbbb"])
        #expect(all.last?.type == "result")
        #expect(summary.updated == results.compactMap(\.message))
        #expect(summary.message == "Updated 2 packages:\n  npm:changed (project) 1.0.0 -> 1.1.0\n  git:github.com/test/extension (project) aaaaaaa -> bbbbbbb")
        #expect(all.contains { $0.type == "progress" && $0.source == "npm:warned" && ($0.message?.contains("is still 1.0.0") ?? false) })
        let offline = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: settings, offline: true)
        #expect(try await offline.updateWithResult(nil).message == "Skipped package updates (offline mode)")
    }

    #if canImport(AppKit)
    // e7a0df27c, image-processing.test.ts:194-205.
    @Test func picksJPEGOverLargerPNGWhenResizingPhoto() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        var seed: UInt32 = 1
        for y in 0..<80 {
            for x in 0..<120 {
                seed = seed &* 1_103_515_245 &+ 12_345
                let noise = CGFloat(seed % 6) / 255
                rep.setColor(NSColor(calibratedRed: CGFloat(x) / 120 + noise,
                    green: CGFloat(y) / 80 + noise, blue: 0.5 + noise, alpha: 1), atX: x, y: y)
            }
        }
        let input = try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
        let result = resizeImage(ImageContent(data: input.base64EncodedString(), mimeType: "image/jpeg"),
            options: .init(maxWidth: 100, maxHeight: 100))
        #expect(result.wasResized)
        #expect(result.mimeType == "image/jpeg")
        #expect(result.width == 100)
    }
    #endif

    #if os(macOS) || os(Linux)
    // c60de42e9, exec.test.ts:7-23.
    @Test(.timeLimit(.minutes(1))) func reportsSpawnErrorsInStderr() async throws {
        let result = try await execCommand("/no-such-command-\(UUID().uuidString)", [], "/")
        #expect(result.code == 1)
        #expect(!result.killed)
        #expect(!result.truncated)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }

    // c466a3595, exec.test.ts: zero cap and combined cap cases.
    @Test(.timeLimit(.minutes(1))) func capsCombinedOutputAndReportsTruncation() async throws {
        let zero = try await execCommand("/bin/sh", ["-c", "printf x"], "/", .init(maxBuffer: 0))
        #expect(zero.stdout.isEmpty)
        #expect(zero.truncated && zero.killed && zero.code != 0)
        let combined = try await execCommand("/bin/sh", ["-c", "printf abc; printf def >&2; sleep 1"], "/", .init(maxBuffer: 4))
        #expect(combined.stdout.utf8.count + combined.stderr.utf8.count == 4)
        #expect(combined.truncated && combined.killed && combined.code != 0)
    }

    @Test(.timeLimit(.minutes(1))) func doesNotAddReplacementForTruncatedUTF8Suffix() async throws {
        let result = try await execCommand("/bin/sh", ["-c", "printf '\\342\\202\\254x'"], "/", .init(maxBuffer: 2))
        #expect(result.stdout.isEmpty)
        #expect(result.truncated)
    }

    // 36be9c612, exec-utf8-chunks.test.ts: multibyte text across process reads.
    @Test(.timeLimit(.minutes(1))) func decodesUTF8AcrossProcessChunks() async throws {
        let result = try await execCommand("/bin/sh", ["-c", "printf '\\342'; sleep 0.01; printf '\\202'; sleep 0.01; printf '\\254'"], "/")
        #expect(result.stdout == "€")
        #expect(result.code == 0 && !result.truncated)
    }

    // c466a3595, exec.test.ts: normal EOF flushes incomplete input and in-cap bytes stay intact.
    @Test(.timeLimit(.minutes(1))) func normalEOFAndInCapOutputRemainIntact() async throws {
        let incomplete = try await execCommand("/bin/sh", ["-c", "printf '\\342'"], "/")
        #expect(incomplete.stdout == "�")
        #expect(incomplete.stderr.isEmpty)
        #expect(!incomplete.truncated)
        let withinCap = try await execCommand("/bin/sh", ["-c", "printf abc; printf def >&2"], "/", .init(maxBuffer: 6))
        #expect(withinCap.stdout == "abc" && withinCap.stderr == "def")
        #expect(!withinCap.truncated && !withinCap.killed)
    }

    @Test(.timeLimit(.minutes(1))) func invalidMaxBufferFailsBeforeSpawn() async {
        do {
            _ = try await execCommand("/bin/sh", ["-c", "exit 0"], "/", .init(maxBuffer: -1))
            Issue.record("Expected invalid maxBuffer")
        } catch {
            #expect(error.localizedDescription.contains("maxBuffer"))
        }
    }

    // c466a3595, exec.ts:78-93: SIGTERM is followed by SIGKILL after the grace period.
    @Test(.timeLimit(.minutes(1))) func outputCapEscalatesWhenChildIgnoresTermination() async throws {
        let started = Date()
        let result = try await execCommand("/bin/sh", ["-c", "trap '' TERM; printf xx; while :; do :; done"], "/",
            .init(maxBuffer: 1, terminationGracePeriod: 0.05))
        #expect(result.truncated && result.killed)
        #expect(result.stdout == "x")
        #expect(Date().timeIntervalSince(started) < 2)
    }

    // 27cc6bfc0, shell.ts: a shell repeatedly forks while cancellation stops it.
    @Test(.timeLimit(.minutes(1))) func stopsShellThatForksInLoop() async throws {
        let result = try await execCommand("/bin/sh", ["-c", "while :; do sleep 0.01; done"], "/", .init(timeout: 0.2))
        #expect(result.killed)
    }
    #endif

    #if os(macOS) || os(Linux)
    // 081a6e87f, auth-storage.test.ts: alias and real path contend for one lock.
    @Test(.timeLimit(.minutes(1))) func symlinkedAuthPathSharesLockWithRealFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-auth-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("auth.json")
        let alias = directory.appendingPathComponent("alias.json")
        try "{}".write(to: real, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = FileAuthStorageBackend(real.path)
        let owner = Task.detached {
            try first.withLock { _ in
                held.signal()
                _ = release.wait(timeout: .now() + 5)
                return AuthStorageLockResult(result: (), next: nil)
            }
        }
        let lockHeld = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: held.wait(timeout: .now() + 2) == .success)
            }
        }
        #expect(lockHeld)
        let second = FileAuthStorageBackend(alias.path)
        second.setLockOptionsForTesting(AuthLockOptions(maxAttempts: 1, initialDelayMs: 1, maxDelayMs: 1))
        do {
            try second.withLock { _ in AuthStorageLockResult(result: (), next: nil) }
            Issue.record("Alias entered lock held on the real path")
        } catch {
            #expect(error.localizedDescription.contains("lock"))
        }
        release.signal()
        _ = try await owner.value
    }
    #endif
}
