import Foundation

struct RoutingPolicy: Codable {
    let schema: String
    let mode: String
    let revision: Int64
    let updated_at: Int64
    let domains: [String]
    let ips: [String]
    let exclude_domains: [String]?
    let exclude_ips: [String]?
    let sources: [String]?
    let source_revision: String?
}
