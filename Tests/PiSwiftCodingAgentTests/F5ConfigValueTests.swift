import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

// Port of resolve-config-value.test.ts and the v0.99.1 parser/helper rules.
@Test(arguments: [
    ("literal-key", "literal-key"), ("LEFT", "LEFT"), ("$LEFT", "left"),
    ("${LEFT}_$RIGHT", "left_right"), ("$$LEFT", "$LEFT"),
    ("$!literal-$RIGHT", "!literal-right"), ("", ""),
    ("${BAD-NAME}", "${BAD-NAME}"), ("$9", "$9"), ("${}", "${}"),
    ("${LEFT", "${LEFT"), ("tail$", "tail$"), ("$é", "$é"),
    ("$$$LEFT", "$left"), ("${LEFT}suffix", "leftsuffix"), ("$LEFT\u{0301}", "left\u{0301}")
]) func f5ConfigTemplates(_ pair: (String, String)) {
    #expect(resolveConfigValue(pair.0, env: ["LEFT": "left", "RIGHT": "right"]) == pair.1)
    #expect(resolveConfigValueUncached(pair.0, env: ["LEFT": "left", "RIGHT": "right"]) == pair.1)
}

@Test func f5ConfigHelpersAndErrors() throws {
    let missing = "PI_SWIFT_F5_MISSING_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    #expect(getConfigValueEnvVarName("${LEFT}") == "LEFT")
    #expect(getConfigValueEnvVarName("$LEFT") == "LEFT")
    #expect(getConfigValueEnvVarName("LEFT") == nil)
    #expect(getConfigValueEnvVarName("$LEFT-$RIGHT") == nil)
    #expect(getConfigValueEnvVarNames("$LEFT-${RIGHT}-$LEFT-$$ESCAPED") == ["LEFT", "RIGHT"])
    #expect(getConfigValueEnvVarNames("!echo $LEFT").isEmpty)
    #expect(isCommandConfigValue("!exit 1"))
    #expect(!isCommandConfigValue("$!literal"))
    #expect(isConfigValueConfigured("!exit 1"))
    #expect(isConfigValueConfigured("BARE"))
    #expect(!isConfigValueConfigured("$\(missing)"))
    #expect(resolveConfigValue("$\(missing)") == nil)
    #expect(resolveConfigValue("$LEFT", env: ["LEFT": "one"]) == "one")
    #expect(resolveConfigValue("$LEFT", env: ["LEFT": "two"]) == "two")
    #expect(getMissingConfigValueEnvVarNames("$\(missing)-$LEFT-$\(missing)", env: ["LEFT": "value"]) == [missing])
    do {
        _ = try resolveConfigValueOrThrow("$\(missing)", description: "API key for provider \"test\"")
        Issue.record("Expected missing variable")
    } catch {
        #expect(error.localizedDescription == "Failed to resolve API key for provider \"test\" from environment variable: \(missing)")
    }
    do {
        _ = try resolveConfigValueOrThrow("$\(missing)-${\(missing)_B}-$\(missing)", description: "value")
        Issue.record("Expected missing variables")
    } catch {
        #expect(error.localizedDescription == "Failed to resolve value from environment variables: \(missing), \(missing)_B")
    }
    #expect(try resolveConfigValueOrThrow("", description: "empty") == "")
    #expect(resolveHeaders(["Empty": "", "Missing": "$\(missing)", "Value": "$LEFT"], env: ["LEFT": "left"]) == ["Value": "left"])
    #expect(try resolveHeadersOrThrow(["Empty": ""], description: "provider") == ["Empty": ""])
    do {
        _ = try resolveHeadersOrThrow(["Missing": "$\(missing)"], description: "provider \"test\"")
        Issue.record("Expected header error")
    } catch {
        #expect(error.localizedDescription == "Failed to resolve provider \"test\" header \"Missing\" from environment variable: \(missing)")
    }
}

@Test(arguments: ["!exit 1", "!nonexistent-command-f5-12345", "!printf ''", "!printf value; exit 1"])
func f5ConfigCommandFailure(_ command: String) {
    #expect(resolveConfigValue(command) == nil)
    #expect(resolveConfigValueUncached(command) == nil)
    do {
        _ = try resolveConfigValueOrThrow(command, description: "key")
        Issue.record("Expected command failure")
    } catch {
        #expect(error.localizedDescription == "Failed to resolve key from shell command: \(command.dropFirst())")
    }
}

@Test func f5ConfigCommandOutput() {
    #expect(resolveConfigValue("!echo '  spaced-key  '") == "spaced-key")
    #expect(resolveConfigValue("!printf 'line1\\nline2'") == "line1\nline2")
    #expect(resolveConfigValue("!echo 'hello world' | tr ' ' '-'") == "hello-world")
}

// Cache clear is tested alone in the serial proof run. Other cache tests use unique commands.
@Test func f5ConfigCacheSuccessFailureAndUncached() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f5-cache-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = directory.appendingPathComponent("counter")
    let command = "!echo run >> '\(counter.path)'; printf value"
    #expect(resolveConfigValue(command) == "value")
    #expect(resolveConfigValue(command) == "value")
    #expect(try String(contentsOf: counter, encoding: .utf8) == "run\n")
    clearConfigValueCache()
    #expect(resolveConfigValue(command) == "value")
    let failure = "!echo fail >> '\(counter.path)'; exit 1"
    #expect(resolveConfigValue(failure) == nil)
    #expect(resolveConfigValue(failure) == nil)
    #expect(resolveConfigValueUncached(command) == "value")
    #expect(try resolveConfigValueOrThrow(command, description: "key") == "value")
    #expect(try String(contentsOf: counter, encoding: .utf8) == "run\nrun\nfail\nrun\nrun\n")
}

@Test func f5AuthCredentialScopedEnvironmentPersists() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f5-auth-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("auth.json").path
    let storage = AuthStorage(path)
    storage.set("custom", credential: .apiKey(ApiKeyCredential(key: "$TOKEN", env: ["TOKEN": "first", "ACCOUNT": "account"])))
    #expect(await storage.getApiKey("custom") == "first")
    #expect(storage.getProviderEnv("custom") == ["TOKEN": "first", "ACCOUNT": "account"])
    let reloaded = AuthStorage(path)
    #expect(await reloaded.getApiKey("custom") == "first")
    reloaded.set("custom", credential: .apiKey(ApiKeyCredential(key: "$TOKEN", env: ["TOKEN": "second"])))
    #expect(await storage.getApiKey("custom") == "second")
    storage.set("bare", credential: .apiKey(ApiKeyCredential(key: "TOKEN", env: ["TOKEN": "secret"])))
    #expect(await storage.getApiKey("bare") == "TOKEN")
    storage.set("missing", credential: .apiKey(ApiKeyCredential(key: "$PI_F5_ABSENT_TOKEN")))
    #expect(!storage.hasAuth("missing"))
    storage.set("command", credential: .apiKey(ApiKeyCredential(key: "!exit 1")))
    #expect(storage.hasAuth("command"))
}
