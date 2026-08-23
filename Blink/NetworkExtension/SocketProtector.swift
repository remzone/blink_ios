import Foundation
import Network
import Mobile
import Darwin

final class SocketProtector: NSObject, MobileProtectorProtocol {
    private static let ipBoundIf: Int32 = 25
    private static let ipv6BoundIf: Int32 = 125
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.blink.tunnel.physical-path")
    private let lock = NSLock()
    private var interfaceIndex: UInt32 = 0

    func start() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let index = Self.physicalInterfaceIndex(path)
            self?.lock.lock(); self?.interfaceIndex = index; self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        lock.lock(); interfaceIndex = 0; lock.unlock()
    }

    func protect(_ fd: Int) -> Bool {
        lock.lock(); var index = interfaceIndex; lock.unlock()
        if index == 0 { index = Self.fallbackInterfaceIndex() }
        guard index != 0 else { return true }
        let socket = Int32(fd)
        let length = socklen_t(MemoryLayout<UInt32>.size)
        let ipv4 = setsockopt(socket, IPPROTO_IP, Self.ipBoundIf, &index, length)
        let ipv6 = setsockopt(socket, IPPROTO_IPV6, Self.ipv6BoundIf, &index, length)
        return ipv4 == 0 || ipv6 == 0
    }

    private static func physicalInterfaceIndex(_ path: NWPath) -> UInt32 {
        for interface in path.availableInterfaces {
            switch interface.type {
            case .wifi, .cellular, .wiredEthernet: return if_nametoindex(interface.name)
            default: continue
            }
        }
        return 0
    }

    private static func fallbackInterfaceIndex() -> UInt32 {
        for name in ["en0", "pdp_ip0", "pdp_ip1"] {
            let index = if_nametoindex(name)
            if index != 0 { return index }
        }
        return 0
    }
}
