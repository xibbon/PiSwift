// Port of packages/schema/src/formats/typebox/hostname.ts at pi-mono v1.5.2.
func isHostname(_ value: String) -> Bool { idnaIsHostname(value) }
