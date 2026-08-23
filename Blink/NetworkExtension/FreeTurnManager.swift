import Foundation
import Mobile

final class FreeTurnManager {
    private(set) var isRunning = false
    private let protector = SocketProtector()

    func start(profile: VPNProfile, obfuscationKey: String) async throws {
        let json = try FreeTurnConfigBuilder.json(profile: profile, obfuscationKey: obfuscationKey)
        let validation = MobileValidateConfig(json)
        guard validation.isEmpty else { throw TunnelError.freeTurn(validation) }
        protector.start()
        MobileSetProtect(protector)
        MobileSetStateDir(SharedConstants.storageDirectory().path)
        var error: NSError?
        MobileStart(json, &error)
        if let error { throw TunnelError.freeTurn(error.localizedDescription) }
        isRunning = true

        for _ in 0..<300 {
            try Task.checkCancellation()
            guard let snapshot = MobileGetState() else {
                try await Task.sleep(for: .milliseconds(100)); continue
            }
            switch snapshot.state ?? "idle" {
            case "connected": return
            case "error": throw TunnelError.freeTurn(snapshot.errMsg ?? "Unknown core error")
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw TunnelError.freeTurnTimeout
    }

    func stop() {
        if isRunning { MobileStop() }
        MobileSetProtect(nil)
        protector.stop()
        isRunning = false
    }

    func metrics() -> TunnelMetrics {
        guard let value = MobileGetState() else { return .empty }
        return TunnelMetrics(
            state: value.state ?? "idle", uploadedBytes: value.txTotal,
            downloadedBytes: value.rxTotal, uploadRate: value.txRate,
            downloadRate: value.rxRate, streams: value.streams)
    }
}
