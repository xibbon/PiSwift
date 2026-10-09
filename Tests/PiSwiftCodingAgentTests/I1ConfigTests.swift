import Foundation
import Testing
import TestEnvironmentSupport
import PiSwiftCodingAgent

@Test(.processEnvironment, arguments: ["~/x", "~", "~/x/../y", "~/x//", "~other/x", "/absolute/x"])
func i1AgentDirExpandsLeadingTilde(override: String) {
    let previous = ProcessInfo.processInfo.environment[ENV_AGENT_DIR]
    setenv(ENV_AGENT_DIR, override, 1)
    defer {
        if let previous { setenv(ENV_AGENT_DIR, previous, 1) }
        else { unsetenv(ENV_AGENT_DIR) }
    }
    let expected: String
    if override == "~/x" { expected = URL(fileURLWithPath: getHomeDir()).appendingPathComponent("x").path }
    else if override == "~" { expected = getHomeDir() }
    else if override == "~/x/../y" { expected = URL(fileURLWithPath: getHomeDir()).appendingPathComponent("y").path }
    else if override == "~/x//" { expected = URL(fileURLWithPath: getHomeDir()).appendingPathComponent("x").path }
    else { expected = override }
    #expect(getAgentDir() == expected)
}
