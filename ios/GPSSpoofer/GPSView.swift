import SwiftUI
import MapKit

// GPS: one full-screen satellite map. Tap anywhere (or a hotel/club, or search "Tokyo") → a pin
// with two choices: Teleport there now, or add it as a trip stop. Once there are stops a compact
// trip bar appears (walk / drive / boat, time scale, play). Everything is standalone: OnDeviceGPS
// drives the phone's own developer location service through LocalDevVPN.

// The current fake spot, persisted so the UI survives relaunch.
enum GeoSpoof {
    static let d = UserDefaults.standard
    static var on: Bool { d.bool(forKey: "gs.geo.on") }
    static var coord: (Double, Double)? {
        guard on else { return nil }
        return (d.double(forKey: "gs.geo.lat"), d.double(forKey: "gs.geo.lon"))
    }
    static func set(_ lat: Double, _ lon: Double, name: String) {
        d.set(true, forKey: "gs.geo.on"); d.set(name, forKey: "gs.geo.name")
        d.set(lat, forKey: "gs.geo.lat"); d.set(lon, forKey: "gs.geo.lon")
    }
    static func off() { d.set(false, forKey: "gs.geo.on") }
}



struct GPSView: View {
    @AppStorage("gs.geo.on") private var on = false
    @AppStorage("gs.geo.name") private var name = ""
    @AppStorage("gs.geo.lat") private var lat = 37.7749
    @AppStorage("gs.geo.lon") private var lon = -122.4194
    @ObservedObject private var device = OnDeviceGPS.shared
    @ObservedObject private var trip = TripEngine.shared
    @StateObject private var pois = POISearch()
    @State private var camera: MapCameraPosition = .automatic
    @State private var candidate: Candidate?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var follow = false
    @State private var showStops = false
    @State private var visible: MKCoordinateRegion?
    @State private var vpnUp = LocalDevVPN.isConnected
    @State private var showGuide = false
    private let vpnTick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    @FocusState private var searchFocused: Bool

    struct Candidate: Equatable {
        var coord: CLLocationCoordinate2D
        var name: String
        var detail: String?
        static func == (a: Candidate, b: Candidate) -> Bool {
            a.coord.latitude == b.coord.latitude && a.coord.longitude == b.coord.longitude && a.name == b.name
        }
    }

    private var pin: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    var body: some View {
        ZStack {
            map.ignoresSafeArea(edges: .top)
            VStack(spacing: 8) {
                topBar
                if !results.isEmpty { resultsList }
                Spacer()
                bottomStack
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
        .background(Color.black)
        .onReceive(vpnTick) { _ in
            let up = LocalDevVPN.isConnected
            if up != vpnUp { vpnUp = up; PhoneStatus.write() }
        }
        .sheet(isPresented: $showGuide) { OnboardingView { showGuide = false } }
        .onAppear {
            if on { camera = .region(.init(center: pin, latitudinalMeters: 6000, longitudinalMeters: 6000)) }
        }
        .onChange(of: trip.position?.latitude) { _, _ in
            if follow, trip.running, let p = trip.position {
                camera = .camera(MapCamera(centerCoordinate: p, distance: trip.mode == .walk ? 800 : 3000))
            }
        }
    }

    // MARK: map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if !trip.route.isEmpty {
                    MapPolyline(coordinates: trip.route).stroke(Theme.acid, lineWidth: 4)
                }
                ForEach(Array(trip.waypoints.enumerated()), id: \.element.id) { i, w in
                    Annotation("", coordinate: w.coord) {
                        Text("\(i + 1)").font(Theme.mono(11, .bold)).foregroundStyle(.black)
                            .frame(width: 22, height: 22).background(Circle().fill(Theme.acid))
                            .overlay(Circle().stroke(.black, lineWidth: 1))
                    }
                }
                ForEach(pois.items, id: \.self) { m in
                    Annotation("", coordinate: m.placemark.coordinate) {
                        Button { pick(m) } label: {
                            Image(systemName: POISearch.isHotel(m) ? "bed.double.fill" : "music.note")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(POISearch.isHotel(m) ? Color.blue : Color.pink))
                                .overlay(Circle().stroke(.white, lineWidth: 1))
                        }
                    }
                }
                if let c = candidate {
                    Marker(c.name, systemImage: "mappin", coordinate: c.coord).tint(.white)
                }
                if trip.running || trip.done > 0, let p = trip.position {
                    Annotation("", coordinate: p) {
                        Image(systemName: trip.mode.icon).font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black).frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.acid)).overlay(Circle().stroke(.black, lineWidth: 1))
                    }
                } else if on {
                    Annotation("", coordinate: pin) {
                        Circle().fill(Theme.acid).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 4)
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                visible = ctx.region
                pois.refresh(ctx.region)
            }
            .onTapGesture { pt in
                searchFocused = false; results = []
                guard let c = proxy.convert(pt, from: .local) else { return }
                candidate = Candidate(coord: c, name: "Dropped pin",
                                      detail: String(format: "%.4f, %.4f", c.latitude, c.longitude))
            }
        }
    }

    // MARK: top: search + layer toggles

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: searching ? "hourglass" : "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tokyo, North Korea, a hotel…", text: $query)
                    .font(.system(size: 15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($searchFocused)
                    .onSubmit { search(go: true) }
                    .onChange(of: query) { _, q in if q.count >= 3 { search(go: false) } else { results = [] } }
                if !query.isEmpty {
                    Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())

            chip("questionmark", on: false, tint: .clear) { showGuide = true }
            chip("bed.double.fill", on: pois.showHotels, tint: .blue) { pois.showHotels.toggle(); refreshPOIs() }
            chip("music.note", on: pois.showClubs, tint: .pink) { pois.showClubs.toggle(); refreshPOIs() }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ForEach(results, id: \.self) { m in
                Button { go(m, region: nil) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name ?? "?").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        Text(m.placemark.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9)
                }
                Divider().opacity(0.3)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: bottom: status, pin actions, trip bar

    private var bottomStack: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                statusPill
                Spacer()
                if trip.running || trip.done > 0 {
                    round(follow ? "location.fill" : "location", tint: follow ? Theme.acid : .white) { follow.toggle() }
                }
            }
            if let c = candidate { pinCard(c) }
            if !trip.waypoints.isEmpty { tripBar }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(device.live ? Theme.good : vpnUp ? Color.gray : Theme.bad).frame(width: 8, height: 8)
            Text(statusText).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .onTapGesture { if !vpnUp { LocalDevVPN.connectOrInstall() } }
            if on || trip.running {
                Button { stopAll() } label: { Text("Stop").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.acid) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusText: String {
        if !OnDeviceGPS.hasPairing { return "not paired: press Install in the Mac app" }
        if !vpnUp { return "LocalDevVPN is off: tap to connect" }
        if trip.running { return "\(trip.mode.label)ing · \(Int(trip.speed * 3.6)) km/h" }
        if on, device.live { return name.isEmpty ? "faking location" : name }
        return device.live ? "faking location" : (device.status == "idle" ? "real location" : device.status)
    }

    private func pinCard(_ c: Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let d = c.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button { candidate = nil } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                action("Teleport", "bolt.fill", filled: true) { teleport(c.coord, named: c.name); candidate = nil }
                action(trip.waypoints.isEmpty ? "Start trip here" : "Add stop", "plus") {
                    trip.add(c.coord, name: c.name); candidate = nil
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var tripBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(TravelMode.allCases) { m in
                    Button { trip.mode = m } label: {
                        Image(systemName: m.icon).font(.system(size: 14, weight: .semibold))
                            .frame(width: 38, height: 32)
                            .background(trip.mode == m ? Theme.acid : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(trip.mode == m ? .black : .white)
                    }.disabled(trip.running)
                }
                Menu {
                    ForEach([1.0, 2.0, 5.0, 20.0], id: \.self) { s in
                        Button("\(Int(s))× speed") { trip.timeScale = s }
                    }
                } label: {
                    Text("\(Int(trip.timeScale))×").font(.system(size: 13, weight: .bold))
                        .frame(width: 38, height: 32).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button { showStops.toggle() } label: {
                    Text("\(trip.waypoints.count) stop\(trip.waypoints.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Image(systemName: showStops ? "chevron.down" : "chevron.up").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button { trip.clearAll(); showStops = false } label: { Image(systemName: "trash").font(.system(size: 14)) }
                    .foregroundStyle(.secondary).padding(.leading, 4)
            }

            if showStops {
                ForEach(Array(trip.waypoints.enumerated()), id: \.element.id) { i, w in
                    HStack {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 18, height: 18).background(Circle().fill(Theme.acid))
                        Text(w.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        if !trip.running {
                            Button { trip.remove(w) } label: { Image(systemName: "minus.circle") }.foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if trip.total > 0 {
                ProgressView(value: min(trip.done, trip.total), total: trip.total).tint(Theme.acid)
                Text(String(format: "%.1f / %.1f km · ~%@ left", trip.done / 1000, trip.total / 1000, eta(trip.etaSeconds)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !trip.message.isEmpty || trip.waypoints.count < 2 {
                Text(trip.waypoints.count < 2 ? "Tap the map or a place to add a destination" : trip.message)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if trip.waypoints.count >= 2 {
                if trip.running {
                    action("Pause", "pause.fill", filled: true) { trip.pause() }
                } else {
                    action(trip.planning ? "Planning route…" : trip.done > 0 && trip.done < trip.total ? "Resume" : "Go",
                           "play.fill", filled: true) {
                        Task {
                            await trip.start()
                            follow = true
                        }
                    }
                    .disabled(trip.planning)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: small controls

    private func chip(_ icon: String, on: Bool, tint: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .foregroundStyle(.white)
        }
    }

    private func round(_ icon: String, tint: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
        }
    }

    private func action(_ t: String, _ icon: String, filled: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Label(t, systemImage: icon).font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(filled ? AnyShapeStyle(Theme.acid) : AnyShapeStyle(Color.white.opacity(0.1)),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(filled ? .black : .white)
        }
    }

    // MARK: actions

    private func pick(_ m: MKMapItem) {
        searchFocused = false
        candidate = Candidate(coord: m.placemark.coordinate, name: m.name ?? "Place", detail: m.placemark.title)
    }

    private func teleport(_ c: CLLocationCoordinate2D, named n: String) {
        if trip.running { trip.pause() }
        lat = c.latitude; lon = c.longitude; name = n; on = true
        Spoofer.shared.move(c, name: n)
    }

    private func stopAll() {
        trip.pause(); on = false
        Spoofer.shared.stop()
    }

    /// Jump to a search result: move the map there and teleport straight away.
    private func go(_ m: MKMapItem, region: MKCoordinateRegion?) {
        results = []; searchFocused = false
        query = ""
        let c = m.placemark.coordinate
        camera = .region(region ?? .init(center: c, latitudinalMeters: 5000, longitudinalMeters: 5000))
        teleport(c, named: m.name ?? "Place")
    }

    private func search(go jump: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.resultTypes = [.address, .pointOfInterest]
        searching = true
        Task {
            let resp = try? await MKLocalSearch(request: req).start()
            searching = false
            guard query.trimmingCharacters(in: .whitespaces) == q else { return }   // stale
            let items = Array((resp?.mapItems ?? []).prefix(6))
            if jump, let first = items.first {
                // a country/city search gets a region that frames the whole place
                let single = items.count == 1 ? resp?.boundingRegion : nil
                go(first, region: single)
            } else {
                results = items
            }
        }
    }

    private func refreshPOIs() { if let v = visible { pois.refresh(v) } }

    private func eta(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(max(m, 1))m"
    }
}
