import Foundation

private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        let millions = Double(count) / 1_000_000.0
        return millions.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(millions))M" : String(format: "%.1fM", millions)
    }
    if count >= 1_000 {
        let thousands = Double(count) / 1_000.0
        return thousands.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(thousands))K" : String(format: "%.1fK", thousands)
    }
    return "\(count)"
}

public func listModels(_ modelRegistry: ModelRegistry, _ searchPattern: String? = nil) async {
    if let error = modelRegistry.getError() {
        fputs("Warning: \(error)\n", stderr)
    }

    let models = await modelRegistry.getAvailable()
    if models.isEmpty {
        print("No models available. Set API keys in environment variables.")
        return
    }

    var filtered = models
    if let searchPattern, !searchPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        filtered = fuzzyFilter(models, searchPattern) { model in
            "\(model.provider) \(model.id)"
        }
    }

    if filtered.isEmpty {
        print("No models matching \"\(searchPattern ?? "")\"")
        return
    }

    filtered.sort {
        if $0.provider == $1.provider {
            return $0.id < $1.id
        }
        return $0.provider < $1.provider
    }

    let rows = filtered.map { model in
        (
            provider: model.provider,
            model: model.id,
            context: formatTokenCount(model.contextWindow),
            maxOut: formatTokenCount(model.maxTokens),
            thinking: model.reasoning ? "yes" : "no",
            images: model.input.contains(.image) ? "yes" : "no"
        )
    }

    let headers = (provider: "provider", model: "model", context: "context", maxOut: "max-out", thinking: "thinking", images: "images")
    let widths = (
        provider: max(headers.provider.count, rows.map { $0.provider.count }.max() ?? 0),
        model: max(headers.model.count, rows.map { $0.model.count }.max() ?? 0),
        context: max(headers.context.count, rows.map { $0.context.count }.max() ?? 0),
        maxOut: max(headers.maxOut.count, rows.map { $0.maxOut.count }.max() ?? 0),
        thinking: max(headers.thinking.count, rows.map { $0.thinking.count }.max() ?? 0),
        images: max(headers.images.count, rows.map { $0.images.count }.max() ?? 0)
    )

    let headerLine = [
        headers.provider.padding(toLength: widths.provider, withPad: " ", startingAt: 0),
        headers.model.padding(toLength: widths.model, withPad: " ", startingAt: 0),
        headers.context.padding(toLength: widths.context, withPad: " ", startingAt: 0),
        headers.maxOut.padding(toLength: widths.maxOut, withPad: " ", startingAt: 0),
        headers.thinking.padding(toLength: widths.thinking, withPad: " ", startingAt: 0),
        headers.images.padding(toLength: widths.images, withPad: " ", startingAt: 0),
    ].joined(separator: "  ")
    print(headerLine)

    for row in rows {
        let line = [
            row.provider.padding(toLength: widths.provider, withPad: " ", startingAt: 0),
            row.model.padding(toLength: widths.model, withPad: " ", startingAt: 0),
            row.context.padding(toLength: widths.context, withPad: " ", startingAt: 0),
            row.maxOut.padding(toLength: widths.maxOut, withPad: " ", startingAt: 0),
            row.thinking.padding(toLength: widths.thinking, withPad: " ", startingAt: 0),
            row.images.padding(toLength: widths.images, withPad: " ", startingAt: 0),
        ].joined(separator: "  ")
        print(line)
    }
}
