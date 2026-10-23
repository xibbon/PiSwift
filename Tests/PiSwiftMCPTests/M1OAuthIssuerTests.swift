import Testing
@testable import PiSwiftMCP

@Test(arguments: [
    (nil, nil, "OAuth issuer mismatch: expected none, received none"),
    (nil, "https://attacker.example", "OAuth issuer mismatch: expected none, received \"https://attacker.example\""),
    ("https://issuer.example", nil, "OAuth issuer mismatch: expected \"https://issuer.example\", received none"),
    ("https://issuer.example/\"quoted\"", "line\nfeed", "OAuth issuer mismatch: expected \"https://issuer.example/\\\"quoted\\\"\", received \"line\\nfeed\"")
] as [(String?, String?, String)])
func m1OAuthIssuerMismatchMessage(_ expected: String?, _ received: String?, _ message: String) {
    #expect(McpOAuthError.issuerMismatch(expected: expected, received: received).errorDescription == message)
}
