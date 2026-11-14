import Darwin
import Foundation

/// IP local del iPhone en la Wi-Fi, para mostrarla en pantalla y armar el
/// comando de ffmpeg del PC.
enum LocalIP {

    static func wifiAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, interfaces != nil else { return nil }
        defer { freeifaddrs(interfaces) }

        var pointer = interfaces
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let interfaceAddress = current.pointee.ifa_addr else { continue }
            guard interfaceAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            // en0 = Wi-Fi en el iPhone.
            guard name == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(interfaceAddress,
                                     socklen_t(interfaceAddress.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0,
                                     NI_NUMERICHOST)
            if result == 0 {
                address = String(cString: host)
            }
        }

        return address
    }
}
