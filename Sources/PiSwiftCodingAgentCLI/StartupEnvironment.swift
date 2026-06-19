import Foundation
import PiSwiftCodingAgent

func markCodingAgentEnvironment() {
    setenv(ENV_CODING_AGENT, "true", 1)
}

