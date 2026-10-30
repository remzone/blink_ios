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
              let host = url.host, !host.isEmpty, host.count <= 253,
              let user = url.user, UUID(uuidString: user) != nil,
              url.password == nil, let port = url.port, (1...65535).contains(port),
              url.path.isEmpty || url.path == "/" else { throw XrayProfileError.invalid }
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
        return XrayProfile(address: host, port: port, uuid: user, network: network, security: security,
            serverName: parameters["sni"] ?? host, fingerprint: parameters["fp"] ?? "chrome",
            publicKey: parameters["pbk"] ?? "", shortId: parameters["sid"] ?? "", flow: flow,
            host: parameters["host"] ?? host, path: parameters["path"] ?? "/", mode: parameters["mode"] ?? "auto")
    }

    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

enum XrayProfileError: LocalizedError {
    case invalid, unsupported
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid VLESS link. An endpoint, port and UUID are required."
        case .unsupported: return "This link uses unsupported or duplicate parameters. Basic TCP/XHTTP, TLS and REALITY are supported; XHTTP extra/downloadSettings and other extensions are not silently discarded."
        }
    }
}
