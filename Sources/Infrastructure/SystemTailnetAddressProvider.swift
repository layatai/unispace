import Darwin
import Foundation
import UniSpaceApplication
import UniSpaceDomain

public struct SystemTailnetAddressProvider: TailnetAddressProviding {
    public init() {}

    public func currentAddresses() -> [PeerAddress] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var result = Set<PeerAddress>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6),
                  let host = Self.numericHost(address),
                  Self.isTailnetAddress(host),
                  let peerAddress = try? PeerAddress(host) else { continue }
            result.insert(peerAddress)
        }
        return result.sorted { $0.host < $1.host }
    }

    static func isTailnetAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            return bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
        }

        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        }
        return false
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length: socklen_t = address.pointee.sa_family == UInt8(AF_INET)
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
