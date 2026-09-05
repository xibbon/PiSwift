import Foundation
import PiSwiftAI

public func areExperimentalFeaturesEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PI_EXPERIMENTAL"] == "1"
}

public func getExperimentalToolSampling(environment: [String: String] = ProcessInfo.processInfo.environment) -> ConstrainedSampling? {
    areExperimentalFeaturesEnabled(environment: environment) ? .jsonSchema(strict: .prefer) : nil
}
