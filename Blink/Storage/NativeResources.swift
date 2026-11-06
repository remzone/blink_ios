import Foundation
import BlinkCore

enum NativeResources {
    private static let preparation: Result<Void, Error> = Result {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let path = root.appendingPathComponent("blink-xray-assets", isDirectory: true).path
        var error: NSError?
        _ = MobilePrepareAssets(path, &error)
        if let error { throw error }
    }
    static func prepare() throws { try preparation.get() }
}
