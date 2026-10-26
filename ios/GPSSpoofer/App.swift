import SwiftUI
import UIKit

// GPS Spoofer: the on-phone half. The Mac app installs this, pairs it with the phone once, and
// from then on everything runs here: the map picks a spot and OnDeviceGPS moves the whole phone.

enum Theme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)   // #0a0a0a, Toolbay canvas
    static let panel = Color(white: 0.08)
    static let line = Color(white: 0.17)
    static let acid = Color(red: 0.545, green: 0.427, blue: 1.0)  // #8b6dff, Toolbay accent
    static let good = Color(red: 0.2, green: 0.83, blue: 0.45)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let dim = Color(white: 0.55)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

@main
struct GPSSpooferApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.acid)
                .onAppear { LaunchArgs.run(); PhoneStatus.write() }
                .onChange(of: phase) { _, p in if p == .active { PhoneStatus.write() } }
                .onOpenURL { _ in PhoneStatus.write() }   // gpsspoofer:// callback from LocalDevVPN
        }
    }
}

/// `devicectl device process launch … --spoof 35.68,139.69` (or `--unspoof`) drives the spoof
/// without touching the screen; handy for testing.
enum LaunchArgs {
    @MainActor static func run() {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "--spoof"), i + 1 < a.count {
            let p = a[i + 1].split(separator: ",").compactMap { Double($0) }
            guard p.count == 2 else { return }
            GeoSpoof.set(p[0], p[1], name: "Remote")
            Spoofer.shared.move(.init(latitude: p[0], longitude: p[1]), name: "Remote")
        } else if a.contains("--unspoof") {
            GeoSpoof.off()
            Spoofer.shared.stop()
        } else if GeoSpoof.on, let (lat, lon) = GeoSpoof.coord {
            // App was killed (update, crash, reboot) while faking: pick up where it left off.
            Spoofer.shared.move(.init(latitude: lat, longitude: lon),
                                name: UserDefaults.standard.string(forKey: "gs.geo.name") ?? "Pin")
        }
    }
}

struct RootView: View {
    @AppStorage("gs.onboarded") private var onboarded = false

    var body: some View {
        GPSView()
            .fullScreenCover(isPresented: .init(get: { !onboarded }, set: { onboarded = !$0 })) {
                OnboardingView { onboarded = true }
            }
    }
}
