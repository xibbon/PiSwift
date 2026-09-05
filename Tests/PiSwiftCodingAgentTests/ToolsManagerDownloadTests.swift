import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct DownloadTestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func downloadTestExtract(_ args: [String], binary: String) throws {
    let flag = try #require(args.firstIndex(of: "-C"))
    let directory = URL(fileURLWithPath: args[flag + 1]).appendingPathComponent("nested/release")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("binary fixture".utf8).write(to: directory.appendingPathComponent(binary))
}

@Suite("Tool downloads")
struct ToolsManagerDownloadTests {
    @Test func releaseRedirectsUseManualPolicyAndDecodeTags() async throws {
        let cases = [
            ("https://github.com/sharkdp/fd/releases/tag/v10.4.2", "10.4.2"),
            ("/sharkdp/fd/releases/tag/v10.4.2", "10.4.2"),
            ("https://github.com/BurntSushi/ripgrep/releases/tag/15.2.0", "15.2.0"),
            ("/sharkdp/fd/releases/tag/v10%2E4%2E2", "10.4.2"),
        ]
        for (location, expected) in cases {
            let version = try await getLatestVersion("sharkdp/fd", transport: { request, follows in
                #expect(request.url?.absoluteString == "https://github.com/sharkdp/fd/releases/latest")
                #expect(!follows)
                #expect(request.timeoutInterval == 10)
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "pi-coding-agent")
                return ManagementHTTPResponse(statusCode: 302, headers: ["Location": location], body: Data("unused redirect body".utf8))
            })
            #expect(version == expected)
        }
    }

    @Test func invalidRedirectsGiveSpecificErrors() async {
        for (status, location, expected) in [
            (404, "", "HTTP 404 without redirect"),
            (200, "/sharkdp/fd/releases/tag/v1", "HTTP 200 without redirect"),
            (302, "", "HTTP 302 without redirect"),
            (302, "https://github.com/login", "unexpected redirect to https://github.com/login"),
            (302, "/sharkdp/fd/releases/tag/", "unexpected redirect to /sharkdp/fd/releases/tag/"),
        ] {
            do {
                _ = try await getLatestVersion("sharkdp/fd", transport: { _, _ in
                    ManagementHTTPResponse(statusCode: status, headers: ["location": location])
                })
                Issue.record("Expected an invalid redirect error")
            } catch {
                #expect(error.localizedDescription == "Failed to resolve latest sharkdp/fd release: \(expected)")
            }
        }
    }

    @Test func assetsUseMuslForBothLinuxArchitectures() {
        for tool in ["fd", "rg"] {
            for architecture in ["x64", "arm64"] {
                let prefix = tool == "fd" ? "fd-v1.2.3" : "ripgrep-1.2.3"
                let arch = architecture == "arm64" ? "aarch64" : "x86_64"
                #expect(toolDownloadAssetName(tool, version: "1.2.3", platform: "linux", architecture: architecture) == "\(prefix)-\(arch)-unknown-linux-musl.tar.gz")
                #expect(toolDownloadAssetName(tool, version: "1.2.3", platform: "darwin", architecture: architecture) == "\(prefix)-\(arch)-apple-darwin.tar.gz")
                #expect(toolDownloadAssetName(tool, version: "1.2.3", platform: "win32", architecture: architecture) == "\(prefix)-\(arch)-pc-windows-msvc.zip")
            }
        }
        #expect(toolDownloadAssetName("fd", version: "1", platform: "ios", architecture: "arm64") == nil)
    }

    @Test func offlineFlagsReportOnlyCallbackStatus() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        for flag in ["1", "true", "TRUE", "yes", "YES"] {
            let statuses = LockedState<[ToolStatus]>([])
            let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", environment: ["PI_OFFLINE": flag], transport: { _, _ in
                Issue.record("Offline mode must not send an HTTP request")
                throw URLError(.notConnectedToInternet)
            })
            #expect(await manager.ensureTool("fd", onStatus: { status in statuses.withLock { $0.append(status) } }) == nil)
            #expect(statuses.withLock { $0.map(\.message) } == ["fd not found. Offline mode enabled, skipping download."])
            #expect(statuses.withLock { $0.first?.type } == .warning)
            #expect(await manager.ensureTool("rg") == nil)
        }
    }

    @Test func iosDoesNotDownloadOrExecute() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        let statuses = LockedState<[ToolStatus]>([])
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "ios", environment: [:], transport: { _, _ in
            Issue.record("iOS must not download binaries")
            throw URLError(.unsupportedURL)
        })
        #expect(await manager.ensureTool("fd", onStatus: { status in statuses.withLock { $0.append(status) } }) == nil)
        #expect(statuses.withLock { $0.first?.message } == "fd not found. Tool installation is unavailable on this platform.")
    }

    @Test func errorCauseChainIsPreservedAfterRetries() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        let statuses = LockedState<[ToolStatus]>([])
        let attempts = LockedState(0)
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", architecture: "arm64", environment: [:], transport: { _, _ in
            attempts.withLock { $0 += 1 }
            let cause = DownloadFailure(message: "connect ETIMEDOUT 140.82.113.3:443")
            throw DownloadFailure(message: "fetch failed", cause: cause)
        })
        #expect(await manager.ensureTool("fd", onStatus: { status in statuses.withLock { $0.append(status) } }) == nil)
        #expect(attempts.withLock { $0 } == 3)
        #expect(statuses.withLock { $0.map(\.message) } == ["fd not found. Downloading...", "Failed to download fd: fetch failed: connect ETIMEDOUT 140.82.113.3:443"])
    }

    @Test func pinnedIntelFdSkipsReleaseLookupAndInstallsNestedBinary() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        let requests = LockedState<[String]>([])
        let statuses = LockedState<[ToolStatus]>([])
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", architecture: "x64", environment: [:], transport: { request, follows in
            requests.withLock { $0.append(request.url!.absoluteString) }
            #expect(follows)
            #expect(request.timeoutInterval == 120)
            return ManagementHTTPResponse(statusCode: 200, body: Data("archive fixture".utf8))
        }, commandRunner: { command, args, _ in
            #expect(command == "tar")
            #expect(args.first == "xzf")
            try downloadTestExtract(args, binary: "fd")
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        })
        let path = try #require(await manager.ensureTool("fd", onStatus: { status in statuses.withLock { $0.append(status) } }))
        #expect(requests.withLock { $0 } == ["https://github.com/sharkdp/fd/releases/download/v10.3.0/fd-v10.3.0-x86_64-apple-darwin.tar.gz"])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "binary fixture")
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path("bin")) == ["fd"])
        #expect(statuses.withLock { $0.map(\.type) } == [.info, .info])
        #expect(await manager.ensureTool("fd") == path)
        #expect(requests.withLock { $0.count } == 1)
    }

    @Test func unpinnedRipgrepResolvesReleaseBeforeDownload() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        let requests = LockedState<[(String, Bool)]>([])
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "linux", architecture: "arm64", environment: [:], transport: { request, follows in
            requests.withLock { $0.append((request.url!.absoluteString, follows)) }
            if request.url!.path.hasSuffix("/latest") {
                return ManagementHTTPResponse(statusCode: 302, headers: ["location": "/BurntSushi/ripgrep/releases/tag/15.2.0"])
            }
            return ManagementHTTPResponse(statusCode: 200, body: Data())
        }, commandRunner: { _, args, _ in
            try downloadTestExtract(args, binary: "rg")
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        })
        #expect(await manager.ensureTool("rg") != nil)
        #expect(requests.withLock { $0.map(\.1) } == [false, true])
        #expect(requests.withLock { $0.last?.0 } == "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz")
    }

    @Test func cachedToolsPrecedePathAndFdAcceptsFdfind() throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        try FileManager.default.createDirectory(atPath: directory.path("path"), withIntermediateDirectories: true)
        let alternative = directory.path("path/fdfind")
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: alternative))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: alternative)
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", environment: ["PATH": directory.path("path")])
        #expect(manager.getToolPath("fd") == alternative)
        try FileManager.default.createDirectory(atPath: directory.path("bin"), withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: directory.path("bin/fd")))
        #expect(manager.getToolPath("fd") == directory.path("bin/fd"))
    }

    @Test func downloadAndExtractionFailuresRemoveTemporaryFiles() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        for downloadFails in [true, false] {
            let statuses = LockedState<[ToolStatus]>([])
            let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", architecture: "x64", environment: [:], transport: { _, _ in
                ManagementHTTPResponse(statusCode: downloadFails ? 404 : 200, body: Data("archive".utf8))
            }, commandRunner: { _, _, _ in
                #expect(!downloadFails)
                return ExecResult(stdout: "", stderr: "bad archive", code: 2, killed: false)
            })
            #expect(await manager.ensureTool("fd", onStatus: { status in statuses.withLock { $0.append(status) } }) == nil)
            let error = try #require(statuses.withLock { $0.last?.message })
            #expect(error.contains(downloadFails ? "Download failed with HTTP 404: https://github.com/" : "tar: bad archive"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path("bin")).isEmpty)
        }
    }

    @Test func concurrentInstallsUseSeparateExtractionDirectories() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        let extractionDirectories = LockedState<[String]>([])
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", architecture: "x64", environment: [:], transport: { _, _ in
            ManagementHTTPResponse(statusCode: 200, body: Data("archive".utf8))
        }, commandRunner: { _, args, _ in
            extractionDirectories.withLock { $0.append(args.last!) }
            try downloadTestExtract(args, binary: "fd")
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        })
        async let first = manager.ensureTool("fd")
        async let second = manager.ensureTool("fd")
        let paths = await [first, second]
        #expect(paths.allSatisfy { $0 != nil })
        #expect(paths[0] == paths[1])
        #expect(extractionDirectories.withLock { Set($0).count == $0.count })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path("bin")) == ["fd"])
    }

    #if os(macOS)
    @Test func realTarArchiveUsesExecCommandAndInstallsExecutable() async throws {
        let directory = try DownloadTestDirectory()
        defer { directory.remove() }
        try FileManager.default.createDirectory(atPath: directory.path("source/deep"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf fixture".utf8).write(to: URL(fileURLWithPath: directory.path("source/deep/fd")))
        let archive = directory.path("fixture.tar.gz")
        let packed = try await execCommand("tar", ["czf", archive, "-C", directory.path("source"), "."], directory.url.path)
        #expect(packed.code == 0)
        let archiveData = try Data(contentsOf: URL(fileURLWithPath: archive))
        let manager = ToolManager(toolsDirectory: directory.path("bin"), platform: "darwin", architecture: "x64", environment: [:], transport: { _, _ in
            ManagementHTTPResponse(statusCode: 200, body: archiveData)
        })
        let installed = try #require(await manager.ensureTool("fd"))
        #expect(FileManager.default.isExecutableFile(atPath: installed))
        #expect(try String(contentsOfFile: installed, encoding: .utf8) == "#!/bin/sh\nprintf fixture")
    }
    #endif
}

private struct DownloadFailure: LocalizedError, ErrorWithCause {
    var message: String
    var cause: (any Error)? = nil
    var errorDescription: String? { message }
}
