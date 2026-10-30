import Foundation

struct StandardSubscriptionNode: Identifiable {
    let id: Int
    let name: String
    let profile: XrayProfile?
    let rejection: String?
}

/// Plain URI lists and standard/base64url encoded URI lists. Never guesses away
/// unsupported authentication or transport options; every node has a result.
enum StandardSubscription {
    static let maximumBytes = 128 * 1024
    static let maximumNodes = 256

    static func parse(_ data: Data) throws -> [StandardSubscriptionNode] {
        guard data.count <= maximumBytes else { throw SubscriptionError.responseTooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw SubscriptionError.invalidDocument }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\u{feff}" { text.removeFirst() }
        if !text.contains("://") {
            var encoded = text.filter { !$0.isWhitespace }
            guard !encoded.isEmpty,
                  encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=_-".contains($0)) }) else {
                throw SubscriptionError.invalidDocument
            }
            encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard encoded.count % 4 != 1 else { throw SubscriptionError.invalidDocument }
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let decoded = Data(base64Encoded: encoded), decoded.count <= maximumBytes,
                  let decodedText = String(data: decoded, encoding: .utf8) else { throw SubscriptionError.invalidDocument }
            text = decodedText
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= maximumNodes else { throw SubscriptionError.invalidDocument }
        return lines.enumerated().map { index, line in
            let fallback = "Node \(index + 1)"
            guard line.utf8.count <= 16384 else {
                return StandardSubscriptionNode(id: index, name: fallback, profile: nil, rejection: "Node exceeds the size limit.")
            }
            // Names are display-only; no complete URI or credentials are retained.
            let fragment = URLComponents(string: line)?.fragment ?? ""
            let clean = String(String.UnicodeScalarView(fragment.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100)))
            let name = clean.isEmpty ? fallback : clean
            do {
                let profile = try XrayProfile.parse(line)
                return StandardSubscriptionNode(id: index, name: name, profile: profile, rejection: nil)
            } catch let error as XrayProfileError {
                return StandardSubscriptionNode(id: index, name: name, profile: nil, rejection: error.localizedDescription)
            } catch {
                return StandardSubscriptionNode(id: index, name: name, profile: nil, rejection: "Invalid node.")
            }
        }
    }
}
