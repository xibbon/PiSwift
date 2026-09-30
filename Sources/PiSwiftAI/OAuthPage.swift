import Foundation

/// Browser pages from pi-mono v0.99.1 `utils/oauth-page.ts`.
enum OAuthPage {
    private static let template: String = {
        guard let url = Bundle.module.url(forResource: "oauth-page", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            return "<!doctype html><title>{{title}}</title><h1>{{heading}}</h1><p>{{message}}</p>{{details}}"
        }
        return html
    }()

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func render(title: String, heading: String, message: String, details: String? = nil) -> String {
        template.replacingOccurrences(of: "{{title}}", with: escaped(title))
            .replacingOccurrences(of: "{{heading}}", with: escaped(heading))
            .replacingOccurrences(of: "{{message}}", with: escaped(message))
            .replacingOccurrences(of: "{{details}}", with: details.map { "<div class=\"details\">\(escaped($0))</div>" } ?? "")
    }

    static func success(_ message: String) -> String {
        render(title: "Authentication successful", heading: "Authentication successful", message: message)
    }

    static func error(_ message: String, details: String? = nil) -> String {
        render(title: "Authentication failed", heading: "Authentication failed", message: message, details: details)
    }
}
