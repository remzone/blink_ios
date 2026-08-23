import Foundation

struct TunnelMetrics: Codable, Equatable {
    var state: String
    var uploadedBytes: Int64
    var downloadedBytes: Int64
    var uploadRate: Int64
    var downloadRate: Int64
    var streams: Int
    static let empty = TunnelMetrics(state: "idle", uploadedBytes: 0, downloadedBytes: 0, uploadRate: 0, downloadRate: 0, streams: 0)
}
