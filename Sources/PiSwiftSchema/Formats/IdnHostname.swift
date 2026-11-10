// Port of packages/schema/src/formats/typebox/idn_hostname.ts, pi-mono v1.5.2.
import Foundation

// The upstream package entry point exports only `formats`; this function is internal.
func isIdnHostname(_ value: String) -> Bool { idnaIsIdnHostname(value) }
