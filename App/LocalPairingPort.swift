import Darwin
import Dispatch
import dnssd

enum LocalPairingPort {
    static func discover() async -> UInt16? {
        guard !Task.isCancelled else { return nil }
        let port: UInt16? = await withCheckedContinuation { continuation in
            PairingPortDiscovery.queue.async {
                PairingPortDiscovery(continuation).start()
            }
        }
        return Task.isCancelled ? nil : port
    }
}

private final class PairingPortDiscovery: @unchecked Sendable {
    static let queue = DispatchQueue(label: "shen3w.sideloadupdater.pairing-port")
    private static let shareConnection = DNSServiceFlags(kDNSServiceFlagsShareConnection)
    private static let localOnly = kDNSServiceInterfaceIndexLocalOnly

    private var continuation: CheckedContinuation<UInt16?, Never>?
    private var connection: DNSServiceRef?
    private var portsByLookup: [DNSServiceRef: UInt16] = [:]

    init(_ continuation: CheckedContinuation<UInt16?, Never>) {
        self.continuation = continuation
    }

    func start() {
        let deadline = DispatchTime.now() + .seconds(2)
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError,
              let connection,
              DNSServiceSetDispatchQueue(connection, Self.queue) == kDNSServiceErr_NoError else {
            finish(nil)
            return
        }

        var browse: DNSServiceRef? = connection
        let status = DNSServiceBrowse(
            &browse, Self.shareConnection, Self.localOnly, "_remotepairing._tcp", "local.",
            { _, flags, _, error, name, type, domain, context in
                let discovery = PairingPortDiscovery.discovery(from: context)
                guard error == kDNSServiceErr_NoError else {
                    discovery.finish(nil)
                    return
                }
                if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                    discovery.resolve(name: name, type: type, domain: domain)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard status == kDNSServiceErr_NoError else {
            finish(nil)
            return
        }
        Self.queue.asyncAfter(deadline: deadline) { self.finish(nil) }
    }

    private func resolve(
        name: UnsafePointer<CChar>?, type: UnsafePointer<CChar>?, domain: UnsafePointer<CChar>?
    ) {
        guard let connection, let name, let type, let domain else { return }
        var resolution: DNSServiceRef? = connection
        _ = DNSServiceResolve(
            &resolution, Self.shareConnection, Self.localOnly, name, type, domain,
            { _, _, _, error, _, host, port, _, _, context in
                if error == kDNSServiceErr_NoError, let host, port != 0 {
                    PairingPortDiscovery.discovery(from: context).lookUp(host: host, port: UInt16(bigEndian: port))
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func lookUp(host: UnsafePointer<CChar>, port: UInt16) {
        guard let connection else { return }
        var lookup: DNSServiceRef? = connection
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let status = DNSServiceGetAddrInfo(
            &lookup, Self.shareConnection, Self.localOnly, protocols, host,
            { lookup, flags, _, error, _, address, _, context in
                guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                      let lookup, let address else { return }
                let discovery = PairingPortDiscovery.discovery(from: context)
                if let port = discovery.portsByLookup[lookup], PairingPortDiscovery.isLocal(address) {
                    discovery.finish(port)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status == kDNSServiceErr_NoError, let lookup {
            portsByLookup[lookup] = port
        }
    }

    private func finish(_ port: UInt16?) {
        guard let continuation else { return }
        self.continuation = nil
        if let connection {
            self.connection = nil
            DNSServiceRefDeallocate(connection)
        }
        portsByLookup.removeAll()
        continuation.resume(returning: port)
    }

    private static func discovery(from context: UnsafeMutableRawPointer?) -> PairingPortDiscovery {
        Unmanaged<PairingPortDiscovery>.fromOpaque(context!).takeUnretainedValue()
    }

    private static func isLocal(_ address: UnsafePointer<sockaddr>) -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return false }
        defer { freeifaddrs(interfaces) }

        var entry: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let current = entry {
            let interface = current.pointee
            if interface.ifa_flags & UInt32(IFF_UP) != 0, let local = interface.ifa_addr,
               matches(address, UnsafePointer(local), interfaceName: interface.ifa_name) {
                return true
            }
            entry = interface.ifa_next
        }
        return false
    }

    private static func matches(
        _ address: UnsafePointer<sockaddr>, _ local: UnsafePointer<sockaddr>,
        interfaceName: UnsafePointer<CChar>
    ) -> Bool {
        guard address.pointee.sa_family == local.pointee.sa_family else { return false }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let resolved = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let assigned = local.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            return resolved.s_addr == assigned.s_addr
        case AF_INET6:
            let resolved = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let assigned = local.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            return withUnsafeBytes(of: resolved.sin6_addr) { resolvedBytes in
                withUnsafeBytes(of: assigned.sin6_addr) { assignedBytes in
                    guard resolvedBytes[0] == 0xfe, resolvedBytes[1] & 0xc0 == 0x80 else {
                        return resolvedBytes.elementsEqual(assignedBytes)
                    }
                    let embeddedScope = UInt32(resolvedBytes[2]) << 8 | UInt32(resolvedBytes[3])
                    let scope = resolved.sin6_scope_id == 0 || resolved.sin6_scope_id == localOnly
                        ? embeddedScope : resolved.sin6_scope_id
                    return (scope == 0 || scope == if_nametoindex(interfaceName))
                        && resolvedBytes.prefix(2).elementsEqual(assignedBytes.prefix(2))
                        && resolvedBytes.dropFirst(4).elementsEqual(assignedBytes.dropFirst(4))
                }
            }
        default:
            return false
        }
    }
}
