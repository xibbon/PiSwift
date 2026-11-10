// Port of packages/schema/src/formats/typebox/idna/label/ascii.ts, pi-mono v1.5.2.
import Foundation

enum IdnaAsciiLabel {
    // IsAsciiLabel
    static func isAsciiLabel(_ value: String) -> Bool {
        IdnaPattern.reRuleHyphenPlacement(value)
            && IdnaPattern.reRuleNotReservedAce(value)
            && IdnaPattern.reAsciiLDH(value)
    }
}
