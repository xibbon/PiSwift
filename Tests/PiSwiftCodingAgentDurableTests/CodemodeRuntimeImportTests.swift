import PiSwiftCodingAgent
import PiSwiftCodemodeRuntime
import PiSwiftDurable
import protocol PiSwiftDurable.CodemodeSandbox
import Testing

@Test func codemodeRuntimeAndDurableSandboxNamesCompile() {
    let durableProtocol: (any CodemodeSandbox).Type = (any PiSwiftDurable.CodemodeSandbox).self
    let legacyEngine: PiSwiftCodingAgent.CodemodeSandbox.Type = JSCCodemodeEngine.self
    #expect(durableProtocol == (any PiSwiftDurable.CodemodeSandbox).self)
    #expect(legacyEngine == JSCCodemodeEngine.self)
}
