import SwiftUI

// First-launch guide (also behind the ? button on the map): what it does, how it works, and a
// live checklist of what has to be true before the phone will move.

struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage().tag(0)
                HowItWorksPage().tag(1)
                RequirementsPage().tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < 2 { withAnimation { page += 1 } } else { done() }
            } label: {
                Text(page < 2 ? "Next" : "Start")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Theme.acid, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Theme.acid.opacity(0.15)).frame(width: 150, height: 150)
                Circle().stroke(Theme.acid.opacity(0.4), lineWidth: 1).frame(width: 190, height: 190)
                Image(systemName: "location.north.circle.fill")
                    .font(.system(size: 76, weight: .semibold)).foregroundStyle(Theme.acid)
            }
            Text("GPS Spoofer").font(.system(size: 34, weight: .bold))
            Text("Move your whole iPhone anywhere in the world. Maps, weather, games and every other app see the new location.")
                .font(.system(size: 16)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
            Text("Tap a spot on the map to teleport, or add stops to walk, drive or sail between them.")
                .font(.system(size: 13)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.bottom, 40)
        }
    }
}

private struct HowItWorksPage: View {
    private let steps: [(icon: String, title: String, detail: String)] = [
        ("mappin.and.ellipse", "GPS Spoofer", "You pick a spot on the map."),
        ("lock.shield", "LocalDevVPN", "A private tunnel that lets this app talk to your own iPhone. Nothing leaves the phone."),
        ("iphone.gen3", "iPhone location service", "The same developer tool Xcode uses to test apps sets the new position."),
        ("square.grid.2x2", "Every app", "Maps, weather, games: they all see the spot you picked."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How it works").font(.system(size: 28, weight: .bold)).padding(.bottom, 6)
            Text("No jailbreak. Your Mac sets it up once, then it runs on the phone by itself.")
                .font(.system(size: 14)).foregroundStyle(Theme.dim).padding(.bottom, 22)

            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                ZStack(alignment: .topLeading) {
                    // the wire between the four nodes, with a pulse travelling down it
                    GeometryReader { g in
                        let h = g.size.height - 44
                        Rectangle().fill(Theme.line).frame(width: 2, height: h).offset(x: 21, y: 22)
                        Circle().fill(Theme.acid).frame(width: 10, height: 10)
                            .shadow(color: Theme.acid, radius: 6)
                            .offset(x: 17, y: 17 + h * t)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(steps.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: steps[i].icon)
                                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(i == 0 ? Theme.acid : Theme.panel))
                                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(steps[i].title).font(.system(size: 16, weight: .semibold))
                                    Text(steps[i].detail).font(.system(size: 13)).foregroundStyle(Theme.dim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(Theme.acid)
                Text("One time only: the GPS Spoofer Mac app installs this app over a cable and pairs it with your phone.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            .padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 24)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 40)
    }
}

private struct RequirementsPage: View {
    @State private var vpnInstalled = false
    @State private var vpnConnected = false
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before you start").font(.system(size: 28, weight: .bold))
            Text("All lights green and you're ready.").font(.system(size: 14)).foregroundStyle(Theme.dim)
                .padding(.bottom, 6)

            // Developer-signed apps only open with Developer Mode on, so if we're running it's on.
            Check(ok: true, title: "Developer Mode is on",
                  detail: "Settings › Privacy & Security › Developer Mode")
            Check(ok: OnDeviceGPS.hasPairing, title: "Paired with your Mac",
                  detail: OnDeviceGPS.hasPairing ? "Done. You won't need the Mac again."
                                                 : "Plug into your Mac and press Install in the GPS Spoofer Mac app.")
            Check(ok: vpnInstalled, title: "LocalDevVPN installed",
                  detail: "Free on the App Store.",
                  action: vpnInstalled ? nil : ("Get it", { UIApplication.shared.open(LocalDevVPN.appStoreURL) }))
            Check(ok: vpnConnected, title: "LocalDevVPN connected",
                  detail: "Keep it connected while you spoof. Connect on Wi-Fi the first time.",
                  action: vpnConnected || !vpnInstalled ? nil : ("Connect", { LocalDevVPN.connectOrInstall() }))
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 40)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        vpnInstalled = LocalDevVPN.isInstalled
        vpnConnected = LocalDevVPN.isConnected
        PhoneStatus.write()
    }
}

private struct Check: View {
    let ok: Bool
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(ok ? Theme.good : Theme.bad).frame(width: 12, height: 12)
                .shadow(color: ok ? Theme.good : Theme.bad, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.acid, in: Capsule()).foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}
