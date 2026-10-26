import Darwin
import Foundation
import UIKit

/// LocalDevVPN (free, App Store) lets this app reach its own phone's developer services: when it's
/// connected the phone shows up to itself at 10.7.0.1. It registers `localdevvpn://` and takes a
/// callback scheme, so "Connect" opens it, it starts the tunnel, and it comes straight back here.
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!
    static let enableURL = URL(string: "localdevvpn://enable?scheme=gpsspoofer")!

    /// Needs `localdevvpn` in LSApplicationQueriesSchemes.
    @MainActor static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }

    /// Connected = some interface has a 10.7.0.x address.
    static var isConnected: Bool { ipv4Addresses().contains { $0.hasPrefix("10.7.0.") } }

    @MainActor static func connectOrInstall() {
        UIApplication.shared.open(isInstalled ? enableURL : appStoreURL)
    }

    private static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    out.append(String(cString: host))
                }
            }
            p = cur.pointee.ifa_next
        }
        return out
    }
}

/// Documents/status.json: what the Mac app reads over USB to light its "after install" checks.
enum PhoneStatus {
    @MainActor static func write() {
        let s: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "paired": OnDeviceGPS.hasPairing,
            "vpnInstalled": LocalDevVPN.isInstalled,
            "vpnConnected": LocalDevVPN.isConnected,
            "live": OnDeviceGPS.shared.live,
            "message": OnDeviceGPS.shared.status,
        ]
        let url = OnDeviceGPS.pairingURL.deletingLastPathComponent().appendingPathComponent("status.json")
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
