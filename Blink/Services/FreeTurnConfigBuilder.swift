import Foundation

struct FreeTurnCoreConfig: Codable {
    var peer: String
    var clientId: String
    var subUrl = ""
    var provider = "vk"
    var routes = false
    var turn = Turn()
    var proxy: Proxy
    var vk: VK
    var obf: Obf
    var dns = DNS()
    var log = Log()
    var tunnel = Tunnel()

    struct Turn: Codable { var n = 12; var transport = "tcp"; var host = ""; var port = "" }
    struct Proxy: Codable { var listen: String }
    struct VK: Codable { var links: [String]; var streamsPerCred = 12; var manualCaptcha = false; var platform = "mobile" }
    struct Obf: Codable { var profile: String; var key: String; var timingMs = 0 }
    struct DNS: Codable { var mode = "auto"; var servers: [String] = [] }
    struct Log: Codable { var debug = false }
    struct Tunnel: Codable { var mode = "none"; var config = ""; var mtu = 0 }
}

enum FreeTurnConfigBuilder {
    static func json(profile: VPNProfile, obfuscationKey: String) throws -> String {
        let config = FreeTurnCoreConfig(
            peer: "\(profile.server):\(profile.port)",
            clientId: profile.freeTurn.clientID,
            proxy: .init(listen: "127.0.0.1:\(profile.freeTurn.listenPort)"),
            vk: .init(links: [profile.freeTurn.vkLink]),
            obf: .init(profile: profile.freeTurn.obfProfile, key: obfuscationKey)
        )
        let data = try JSONEncoder().encode(config)
        return String(decoding: data, as: UTF8.self)
    }
}
