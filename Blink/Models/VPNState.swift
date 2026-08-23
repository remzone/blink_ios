import Foundation

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date)
    case disconnecting
    case failed(message: String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .failed: "Error"
        }
    }

    var isBusy: Bool {
        self == .connecting || self == .disconnecting
    }
}
