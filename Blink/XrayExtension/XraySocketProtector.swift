import Foundation
import Network
import BlinkCore
import Darwin

final class XraySocketProtector: NSObject, MobileProtectorProtocol, @unchecked Sendable {
    private static let ipBoundIf: Int32 = 25
    private static let ipv6BoundIf: Int32 = 125
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.blink.tunnel.physical-path")
    private let condition = NSCondition()
    private var interfaceIndex: UInt32 = 0
    private var generation = UUID()

    func start() {
        stop()
        let monitor = NWPathMonitor()
        condition.lock()
        let id = UUID(); generation = id; self.monitor = monitor
        condition.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let index = path.status == .satisfied ? Self.physicalInterfaceIndex(path) : 0
            self.condition.lock()
            if self.generation == id { self.interfaceIndex = index; self.condition.broadcast() }
            self.condition.unlock()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        condition.lock()
        let previous = monitor; monitor = nil; generation = UUID(); interfaceIndex = 0
        condition.broadcast(); condition.unlock()
        previous?.cancel()
    }

    func protect(_ fd: Int64) -> Bool {
        guard fd >= 0, fd <= Int64(Int32.max) else { return false }
        // Wait for an actual active physical path; interface existence alone is insufficient.
        condition.lock()
        let id = generation, deadline = Date().addingTimeInterval(2)
        while interfaceIndex == 0 && monitor != nil && generation == id && Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        var index = generation == id ? interfaceIndex : 0
        condition.unlock()
        guard index != 0 else { return false }
        let socket = Int32(fd), length = socklen_t(MemoryLayout<UInt32>.size)
        let ipv4 = setsockopt(socket, IPPROTO_IP, Self.ipBoundIf, &index, length)
        let ipv6 = setsockopt(socket, IPPROTO_IPV6, Self.ipv6BoundIf, &index, length)
        return ipv4 == 0 || ipv6 == 0
    }

    private static func physicalInterfaceIndex(_ path: NWPath) -> UInt32 {
        for interface in path.availableInterfaces where path.usesInterfaceType(interface.type) {
            switch interface.type {
            case .wifi, .cellular, .wiredEthernet: return if_nametoindex(interface.name)
            default: continue
            }
        }
        return 0
    }
}
