import Foundation
import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

@Test func markCodingAgentEnvironmentSetsDetectionFlag() {
    let previous = ProcessInfo.processInfo.environment[ENV_CODING_AGENT]
    defer {
        if let previous {
            setenv(ENV_CODING_AGENT, previous, 1)
        } else {
            unsetenv(ENV_CODING_AGENT)
        }
    }

    unsetenv(ENV_CODING_AGENT)
    markCodingAgentEnvironment()

    #expect(ProcessInfo.processInfo.environment[ENV_CODING_AGENT] == "true")
}

