import Foundation
import MapKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Boat routing that actually stays on water — fully on-device, no server.
// Render Apple Maps for the leg's area, classify water pixels by their blue, close small gaps
// (bridges, borders and labels drawn over rivers), then A* through water with a cost that keeps
// the boat off the shoreline. The grid path is string-pulled into straight runs over open water.

enum WaterRouter {
    static let grid = 900   // pixels on the long side

    /// nil = couldn't find a water path (caller falls back to a straight line).
    static func route(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let pa = MKMapPoint(a), pb = MKMapPoint(b)
        var rect = MKMapRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                             width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
        // pad so the boat can swing round headlands; at least ~3 km of context
        let minSide = 3000 * MKMapPointsPerMeterAtLatitude((a.latitude + b.latitude) / 2)
        let base = max(rect.width, rect.height, minSide)
        let n = grid
        // No path inside a tight box usually means the water goes around something (an island, a
        // peninsula) — widen the view and try again.
        for pad in [1.4, 3.0, 7.0] {
            let side = base * pad
            let box = MKMapRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            guard let rgba = await snapshot(box, size: n) else { return nil }
            let r = await Task.detached(priority: .userInitiated) {
                solve(rgba: rgba, n: n, rect: box, a: pa, b: pb)
            }.value
            if let r { return r }
        }
        return nil
    }

    // MARK: snapshot → RGBA bytes (1 px per point, light mode so water is the classic blue)

    static func snapshot(_ rect: MKMapRect, size n: Int) async -> [UInt8]? {
        let o = MKMapSnapshotter.Options()
        o.mapRect = rect
        o.pointOfInterestFilter = .excludingAll
        o.showsBuildings = false
        #if os(iOS)
        o.size = CGSize(width: n, height: n)
        o.traitCollection = UITraitCollection(traitsFrom: [.init(displayScale: 1), .init(userInterfaceStyle: .light)])
        guard let snap = try? await MKMapSnapshotter(options: o).start(),
              let cg = snap.image.cgImage else { return nil }
        #else
        o.size = NSSize(width: n, height: n)
        o.appearance = NSAppearance(named: .aqua)
        guard let snap = try? await MKMapSnapshotter(options: o).start(),
              let cg = snap.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? buf : nil
    }

    // MARK: grid solve

    static func solve(rgba: [UInt8], n: Int, rect: MKMapRect, a: MKMapPoint, b: MKMapPoint) -> [CLLocationCoordinate2D]? {
        let N = n * n
        // 1. classify — Apple water ≈ (130-175, 185-220, 225-252); land/roads are near-white, parks green
        var water = [Bool](repeating: false, count: N)
        for i in 0..<N {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), bl = Int(rgba[i * 4 + 2])
            water[i] = bl > 185 && bl - r > 40 && bl >= g
        }
        // 2. closing (dilate then erode) bridges thin roads/bridges/labels drawn across rivers
        let r = max(2, n / 220)
        water = erode(dilate(water, n, r), n, r)
        // 3. distance from shore (BFS, capped) → shoreline penalty
        let cap = 14
        var shore = [Int](repeating: cap, count: N)
        var q = [Int](); q.reserveCapacity(N)
        for i in 0..<N where !water[i] { shore[i] = 0; q.append(i) }
        var head = 0
        while head < q.count {
            let i = q[head]; head += 1
            let d = shore[i]; if d >= cap { continue }
            let x = i % n, y = i / n
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < n, ny < n else { continue }
                let j = ny * n + nx
                if shore[j] > d + 1 { shore[j] = d + 1; q.append(j) }
            }
        }

        func toPx(_ p: MKMapPoint) -> Int {
            let x = min(n - 1, max(0, Int((p.x - rect.minX) / rect.width * Double(n))))
            let y = min(n - 1, max(0, Int((p.y - rect.minY) / rect.height * Double(n))))
            return y * n + x
        }
        func toCoord(_ i: Int) -> CLLocationCoordinate2D {
            let x = (Double(i % n) + 0.5) / Double(n) * rect.width + rect.minX
            let y = (Double(i / n) + 0.5) / Double(n) * rect.height + rect.minY
            return MKMapPoint(x: x, y: y).coordinate
        }
        // 4. snap endpoints to the nearest water (start from a dock on land → nearest shore)
        guard let s = nearestWater(toPx(a), water, n), let t = nearestWater(toPx(b), water, n) else { return nil }

        // 5. A*
        var gScore = [Float](repeating: .infinity, count: N)
        var came = [Int32](repeating: -1, count: N)
        var heap = MinHeap()
        let tx = Float(t % n), ty = Float(t / n)
        func h(_ i: Int) -> Float { let dx = Float(i % n) - tx, dy = Float(i / n) - ty; return (dx * dx + dy * dy).squareRoot() }
        gScore[s] = 0; heap.push(h(s), s)
        let nbr: [(Int, Int, Float)] = [(1,0,1),(-1,0,1),(0,1,1),(0,-1,1),(1,1,1.4142),(1,-1,1.4142),(-1,1,1.4142),(-1,-1,1.4142)]
        var found = false
        while let (_, i) = heap.pop() {
            if i == t { found = true; break }
            let x = i % n, y = i / n, gi = gScore[i]
            for (dx, dy, step) in nbr {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < n, ny < n else { continue }
                let j = ny * n + nx
                guard water[j] else { continue }
                let cost = gi + step * (1 + 4 / Float(1 + shore[j]))
                if cost < gScore[j] { gScore[j] = cost; came[j] = Int32(i); heap.push(cost + h(j), j) }
            }
        }
        guard found else { return nil }
        var path = [t]
        while let last = path.last, last != s { path.append(Int(came[last])) }
        path.reverse()

        // 6. string-pull: keep only turns needed to stay on water (prefer lines ≥3 px from shore)
        var pulled = [path[0]]
        var k = 0
        while k < path.count - 1 {
            var far = k + 1
            var j = path.count - 1
            while j > k + 1 {
                if clearLine(path[k], path[j], water, shore, n) { far = j; break }
                j -= max(1, (j - k) / 24)
            }
            pulled.append(path[far]); k = far
        }
        var out = [a.coordinate]
        out += pulled.map(toCoord)
        out.append(b.coordinate)
        return out
    }

    private static func clearLine(_ i: Int, _ j: Int, _ water: [Bool], _ shore: [Int], _ n: Int) -> Bool {
        var x0 = i % n, y0 = i / n
        let x1 = j % n, y1 = j / n
        let dx = abs(x1 - x0), dy = -abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            let p = y0 * n + x0
            if !water[p] || (shore[p] < 2 && p != i && p != j) { return false }
            if x0 == x1 && y0 == y1 { return true }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    private static func nearestWater(_ i: Int, _ water: [Bool], _ n: Int) -> Int? {
        if water[i] { return i }
        var seen = Set<Int>([i]); var q = [i]; var head = 0
        while head < q.count {
            let c = q[head]; head += 1
            let x = c % n, y = c / n
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < n, ny < n else { continue }
                let j = ny * n + nx
                if seen.contains(j) { continue }
                if water[j] { return j }
                seen.insert(j); q.append(j)
            }
        }
        return nil
    }

    private static func dilate(_ m: [Bool], _ n: Int, _ r: Int) -> [Bool] { morph(m, n, r, any: true) }
    private static func erode(_ m: [Bool], _ n: Int, _ r: Int) -> [Bool] { morph(m, n, r, any: false) }
    /// separable square max/min filter
    private static func morph(_ m: [Bool], _ n: Int, _ r: Int, any: Bool) -> [Bool] {
        var tmp = m, out = m
        for y in 0..<n {
            var run = 0   // count of `any`-valued cells in the window
            let row = y * n
            for x in 0..<min(r, n) where m[row + x] == any { run += 1 }
            for x in 0..<n {
                if x + r < n, m[row + x + r] == any { run += 1 }
                if x - r - 1 >= 0, m[row + x - r - 1] == any { run -= 1 }
                tmp[row + x] = run > 0 ? any : !any
            }
        }
        for x in 0..<n {
            var run = 0
            for y in 0..<min(r, n) where tmp[y * n + x] == any { run += 1 }
            for y in 0..<n {
                if y + r < n, tmp[(y + r) * n + x] == any { run += 1 }
                if y - r - 1 >= 0, tmp[(y - r - 1) * n + x] == any { run -= 1 }
                out[y * n + x] = run > 0 ? any : !any
            }
        }
        return out
    }
}

private struct MinHeap {
    private var a: [(Float, Int)] = []
    mutating func push(_ k: Float, _ v: Int) {
        a.append((k, v)); var i = a.count - 1
        while i > 0 { let p = (i - 1) / 2; if a[p].0 <= a[i].0 { break }; a.swapAt(p, i); i = p }
    }
    mutating func pop() -> (Float, Int)? {
        guard !a.isEmpty else { return nil }
        let top = a[0]; let last = a.removeLast()
        if !a.isEmpty {
            a[0] = last; var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1; var m = i
                if l < a.count, a[l].0 < a[m].0 { m = l }
                if r < a.count, a[r].0 < a[m].0 { m = r }
                if m == i { break }
                a.swapAt(m, i); i = m
            }
        }
        return top
    }
}
