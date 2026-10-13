import Foundation

/// The road side of `NavigationEngine`'s road update (docs/N3_PLAN.md,
/// "Road model in the filter"): segments in the engine's local plane, the
/// candidate search of Step 2 and the cross-track update of Step 4. The
/// engine owns the particles, the weights and the random numbers.
///
/// **Cell cache.** A pack cell's segments are converted once to the local
/// plane and kept, keyed by cell. The cache is lookup-only: its contents are
/// a pure function of (plane, cell), so its size and eviction cannot change
/// a result (tests run capacities 0 — no cache — and 1 against the
/// default). It is cleared when
/// the plane changes (a re-anchor). Within one update the cells under the
/// cloud are copied into a flat store, indexed through a dense window over
/// the cloud's cell bounding box (at most `maxWindowCells`), so the
/// per-particle loop does no hashing; a wider cloud falls back to a
/// lookup-only dictionary.
///
/// No `Dictionary` or `Set` is iterated here: iteration order would change
/// from process to process.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
struct RoadMatcher: Sendable {
    let network: RoadNetwork
    /// First global edge index of each pack (load order), and the total.
    let edgeBase: [Int]
    let cacheCapacity: Int

    static let defaultCacheCapacity = 4096
    /// Largest dense window over the cloud's cells (128 × 128).
    static let maxWindowCells = 128 * 128
    /// `roadEdge` of a particle on no edge.
    static let noEdge = UInt32.max

    private var cache: [UInt64: PlaneCell] = [:]
    private var cachePlane: LocalTangentPlane?
    /// The current update's cells, flat (see `Store`).
    private(set) var store = Store()

    init(network: RoadNetwork, cacheCapacity: Int = RoadMatcher.defaultCacheCapacity) {
        self.network = network
        var base = [0]
        for pack in network.packs { base.append(base[base.count - 1] + pack.edgeCount) }
        edgeBase = base
        self.cacheCapacity = max(0, cacheCapacity)
    }

    /// A cell's segments in one local plane, structure of arrays.
    struct PlaneCell: Sendable {
        var ax: [Double] = [], ay: [Double] = []
        /// Unit direction (east, north) — the sin and cos of the forward
        /// bearing — and length, metres.
        var ux: [Double] = [], uy: [Double] = [], length: [Double] = []
        /// Global edge index (`edgeBase[pack] + edge`).
        var edge: [UInt32] = []
        var oneway: [Bool] = []
        var level: [Int8] = []
        /// Segment key, for ties.
        var way: [Int64] = [], index: [UInt32] = []

        var count: Int { ax.count }
    }

    /// The cells of one update, concatenated: cell k holds segments
    /// `start[k] ..< start[k + 1]`.
    struct Store: Sendable {
        var cells = PlaneCell()
        var start: [Int] = [0]

        mutating func removeAll() {
            cells = PlaneCell()
            start = [0]
        }
    }

    // MARK: Cells

    /// Forgets every cached cell (a re-anchor moved the plane).
    mutating func clearCache() {
        cache.removeAll()
        cachePlane = nil
    }

    /// The pack cell containing plane point (east, north).
    func cell(east: Double, north: Double, plane: LocalTangentPlane) -> (cx: Int32, cy: Int32) {
        let p = plane.geodetic(east: east, north: north)
        return network.grid.cell(latitude: p.latitude, longitude: p.longitude)
    }

    /// The segments of a cell in `plane`, from the cache or the packs.
    mutating func planeCell(cx: Int32, cy: Int32, plane: LocalTangentPlane) -> PlaneCell {
        if cachePlane != plane {
            cache.removeAll()
            cachePlane = plane
        }
        guard cacheCapacity > 0 else { return load(cx: cx, cy: cy, plane: plane) }
        let key = RoadGrid.key(cx: cx, cy: cy)
        if let cell = cache[key] { return cell }
        let cell = load(cx: cx, cy: cy, plane: plane)
        if cache.count >= cacheCapacity { cache.removeAll() }
        cache[key] = cell
        return cell
    }

    private func load(cx: Int32, cy: Int32, plane: LocalTangentPlane) -> PlaneCell {
        var c = PlaneCell()
        network.forEachSegment(inCellX: cx, y: cy) { ref in
            let pack = network.packs[ref.pack]
            let s = pack.segment(startingAt: ref.startPoint)
            let record = pack.edge(s.edgeIndex)
            let a = plane.enu(latitude: s.a.latitude, longitude: s.a.longitude)
            let b = plane.enu(latitude: s.b.latitude, longitude: s.b.longitude)
            let dx = b.east - a.east, dy = b.north - a.north
            let length = (dx * dx + dy * dy).squareRoot()
            // A verified pack has no zero-length segment; an unverified one
            // gets a unit vector north rather than a division by zero.
            let ux = length > 0 ? dx / length : 0, uy = length > 0 ? dy / length : 1
            c.ax.append(a.east); c.ay.append(a.north)
            c.ux.append(ux); c.uy.append(uy); c.length.append(length)
            c.edge.append(UInt32(edgeBase[ref.pack] + s.edgeIndex))
            c.oneway.append(record.isOneway)
            c.level.append(record.level)
            c.way.append(s.key.osmWayID); c.index.append(s.key.index)
        }
        return c
    }

    /// Starts an update: the store is emptied.
    mutating func beginUpdate() {
        store.removeAll()
    }

    /// The store index of each cell in `cells`, loading every distinct cell
    /// into the store once (in first-appearance order).
    mutating func storeIndices(of cells: [(cx: Int32, cy: Int32)], plane: LocalTangentPlane) -> [Int] {
        guard let first = cells.first else { return [] }
        var x0 = Int64(first.cx), x1 = x0, y0 = Int64(first.cy), y1 = y0
        for c in cells {
            x0 = min(x0, Int64(c.cx)); x1 = max(x1, Int64(c.cx))
            y0 = min(y0, Int64(c.cy)); y1 = max(y1, Int64(c.cy))
        }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var out = [Int](repeating: 0, count: cells.count)
        if w * h <= Int64(Self.maxWindowCells) {
            var window = [Int](repeating: -1, count: Int(w * h))
            for (i, c) in cells.enumerated() {
                let slot = Int((Int64(c.cy) - y0) * w + (Int64(c.cx) - x0))
                if window[slot] < 0 { window[slot] = append(cx: c.cx, cy: c.cy, plane: plane) }
                out[i] = window[slot]
            }
        } else {
            var seen: [UInt64: Int] = [:]  // lookup only
            for (i, c) in cells.enumerated() {
                let key = RoadGrid.key(cx: c.cx, cy: c.cy)
                if let k = seen[key] {
                    out[i] = k
                } else {
                    let k = append(cx: c.cx, cy: c.cy, plane: plane)
                    seen[key] = k
                    out[i] = k
                }
            }
        }
        return out
    }

    /// Appends a cell to the store; returns its store index.
    private mutating func append(cx: Int32, cy: Int32, plane: LocalTangentPlane) -> Int {
        let c = planeCell(cx: cx, cy: cy, plane: plane)
        store.cells.ax += c.ax; store.cells.ay += c.ay
        store.cells.ux += c.ux; store.cells.uy += c.uy; store.cells.length += c.length
        store.cells.edge += c.edge; store.cells.oneway += c.oneway; store.cells.level += c.level
        store.cells.way += c.way; store.cells.index += c.index
        store.start.append(store.cells.count)
        return store.start.count - 2
    }

    // MARK: Geometry

    /// The nearest point of segment k (store) to p: squared distance and
    /// the unit vector h from the segment towards p — the segment's normal
    /// when the projection is interior, (p − Q)/d at an end vertex, and the
    /// normal when p lies on the segment.
    @inline(__always)
    static func nearest(
        px: Double, py: Double, ax: Double, ay: Double, ux: Double, uy: Double, length: Double
    ) -> (distanceSquared: Double, hx: Double, hy: Double) {
        let rx = px - ax, ry = py - ay
        let s = rx * ux + ry * uy
        // Normal: the direction 90° counter-clockwise of u.
        let nx = -uy, ny = ux
        if s > 0 && s < length {
            let c = rx * nx + ry * ny
            return c < 0 ? (c * c, -nx, -ny) : (c * c, nx, ny)
        }
        let qx = s <= 0 ? ax : ax + length * ux, qy = s <= 0 ? ay : ay + length * uy
        let ex = px - qx, ey = py - qy
        let d2 = ex * ex + ey * ey
        guard d2 > 0 else { return (0, nx, ny) }
        let d = d2.squareRoot()
        return (d2, ex / d, ey / d)
    }

    /// Whether some segment of store cell `k` lies within `radius` of p.
    func anySegment(inStoreCell k: Int, px: Double, py: Double, radius: Double) -> Bool {
        let c = store.cells
        let r2 = radius * radius
        for j in store.start[k]..<store.start[k + 1] {
            let n = Self.nearest(px: px, py: py, ax: c.ax[j], ay: c.ay[j], ux: c.ux[j], uy: c.uy[j], length: c.length[j])
            if n.distanceSquared <= r2 { return true }
        }
        return false
    }

    // MARK: Candidates (Step 2)

    struct Parameters {
        var radius: Double
        var sigmaRoad2: Double
        var headingSigma: Double
        var cosHeadingGate: Double
        var chi2: Double
        var levelHops: Int
        /// −log(2π σψ): the constant of L_road per metre and radian, with
        /// −½ log S₀ added per candidate.
        var logConstant: Double

        init(config: NavigationConfig) {
            radius = config.roadSearchRadiusM
            sigmaRoad2 = config.roadSigmaM * config.roadSigmaM
            headingSigma = config.roadHeadingSigmaDeg * .pi / 180
            cosHeadingGate = cos(min(180, config.roadHeadingGateDeg) * .pi / 180)
            chi2 = config.roadInnovationGateChi2
            levelHops = config.roadLevelHops
            logConstant = -log(2 * .pi * headingSigma)
        }
    }

    struct Candidate {
        var logLikelihood: Double
        var distance: Double
        var hx: Double, hy: Double
        var edge: UInt32
        var level: Int8
    }

    struct Work {
        var tests = 0
        var levelBlocked = 0
    }

    /// e* for one particle: the eligible segment of store cell `k` with the
    /// largest L_road, ties to the lower segment key; nil when none is
    /// eligible. Heading is tested first (a dot product), then squared
    /// distance, then the χ² gate, then the level rule (only for a
    /// candidate otherwise eligible, so `levelBlocked` counts roads the
    /// level rule alone refused).
    func best(
        inStoreCell k: Int, px: Double, py: Double, sinPsi: Double, cosPsi: Double,
        ee: Double, en: Double, nn: Double, level: Int8, edge: UInt32,
        parameters q: Parameters, work: inout Work
    ) -> Candidate? {
        let c = store.cells
        let range = store.start[k]..<store.start[k + 1]
        work.tests += range.count
        let r2 = q.radius * q.radius
        var best: Candidate?
        var bestWay = Int64.max, bestIndex = UInt32.max
        for j in range {
            let dot = sinPsi * c.ux[j] + cosPsi * c.uy[j]
            let oneway = c.oneway[j]
            guard oneway ? dot >= q.cosHeadingGate : abs(dot) >= q.cosHeadingGate else { continue }
            let near = Self.nearest(px: px, py: py, ax: c.ax[j], ay: c.ay[j], ux: c.ux[j], uy: c.uy[j], length: c.length[j])
            let d2 = near.distanceSquared
            guard d2 <= r2 else { continue }
            let pcc = near.hx * near.hx * ee + 2 * near.hx * near.hy * en + near.hy * near.hy * nn
            let s0 = pcc + q.sigmaRoad2
            guard d2 <= q.chi2 * s0 else { continue }
            let candidateLevel = c.level[j]
            if !RoadGeometry.levelAllows(particleLevel: level, candidateLevel: candidateLevel,
                                         withinHops: { isEdge(c.edge[j], withinHops: q.levelHops, of: edge) }) {
                work.levelBlocked += 1
                continue
            }
            let cross = sinPsi * c.uy[j] - cosPsi * c.ux[j]
            let dPsi = atan2(abs(cross), oneway ? dot : abs(dot))
            let z = dPsi / q.headingSigma
            let logL = -0.5 * d2 / s0 - 0.5 * log(s0) - 0.5 * z * z + q.logConstant
            let way = c.way[j], index = c.index[j]
            if let b = best {
                guard logL > b.logLikelihood || (logL == b.logLikelihood && (way, index) < (bestWay, bestIndex)) else { continue }
            }
            best = Candidate(logLikelihood: logL, distance: d2.squareRoot(), hx: near.hx, hy: near.hy,
                             edge: c.edge[j], level: candidateLevel)
            bestWay = way
            bestIndex = index
        }
        return best
    }

    /// Whether global edge `b` is within `hops` of global edge `a` in the
    /// pack's adjacency. Across packs there is no adjacency: false.
    func isEdge(_ b: UInt32, withinHops hops: Int, of a: UInt32) -> Bool {
        guard a != Self.noEdge else { return false }
        let pa = pack(ofEdge: a), pb = pack(ofEdge: b)
        guard pa == pb else { return false }
        return network.packs[pa].isEdge(Int(b) - edgeBase[pa], withinHops: hops, of: Int(a) - edgeBase[pa])
    }

    func pack(ofEdge e: UInt32) -> Int {
        var p = 0
        while p + 2 < edgeBase.count && Int(e) >= edgeBase[p + 1] { p += 1 }
        return p
    }

    /// The pack, edge and way of a global edge index.
    func matchedEdge(_ e: UInt32) -> MatchedRoadEdge {
        let p = pack(ofEdge: e)
        let local = Int(e) - edgeBase[p]
        return MatchedRoadEdge(pack: p, edge: local, osmWayID: network.packs[p].edge(local).osmWayID)
    }

    // MARK: Fix gate

    /// Whether any segment, of any level, lies within `radius` of plane
    /// point p, heading-compatible with `course` (radians, plane frame)
    /// when one is given. Every cell whose rectangle can hold such a
    /// segment is visited (the radius can exceed the pack's).
    mutating func anyCompatibleSegment(
        east px: Double, north py: Double, radius: Double, course: Double?, cosHeadingGate: Double,
        plane: LocalTangentPlane
    ) -> Bool {
        let p = plane.geodetic(east: px, north: py)
        let grid = network.grid
        let f = grid.frame(latitude: p.latitude, longitude: p.longitude)
        // Frame metres and plane metres differ by the frame's scale error
        // (≪ 1 % inside a family): a margin covers it.
        let reach = radius * 1.01 + 1
        let lo = grid.cell(x: f.x - reach, y: f.y - reach), hi = grid.cell(x: f.x + reach, y: f.y + reach)
        let r2 = radius * radius
        let sinC = course.map(sin), cosC = course.map(cos)
        var cy = lo.cy
        while cy <= hi.cy {
            var cx = lo.cx
            while cx <= hi.cx {
                let c = planeCell(cx: cx, cy: cy, plane: plane)
                for j in 0..<c.count {
                    if let sinC, let cosC {
                        let dot = sinC * c.ux[j] + cosC * c.uy[j]
                        guard c.oneway[j] ? dot >= cosHeadingGate : abs(dot) >= cosHeadingGate else { continue }
                    }
                    let n = Self.nearest(px: px, py: py, ax: c.ax[j], ay: c.ay[j], ux: c.ux[j], uy: c.uy[j], length: c.length[j])
                    if n.distanceSquared <= r2 { return true }
                }
                if cx == Int32.max { break }
                cx += 1
            }
            if cy == Int32.max { break }
            cy += 1
        }
        return false
    }

    // MARK: Cross-track update (Step 4)

    /// The road-frame update of one particle: across the road (c, along h)
    /// the measurement "offset = 0" with noise `rw` and innovation −d;
    /// along it (a), the gain is `coupling` × the Kalman gain. Returns the
    /// mean change (Δa, Δc) and the updated covariance in the road frame.
    /// - coupling 0 (Schmidt): Δa = 0 and P′_aa = P_aa exactly;
    ///   P′_ac = P_ac (1 − g), P′_cc = P_cc R_w / S_w, g = P_cc / S_w.
    /// - coupling 1 (Kalman): K = P h / S_w, P′ = P − (P h)(P h)ᵀ / S_w.
    /// - between: K_a = coupling · P_ac / S_w, K_c = g, Joseph form.
    @inline(__always)
    static func crossTrackUpdate(
        paa: Double, pac: Double, pcc: Double, distance d: Double, rw: Double, coupling: Double
    ) -> (da: Double, dc: Double, paa: Double, pac: Double, pcc: Double) {
        let sw = pcc + rw
        let g = pcc / sw
        let y = -d
        if coupling == 0 {
            return (0, g * y, paa, pac * (1 - g), pcc * rw / sw)
        }
        if coupling == 1 {
            let ka = pac / sw
            return (ka * y, g * y, paa - pac * pac / sw, pac - pac * pcc / sw, pcc - pcc * pcc / sw)
        }
        let ka = coupling * pac / sw, kc = g
        let oneMinus = 1 - kc
        let newAA = paa - 2 * ka * pac + ka * ka * pcc + ka * ka * rw
        let newAC = (pac - ka * pcc) * oneMinus + ka * kc * rw
        let newCC = oneMinus * oneMinus * pcc + kc * kc * rw
        return (ka * y, kc * y, newAA, newAC, newCC)
    }
}
