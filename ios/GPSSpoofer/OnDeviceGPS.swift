import Foundation
import CoreLocation
import IDeviceFFI

// Standalone whole-phone GPS spoof — no Mac, no jailbreak.
// The app talks to its OWN phone's developer services (the same LocationSimulation channel Xcode
// uses) via jkcoxson/idevice. iOS won't let an app reach its own services on 127.0.0.1, so the free
// LocalDevVPN app (App Store) must be connected: it exposes the phone at 10.7.0.1:49152.
//   pairing file (Documents/pairing.plist, put there once by the Mac app) → tunnel → RSD → DVT sim.
// The fake location only holds while this app's connection lives, so we keep the app alive in the
// background with a location session and re-send the point every 4s (iOS drops it otherwise).

@MainActor
final class OnDeviceGPS: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = OnDeviceGPS()

    @Published private(set) var status = "idle" {
        didSet { PhoneStatus.write() }   // mirrored to Documents/status.json for the Mac app
    }
    @Published private(set) var live = false { didSet { PhoneStatus.write() } }

    private let q = DispatchQueue(label: "gs.ondevice.gps")
    private let link = Link()
    private var target: (Double, Double)?
    private var heartbeat: Timer?
    private let keepAlive = CLLocationManager()

    nonisolated static var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }
    nonisolated static var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    func set(_ lat: Double, _ lon: Double) {
        target = (lat, lon)
        // Trips call this every second; only (re)arm the keep-alive + heartbeat once.
        if heartbeat == nil {
            status = "moving phone…"
            startKeepAlive()
            heartbeat = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
                Task { @MainActor in OnDeviceGPS.shared.push(quiet: true) }
            }
        }
        push()
    }

    func clear() {
        target = nil
        heartbeat?.invalidate(); heartbeat = nil
        keepAlive.stopUpdatingLocation()
        q.async { [link] in
            let err = link.clear()
            link.close()
            Task { @MainActor in
                self.live = false
                self.status = err.map { "clear failed: \($0)" } ?? "phone back to real GPS"
            }
        }
    }

    private func push(quiet: Bool = false) {
        guard let (lat, lon) = target else { return }
        q.async { [link] in
            // One reconnect attempt: the tunnel dies if LocalDevVPN drops or the phone sleeps hard.
            var err = link.set(lat, lon)
            if err != nil { link.close(); err = link.set(lat, lon) }
            Task { @MainActor in
                if let err {
                    self.live = false
                    self.status = err
                } else {
                    self.live = true
                    if !quiet { self.status = "whole phone at \(String(format: "%.4f, %.4f", lat, lon))" }
                }
            }
        }
    }

    // Background keep-alive: a running location session stops iOS suspending us, which would
    // otherwise kill the tunnel and snap the phone back to its real position.
    private func startKeepAlive() {
        keepAlive.delegate = self
        if keepAlive.authorizationStatus == .notDetermined { keepAlive.requestWhenInUseAuthorization() }
        keepAlive.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        keepAlive.distanceFilter = CLLocationDistanceMax
        keepAlive.pausesLocationUpdatesAutomatically = false
        keepAlive.allowsBackgroundLocationUpdates = true
        keepAlive.showsBackgroundLocationIndicator = true
        keepAlive.startUpdatingLocation()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {}
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

/// Owns the idevice handles. Only ever touched on OnDeviceGPS.q.
private final class Link: @unchecked Sendable {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var sim: OpaquePointer?

    /// Returns nil on success, else a human-readable error.
    func set(_ lat: Double, _ lon: Double) -> String? {
        if sim == nil, let e = open() { return e }
        return take(location_simulation_set(sim, lat, lon), "sending location")
    }

    func clear() -> String? {
        guard sim != nil else { return nil }
        return take(location_simulation_clear(sim), "clearing")
    }

    private func open() -> String? {
        guard OnDeviceGPS.hasPairing else {
            return "not paired yet: plug into your Mac and press Install in the GPS Spoofer Mac app"
        }
        var pairing: OpaquePointer?
        if let e = take(OnDeviceGPS.pairingURL.path.withCString { rp_pairing_file_read($0, &pairing) },
                        "reading pairing file") { return e }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(49152).bigEndian
        inet_pton(AF_INET, "10.7.0.1", &addr.sin_addr)

        let tunnelErr: UnsafeMutablePointer<IdeviceFfiError>? = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                "10.7.0.1".withCString { host in
                    tunnel_create_rppairing(sa, socklen_t(MemoryLayout<sockaddr_in>.size), host,
                                            pairing, nil, nil, &adapter, &handshake)
                }
            }
        }
        if let e = take(tunnelErr, "tunnel (is LocalDevVPN connected?)") { close(); return e }
        if let e = take(remote_server_connect_rsd(adapter, handshake, &server), "developer services") {
            close(); return e
        }
        if let e = take(location_simulation_new(server, &sim), "location service") { close(); return e }
        return nil
    }

    func close() {
        if let sim { location_simulation_free(sim) }
        if let server { remote_server_free(server) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        sim = nil; server = nil; handshake = nil; adapter = nil
    }

    private func take(_ e: UnsafeMutablePointer<IdeviceFfiError>?, _ what: String) -> String? {
        guard let e else { return nil }
        let msg = e.pointee.message.map { String(cString: $0) } ?? "code \(e.pointee.code)"
        idevice_error_free(e)
        return "\(what): \(msg)"
    }
}
