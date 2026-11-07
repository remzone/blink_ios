import Foundation
import Network
import BlinkCore
import Darwin

final class XraySocketProtector: NSObject, MobileProtectorProtocol, @unchecked Sendable {
    private static let ipBoundIf: Int32 = 25
    private static let ipv6BoundIf: Int32 = 125
    private var monitors: [NWPathMonitor] = []
    private let queue = DispatchQueue(label: "com.blink.tunnel.physical-path")
    private let condition = NSCondition()
    private var interfaces: [NWInterface.InterfaceType: UInt32] = [:]
    private var generation = UUID()
    private var failures: Int64 = 0
    private var lastFailureLog = Date.distantPast
    var diagnostics: DiagnosticRecorder?

    func start() {
        stop()
        // An unqualified monitor follows the VPN default route once settings are
        // applied. Independent physical monitors keep the bypass tied to real NICs.
        let types: [NWInterface.InterfaceType] = [.wiredEthernet, .wifi, .cellular]
        let created = types.map { NWPathMonitor(requiredInterfaceType: $0) }
        condition.lock(); let id = UUID(); generation = id; monitors = created; condition.unlock()
        for (monitor, type) in zip(created, types) {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let index = path.status == .satisfied ? path.availableInterfaces.first(where: { $0.type == type }).map { if_nametoindex($0.name) } ?? 0 : 0
                self.condition.lock()
                let current = self.generation == id
                let changed = current && self.interfaces[type] != index
                if current { self.interfaces[type] = index; self.condition.broadcast() }
                self.condition.unlock()
                if changed {
                    self.diagnostics?.record("network.path", fields: ["interfaceIndex": Int64(index), "interfaceType": type == .wifi ? 1 : type == .cellular ? 2 : 3, "pathStatus": path.status == .satisfied ? 1 : 0, "expensive": path.isExpensive ? 1 : 0, "constrained": path.isConstrained ? 1 : 0, "ipv4": path.supportsIPv4 ? 1 : 0, "ipv6": path.supportsIPv6 ? 1 : 0])
                }
            }
            monitor.start(queue: queue)
        }
    }
    func stop() {
        condition.lock(); let previous = monitors; monitors = []; generation = UUID(); interfaces = [:]; condition.broadcast(); condition.unlock()
        previous.forEach { $0.cancel() }
    }
    private func selectedIndex() -> UInt32 {
        for type: NWInterface.InterfaceType in [.wiredEthernet, .wifi, .cellular] { if let index = interfaces[type], index != 0 { return index } }
        return 0
    }
    func protect(_ fd: Int64) -> Bool {
        guard fd >= 0, fd <= Int64(Int32.max) else { return false }
        condition.lock(); let id = generation, deadline = Date().addingTimeInterval(2)
        while selectedIndex() == 0 && !monitors.isEmpty && generation == id && Date() < deadline { _ = condition.wait(until: deadline) }
        var index = generation == id ? selectedIndex() : 0
        condition.unlock()
        guard index != 0 else { reportFailure(code: 0); return false }
        let socket = Int32(fd), length = socklen_t(MemoryLayout<UInt32>.size)
        let ipv4 = setsockopt(socket, IPPROTO_IP, Self.ipBoundIf, &index, length)
        let ipv6 = setsockopt(socket, IPPROTO_IPV6, Self.ipv6BoundIf, &index, length)
        let ok = ipv4 == 0 || ipv6 == 0
        if !ok { reportFailure(code: Int64(errno)) }
        return ok
    }
    private func reportFailure(code: Int64) {
        condition.lock(); failures += 1
        let count = failures, shouldLog = Date().timeIntervalSince(lastFailureLog) >= 1
        if shouldLog { lastFailureLog = Date() }; condition.unlock()
        if shouldLog { diagnostics?.record("network.protection_failed", fields: ["protectFailures": count, "errorCode": code]) }
    }
}
