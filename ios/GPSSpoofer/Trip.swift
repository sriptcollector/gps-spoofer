import Foundation
import MapKit

// Travel simulation: pick real waypoints, choose walk / drive / boat, and the fake location moves
// along the route at a believable pace (real road/footpath geometry from Apple Maps, acceleration,
// braking into corners, stops at each waypoint). Every tick goes through Spoofer → OnDeviceGPS.

// MARK: - Spoofer: one place that moves the fake location

@MainActor
final class Spoofer {
    static let shared = Spoofer()

    func move(_ c: CLLocationCoordinate2D, name: String) {
        GeoSpoof.set(c.latitude, c.longitude, name: name)
        OnDeviceGPS.shared.set(c.latitude, c.longitude)
    }

    func stop() {
        GeoSpoof.off()
        OnDeviceGPS.shared.clear()
    }
}

// MARK: - Travel modes

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, drive, boat
    var id: String { rawValue }
    var label: String { ["walk": "Walk", "drive": "Drive", "boat": "Boat"][rawValue]! }
    var icon: String { ["walk": "figure.walk", "drive": "car.fill", "boat": "ferry.fill"][rawValue]! }
    /// Typical cruising speed, m/s (drive uses Apple's per-leg estimate instead when it has one).
    var cruise: Double { ["walk": 1.4, "drive": 13.0, "boat": 10.0][rawValue]! }
    /// Comfortable acceleration / braking, m/s².
    var accel: Double { ["walk": 0.6, "drive": 2.2, "boat": 0.4][rawValue]! }
    var brake: Double { ["walk": 0.8, "drive": 3.0, "boat": 0.3][rawValue]! }
}

struct Waypoint: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var coord: CLLocationCoordinate2D
    static func == (a: Waypoint, b: Waypoint) -> Bool { a.id == b.id }
}

// MARK: - Trip engine

@MainActor
final class TripEngine: ObservableObject {
    static let shared = TripEngine()

    @Published var waypoints: [Waypoint] = []
    @Published var mode: TravelMode = .drive { didSet { if mode != oldValue { invalidate() } } }
    @Published var timeScale: Double = 1        // 1× = real time
    @Published private(set) var route: [CLLocationCoordinate2D] = []
    @Published private(set) var planning = false
    @Published private(set) var running = false
    @Published private(set) var position: CLLocationCoordinate2D?
    @Published private(set) var speed: Double = 0          // m/s, current
    @Published private(set) var done: Double = 0           // meters travelled
    @Published private(set) var total: Double = 0          // route length, meters
    @Published private(set) var message = ""

    // Per-vertex data, parallel to `route`.
    private var cum: [Double] = []        // cumulative distance at each vertex
    private var limit: [Double] = []      // max speed allowed AT that vertex (corners, stops)
    private var cruiseAt: [Double] = []   // cruise speed on the segment starting at that vertex
    private var timer: Timer?
    private var dwell: Double = 0         // seconds left parked at a waypoint
    private var nextStopIdx = 0
    private var stopVerts: [Int] = []     // vertex index of each waypoint after the first

    var etaSeconds: Double {
        guard total > 0 else { return 0 }
        let v = max(mode.cruise, 0.1)
        return (total - done) / v / max(timeScale, 0.1)
    }

    func add(_ c: CLLocationCoordinate2D, name: String) {
        waypoints.append(Waypoint(name: name, coord: c)); invalidate()
    }
    func remove(_ w: Waypoint) { waypoints.removeAll { $0 == w }; invalidate() }
    func clearAll() { stop(); waypoints = []; invalidate() }

    private var previewTask: Task<Void, Never>?
    private func invalidate() {
        if running { stop() }
        route = []; cum = []; limit = []; cruiseAt = []; total = 0; done = 0
        // draw the real route on the map as soon as there are two points
        previewTask?.cancel()
        guard waypoints.count >= 2 else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, !self.running else { return }
            await self.plan()
        }
    }

    // MARK: planning

    func plan() async {
        guard waypoints.count >= 2 else { message = "add at least 2 waypoints"; return }
        planning = true; message = "planning \(mode.label.lowercased()) route…"
        defer { planning = false }
        var pts: [CLLocationCoordinate2D] = []
        var cruise: [Double] = []
        var stops: Set<Int> = []
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i].coord, b = waypoints[i + 1].coord
            var leg: [CLLocationCoordinate2D]
            var legCruise = mode.cruise
            switch mode {
            case .boat:
                if let water = await WaterRouter.route(a, b) {
                    leg = densify(water, step: 120)
                } else {
                    message = "no water path for leg \(i + 1) — going straight"
                    leg = densify([a, b], step: 150)
                }
            case .walk, .drive:
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
                req.transportType = mode == .walk ? .walking : .automobile
                do {
                    let r = try await MKDirections(request: req).calculate()
                    guard let best = r.routes.first else { throw URLError(.cannotFindHost) }
                    leg = best.polyline.coordinates
                    if mode == .drive, best.expectedTravelTime > 0 {
                        // Apple's ETA already blends highway vs. city; driving a little above the
                        // average between corners lands close to its estimate once we brake for turns.
                        legCruise = min(max(best.distance / best.expectedTravelTime * 1.15, 7), 34)
                    }
                } catch {
                    message = "no \(mode.label.lowercased()) route for leg \(i + 1) — going straight"
                    leg = densify([a, b], step: 50)
                }
            }
            if !pts.isEmpty { leg.removeFirst() }
            pts += leg
            cruise += Array(repeating: legCruise, count: leg.count)
            stops.insert(pts.count - 1)
        }
        guard pts.count >= 2 else { message = "route too short"; return }

        // cumulative distances
        var c: [Double] = [0]
        for i in 1..<pts.count { c.append(c[i - 1] + dist(pts[i - 1], pts[i])) }

        // corner + stop speed caps
        var lim = Array(repeating: Double.infinity, count: pts.count)
        lim[0] = 0; lim[pts.count - 1] = 0
        for s in stops { lim[s] = 0 }
        if mode != .boat {
            for i in 1..<(pts.count - 1) where lim[i] > 0 {
                let turn = turnAngle(pts[i - 1], pts[i], pts[i + 1])
                if mode == .drive {
                    lim[i] = turn > 75 ? 4.5 : turn > 45 ? 7 : turn > 25 ? 11 : turn > 12 ? 16 : .infinity
                } else {
                    lim[i] = turn > 60 ? 1.1 : .infinity
                }
            }
        }
        route = pts; cum = c; limit = lim; cruiseAt = cruise; total = c.last ?? 0
        stopVerts = stops.sorted()
        done = 0; position = pts[0]; speed = 0; nextStopIdx = 1
        message = String(format: "%@ · %.1f km", mode.label.lowercased(), total / 1000)
    }

    // MARK: playback

    func start() async {
        previewTask?.cancel()
        if route.isEmpty { await plan() }
        guard !route.isEmpty else { return }
        if done >= total { done = 0; speed = 0; nextStopIdx = 1 }
        running = true
        if let p = position { Spoofer.shared.move(p, name: "\(mode.label) trip") }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in TripEngine.shared.tick(1) }
        }
    }

    func pause() { running = false; timer?.invalidate(); timer = nil; speed = 0 }
    func stop() { pause(); done = 0; dwell = 0; nextStopIdx = 1; position = route.first }

    private func tick(_ realDt: Double) {
        guard running, !route.isEmpty else { return }
        let dt = realDt * timeScale
        // sub-step so fast time scales still brake properly
        let steps = max(1, Int(ceil(dt / 1.0)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            if dwell > 0 { dwell -= h; speed = 0; continue }
            let i = segIndex(done)
            let target = min(cruiseAt[min(i, cruiseAt.count - 1)] * jitter(), brakingCap(from: done))
            if speed < target { speed = min(target, speed + mode.accel * h) }
            else { speed = max(target, speed - mode.brake * 1.5 * h) }
            // creep forward rather than stall a few meters short of a stop
            let v = max(speed, target == 0 ? 0 : 0.3)
            done = min(total, done + v * h)
            // arrived at an intermediate waypoint? park briefly
            if let stopAt = upcomingStop(), done >= cum[stopAt] - 0.5, stopAt < route.count - 1 {
                done = cum[stopAt]; speed = 0
                dwell = mode == .drive ? 8 : mode == .walk ? 5 : 15
                nextStopIdx += 1
            }
            if done >= total { break }
        }
        let p = jittered(interp(done))
        position = p
        Spoofer.shared.move(p, name: "\(mode.label) trip")
        if done >= total {
            running = false; timer?.invalidate(); timer = nil; speed = 0
            message = "arrived: \(waypoints.last?.name ?? "destination")"
        }
    }

    /// Fastest speed that still lets us brake in time for every cap ahead (v² = v₀² + 2ad).
    private func brakingCap(from s: Double) -> Double {
        var cap = Double.infinity
        var j = segIndex(s) + 1
        let horizon = mode == .drive ? 400.0 : mode == .boat ? 600.0 : 15.0
        while j < route.count, cum[j] - s <= horizon {
            if limit[j].isFinite {
                let d = max(0, cum[j] - s)
                cap = min(cap, sqrt(limit[j] * limit[j] + 2 * mode.brake * d))
            }
            j += 1
        }
        return cap
    }

    private func upcomingStop() -> Int? {
        let k = nextStopIdx - 1
        return k >= 0 && k < stopVerts.count ? stopVerts[k] : nil
    }

    private func segIndex(_ s: Double) -> Int {
        var lo = 0, hi = cum.count - 1
        while lo < hi { let m = (lo + hi + 1) / 2; if cum[m] <= s { lo = m } else { hi = m - 1 } }
        return min(lo, cum.count - 2)
    }

    private func interp(_ s: Double) -> CLLocationCoordinate2D {
        let i = segIndex(s)
        let seg = cum[i + 1] - cum[i]
        let t = seg > 0 ? (s - cum[i]) / seg : 0
        let a = route[i], b = route[i + 1]
        return .init(latitude: a.latitude + (b.latitude - a.latitude) * t,
                     longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    // small natural wobble: speed ±6%, walkers sway ~1 m, boats drift a few meters
    private func jitter() -> Double { 1 + Double.random(in: -0.06...0.06) }
    private func jittered(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let m = mode == .walk ? 0.8 : mode == .boat ? 3.0 : 0.0
        guard m > 0 else { return c }
        let dLat = Double.random(in: -m...m) / 111_111
        let dLon = Double.random(in: -m...m) / (111_111 * cos(c.latitude * .pi / 180))
        return .init(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}

// MARK: - POIs: hotels + clubs around the map view

@MainActor
final class POISearch: ObservableObject {
    @Published var items: [MKMapItem] = []
    @Published var showHotels = true
    @Published var showClubs = true
    private var task: Task<Void, Never>?

    func refresh(_ region: MKCoordinateRegion) {
        task?.cancel()
        var cats: [MKPointOfInterestCategory] = []
        if showHotels { cats.append(.hotel) }
        if showClubs { cats.append(.nightlife) }
        // POI search only makes sense zoomed in to a town, not a continent
        guard !cats.isEmpty, region.span.latitudeDelta < 0.4 else { items = []; return }
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)   // debounce map panning
            if Task.isCancelled { return }
            let req = MKLocalPointsOfInterestRequest(coordinateRegion: region)
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
            let found = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
            if !Task.isCancelled { items = Array(found.prefix(60)) }
        }
    }

    static func isHotel(_ m: MKMapItem) -> Bool { m.pointOfInterestCategory == .hotel }
}

// MARK: - geometry helpers

func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
}

private func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
    let Δλ = (b.longitude - a.longitude) * .pi / 180
    let y = sin(Δλ) * cos(φ2), x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
    return atan2(y, x) * 180 / .pi
}

private func turnAngle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Double {
    var d = abs(bearing(b, c) - bearing(a, b)).truncatingRemainder(dividingBy: 360)
    if d > 180 { d = 360 - d }
    return d
}

private func densify(_ pts: [CLLocationCoordinate2D], step: Double) -> [CLLocationCoordinate2D] {
    var out: [CLLocationCoordinate2D] = [pts[0]]
    for i in 1..<pts.count {
        let a = pts[i - 1], b = pts[i]
        // cap points per segment so a cross-continent leg can't balloon into 100k+ vertices
        let n = min(2000, max(1, Int(dist(a, b) / step)))
        for k in 1...n {
            let t = Double(k) / Double(n)
            out.append(.init(latitude: a.latitude + (b.latitude - a.latitude) * t,
                             longitude: a.longitude + (b.longitude - a.longitude) * t))
        }
    }
    return out
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var c = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&c, range: NSRange(location: 0, length: pointCount))
        return c
    }
}
