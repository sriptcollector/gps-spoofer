import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// GPS Spoofer for Mac: a small window that gets the iPhone app onto the phone. Every light on top
// has to be green before Install unlocks; the lights below show the phone side after install.

enum Palette {   // Toolbay tokens
    static let canvas = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let panel = Color(white: 0.085)
    static let line = Color(white: 0.16)
    static let accent = Color(red: 0.545, green: 0.427, blue: 1.0)
    static let good = Color(red: 0.2, green: 0.83, blue: 0.45)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let dim = Color(white: 0.55)
}

@main
struct GPSSpooferMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var checks = Checks()
    @StateObject private var installer = Installer()

    var body: some Scene {
        Window("GPS Spoofer", id: "main") {
            MainView(checks: checks, installer: installer)
                .frame(width: 440)
                .fixedSize(horizontal: false, vertical: true)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// `--snapshot out.png`: render the window once the checks have run, then quit (for docs/QA).
    func applicationDidFinishLaunching(_ n: Notification) {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return }
        Task { @MainActor in
            let checks = Checks(), installer = Installer()
            await checks.refresh()
            let r = ImageRenderer(content: MainView(checks: checks, installer: installer).frame(width: 440)
                .environment(\.colorScheme, .dark))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: a[i + 1]))
            }
            NSApp.terminate(nil)
        }
    }
}

struct MainView: View {
    @ObservedObject var checks: Checks
    @ObservedObject var installer: Installer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            section("Before installing") {
                row(checks.xcode) {
                    switch checks.xcodeState {
                    case .missing: button("Get Xcode") { NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!) }
                    case .needsSetup: button("Finish setup", busy: "xcode") { await checks.finishXcodeSetup() }
                    case .ready: EmptyView()
                    }
                }
                row(checks.account) {
                    if checks.account.state == .bad, checks.xcodeState == .ready {
                        button("Open Xcode") { checks.openXcodeAccounts() }
                    } else if checks.teams.count > 1 {
                        Picker("", selection: $checks.selectedTeam) {
                            ForEach(checks.teams) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                }
                row(checks.connected) { EmptyView() }
                row(checks.trusted) {
                    if checks.trusted.state == .bad { button("Ask again", busy: "trust") { await checks.askTrust() } }
                }
                row(checks.devMode) {
                    if checks.devMode.state == .bad { button("Show switch", busy: "devmode") { await checks.revealDevMode() } }
                }
            }

            installButton

            section("On your iPhone") {
                row(checks.appOnPhone) { EmptyView() }
                row(checks.vpnOnPhone) {
                    if checks.vpnOnPhone.state == .bad { QRCode(url: Checks.vpnStoreURL).frame(width: 64, height: 64) }
                }
                row(checks.link) { EmptyView() }
            }

            Text("Once everything is green you can unplug. GPS Spoofer runs on the iPhone by itself.")
                .font(.system(size: 11)).foregroundStyle(Palette.dim)
        }
        .padding(20)
        .background(Palette.canvas)
        .onAppear { if !CommandLine.arguments.contains("--snapshot") { checks.start() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("GPS Spoofer").font(.system(size: 20, weight: .bold))
                Text("Puts the GPS Spoofer app on your iPhone").font(.system(size: 12)).foregroundStyle(Palette.dim)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var installButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await installer.install(checks) }
            } label: {
                HStack {
                    if installer.running { ProgressView().controlSize(.small).tint(.white) }
                    Text(installer.running ? "Installing…" : checks.appOnPhone.state == .ok ? "Reinstall on iPhone" : "Install on iPhone")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(checks.readyToInstall && !installer.running ? Palette.accent : Palette.line,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(checks.readyToInstall ? .white : Palette.dim)
            }
            .buttonStyle(.plain)
            .disabled(!checks.readyToInstall || installer.running)

            if installer.running {
                if let p = installer.progress { ProgressView(value: p).tint(Palette.accent) }
                Text(installer.stage).font(.system(size: 12)).foregroundStyle(Palette.dim)
            } else if !checks.readyToInstall {
                Text("Every light above has to be green first.").font(.system(size: 12)).foregroundStyle(Palette.dim)
            }
            if let note = installer.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Palette.good).fixedSize(horizontal: false, vertical: true)
            }
            if let e = installer.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.message).font(.system(size: 12)).foregroundStyle(Palette.bad).fixedSize(horizontal: false, vertical: true)
                    if !e.details.isEmpty {
                        DisclosureGroup("Details", isExpanded: $installer.showDetails) {
                            ScrollView {
                                Text(e.details).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 120)
                        }
                        .font(.system(size: 11)).foregroundStyle(Palette.dim)
                    }
                }
            }
        }
    }

    // MARK: building blocks

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.dim).padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .padding(.bottom, -1)   // hide the last row's divider
                .background(Palette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
        }
    }

    private func row<A: View>(_ l: Light, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(color(l.state)).frame(width: 10, height: 10)
                .shadow(color: l.state == .waiting ? .clear : color(l.state).opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(l.title).font(.system(size: 13, weight: .semibold))
                Text(l.detail).font(.system(size: 11)).foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1).opacity(0.6) }
    }

    private func color(_ s: Light.State) -> Color {
        switch s { case .ok: Palette.good; case .bad: Palette.bad; case .waiting, .checking: Color(white: 0.3) }
    }

    private func button(_ title: String, busy: String? = nil, _ act: @escaping () async -> Void) -> some View {
        Button { Task { await act() } } label: {
            HStack(spacing: 6) {
                if busy != nil, checks.busy == busy { ProgressView().controlSize(.mini) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil && checks.busy == busy)
    }
}

/// QR code so the iPhone camera can open the LocalDevVPN App Store page.
struct QRCode: View {
    let url: URL
    var body: some View {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(url.absoluteString.utf8)
        f.correctionLevel = "M"
        let img = f.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        return Group {
            if let img {
                Image(decorative: img, scale: 1).interpolation(.none).resizable()
                    .padding(4).background(.white, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
