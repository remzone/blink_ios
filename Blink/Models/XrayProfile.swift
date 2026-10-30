import Foundation

/// Credentials are encoded only into Keychain, not App Group files or preferences.
struct XrayProfile: Codable {
    var address: String
    var port: Int
    var uuid: String
    var network: String
    var security: String
    var serverName: String
    var fingerprint: String
    var publicKey: String
    var shortId: String
    var flow: String
    var host: String
    var path: String
    var mode: String

    static func parse(_ input: String) throws -> XrayProfile {
        guard input.utf8.count <= 16384,
              let url = URLComponents(string: input), url.scheme == "vless",
              let rawHost = url.host, !rawHost.isEmpty, rawHost.count <= 253,
              let user = url.user, UUID(uuidString: user) != nil,
              url.password == nil, let port = url.port, (1...65535).contains(port),
              url.path.isEmpty || url.path == "/" else { throw XrayProfileError.invalid }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        var parameters: [String: String] = [:]
        let supported: Set<String> = ["type", "security", "encryption", "sni", "fp", "pbk", "sid", "flow", "host", "path", "mode"]
        for item in url.queryItems ?? [] {
            guard supported.contains(item.name), parameters[item.name] == nil else { throw XrayProfileError.unsupported }
            parameters[item.name] = item.value ?? ""
        }
        guard (parameters["encryption"] ?? "none") == "none" else { throw XrayProfileError.unsupported }
        let network = parameters["type"] ?? "tcp"
        let security = parameters["security"] ?? "none"
        let flow = parameters["flow"] ?? ""
        guard ["tcp", "xhttp"].contains(network), ["none", "tls", "reality"].contains(security),
              ["", "xtls-rprx-vision"].contains(flow), !(network == "xhttp" && !flow.isEmpty) else { throw XrayProfileError.unsupported }
        // Reject irrelevant options instead of silently discarding auth/transport settings.
        if network == "tcp", ["host", "path", "mode"].contains(where: { parameters[$0] != nil }) {
            throw XrayProfileError.unsupported
        }
        if security == "none", ["sni", "fp", "pbk", "sid"].contains(where: { parameters[$0] != nil }) {
            throw XrayProfileError.unsupported
        }
        if security == "tls", ["pbk", "sid"].contains(where: { parameters[$0] != nil }) {
            throw XrayProfileError.unsupported
        }
        let serverName = parameters["sni"] ?? host
        let fingerprint = (parameters["fp"] ?? "chrome").lowercased()
        let publicKey = parameters["pbk"] ?? ""
        let shortID = parameters["sid"] ?? ""
        let path = parameters["path"] ?? "/"
        let mode = parameters["mode"] ?? "auto"
        let httpHost = parameters["host"] ?? host
        guard flow.isEmpty || security != "none" else { throw XrayProfileError.invalidSettings }
        if security != "none" {
            let fingerprints: Set<String> = ["", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized", "randomizednoalpn"]
            guard !serverName.isEmpty, serverName.utf8.count <= 253,
                  !serverName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  fingerprints.contains(fingerprint) else { throw XrayProfileError.invalidSettings }
        }
        if security == "reality" {
            let key = publicKey.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard !fingerprint.isEmpty, publicKey.count == 43,
                  publicKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  Data(base64Encoded: key + "=")?.count == 32,
                  shortID.count <= 16, shortID.count % 2 == 0,
                  shortID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw XrayProfileError.invalidSettings }
        }
        if network == "xhttp" {
            guard ["auto", "packet-up", "stream-up", "stream-one"].contains(mode),
                  path.hasPrefix("/"), path.utf8.count <= 4096, httpHost.utf8.count <= 253,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !httpHost.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw XrayProfileError.invalidSettings }
        }
        return XrayProfile(address: host, port: port, uuid: user, network: network, security: security,
            serverName: serverName, fingerprint: fingerprint, publicKey: publicKey, shortId: shortID, flow: flow,
            host: httpHost, path: path, mode: mode)
    }

    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

enum XrayProfileError: LocalizedError {
    case invalid, unsupported, invalidSettings
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid VLESS link. An endpoint, port and UUID are required."
        case .invalidSettings: return "Invalid or incomplete TLS/REALITY/XHTTP settings (server name, fingerprint, key, short ID, path or mode)."
        case .unsupported: return "This link uses unsupported or duplicate parameters. Basic TCP/XHTTP, TLS and REALITY are supported; XHTTP extra/downloadSettings and other extensions are not silently discarded."
        }
    }
}
