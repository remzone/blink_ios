import Foundation

/// Normalizes share links without changing percent-encoded credentials or config text.
enum ProfileImportInput: Equatable {
    case subscription(String)
    case configuration(String)

    static func parse(_ source: String) throws -> ProfileImportInput {
        guard source.utf8.count <= 1_048_576 else { throw ProfileImportInputError.tooLarge }
        return try resolve(source, depth: 0)
    }

    private static func resolve(_ source: String, depth: Int) throws -> ProfileImportInput {
        guard depth < 4 else { throw ProfileImportInputError.invalidLink }
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\u{feff}" { text.removeFirst() }
        guard !text.isEmpty else { throw ProfileImportInputError.empty }
        // Only unwrap a complete Markdown/autolink, never scan arbitrary config text for URLs.
        if !text.contains("\n") {
            if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
            if text.hasPrefix("["), text.hasSuffix(")"), let split = text.range(of: "](") {
                text = String(text[split.upperBound..<text.index(before: text.endIndex)])
            }
        }
        if text.lowercased().hasPrefix("hiddify://import/") {
            var nested = String(text.dropFirst("hiddify://import/".count))
            if !nested.contains("://") { nested = nested.removingPercentEncoding ?? nested }
            return try resolve(nested, depth: depth + 1)
        }
        if let components = URLComponents(string: text),
           let scheme = components.scheme?.lowercased(),
           ["hiddify", "clash", "clashmeta"].contains(scheme) {
            let actions = scheme == "hiddify" ? ["install-config", "install-sub", "install-proxy"] : ["install-config"]
            let urls = components.queryItems?.filter { $0.name == "url" } ?? []
            guard actions.contains(components.host ?? ""), urls.count == 1,
                  let nested = urls.first?.value else { throw ProfileImportInputError.invalidLink }
            return try resolve(nested, depth: depth + 1)
        }
        if !text.contains("\n"), var components = URLComponents(string: text),
           ["http", "https"].contains(components.scheme?.lowercased() ?? "") {
            // Resolve copied HTTP links through verified HTTPS; do not fetch credentials in cleartext.
            components.scheme = "https"
            components.fragment = nil // Provider display labels are not part of the HTTP resource.
            guard let url = components.url else { throw ProfileImportInputError.invalidLink }
            return .subscription(try SecureSubscriptionHTTP.validatedURL(url.absoluteString).absoluteString)
        }
        return .configuration(text)
    }
}

enum ProfileImportInputError: LocalizedError {
    case empty, tooLarge, invalidLink
    var errorDescription: String? {
        switch self {
        case .empty: return "Вставьте ссылку или конфигурацию."
        case .tooLarge: return "Конфигурация превышает 1 МБ."
        case .invalidLink: return "Не удалось прочитать ссылку импорта. Вставьте исходную HTTPS-подписку или конфигурацию."
        }
    }
}
