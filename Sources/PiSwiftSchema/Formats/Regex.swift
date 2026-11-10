// Port of packages/schema/src/formats/typebox/regex.ts at pi-mono v1.5.2.
func isRegex(_ value: String) -> Bool {
    // Upstream compiles new RegExp(value, "u"). Syntax is checked without
    // building a matching regex, so hostile input cannot trigger backtracking.
    var syntax = RegexSyntax(value)
    return syntax.isValid()
}
