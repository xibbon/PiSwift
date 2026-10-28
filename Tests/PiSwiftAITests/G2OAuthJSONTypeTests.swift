import Foundation
import Testing
@testable import PiSwiftAI

@Test(arguments: ["interval", "expires_in"], ["true", "false", "0", "1"])
func g2OAuthNumericFieldsKeepJSONTypes(_ field: String, _ raw: String) throws {
    let object = try #require(JSONSerialization.jsonObject(with: Data("{\"\(field)\":\(raw)}".utf8)) as? [String: Any])
    let number = oauthJSONNumber(object[field])
    if raw == "true" || raw == "false" {
        #expect(number == nil)
    } else {
        #expect(number == Double(raw))
    }
}

@Test func g2CopilotCatalogKeepsJSONBooleanTypes() throws {
    let data = Data(#"{"data":[{"id":"numeric-picker","model_picker_enabled":1},{"id":"numeric-support","model_picker_enabled":true,"capabilities":{"supports":{"tool_calls":0}}},{"id":"boolean-disabled","model_picker_enabled":true,"capabilities":{"supports":{"tool_calls":false}}}]}"#.utf8)
    let raw = try JSONSerialization.jsonObject(with: data)
    let catalog = try parseGitHubCopilotModelCatalog(raw, allowPolicyFallback: false)
    #expect(catalog.availableModelIds == ["numeric-support"])
}

@Test(arguments: ["true", "false", "0", "1"])
func g2CopilotPickerRequiresLiteralTrue(_ picker: String) throws {
    let json = "{\"data\":[{\"id\":\"model\",\"model_picker_enabled\":\(picker)}]}"
    let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let catalog = try parseGitHubCopilotModelCatalog(raw, allowPolicyFallback: false)
    #expect(catalog.availableModelIds == (picker == "true" ? ["model"] : []))
}

@Test(arguments: ["true", "false", "0", "1"])
func g2CopilotToolSupportRejectsOnlyLiteralFalse(_ support: String) throws {
    let json = "{\"data\":[{\"id\":\"model\",\"model_picker_enabled\":true,\"capabilities\":{\"supports\":{\"tool_calls\":\(support)}}}]}"
    let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let catalog = try parseGitHubCopilotModelCatalog(raw, allowPolicyFallback: false)
    #expect(catalog.availableModelIds == (support == "false" ? [] : ["model"]))
}

@Test(arguments: ["true", "false", "0", "1"])
func g2XaiDeviceIntervalRequiresJSONNumber(_ interval: String) throws {
    let json = "{\"device_code\":\"device\",\"user_code\":\"code\",\"verification_uri\":\"https://auth.x.ai/device\",\"expires_in\":60,\"interval\":\(interval)}"
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let device = try parseXaiDeviceCode(object)
    #expect(device.intervalSeconds == (interval == "1" ? 1 : nil))
}

@Test(arguments: ["true", "false", "0", "1"])
func g2KimiTokenExpiryRequiresPositiveJSONNumber(_ expiry: String) throws {
    let json = "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":\(expiry)}"
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    if expiry == "1" {
        #expect(try kimiCodingCredentials(object, operation: "test").access == "access")
    } else {
        #expect(throws: OAuthError.self) {
            _ = try kimiCodingCredentials(object, operation: "test")
        }
    }
}

@Test(arguments: ["true", "false", "0", "1"])
func g2XaiTokenExpiryRequiresPositiveJSONNumber(_ expiry: String) async throws {
    try await codexRequestLock.withLock {
        MockURLProtocol.allowedHosts.withLock { $0 = ["auth.x.ai"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                       headerFields: ["content-type": "application/json"]))
            return (response, Data("{\"access_token\":\"token\",\"expires_in\":\(expiry)}".utf8))
        } }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            MockURLProtocol.requestHandler.withLock { $0 = nil }
        }
        if expiry == "1" {
            let result = try await refreshXaiToken("refresh")
            #expect(result.access == "token")
        } else {
            await #expect(throws: OAuthError.self) {
                _ = try await refreshXaiToken("refresh")
            }
        }
    }
}
