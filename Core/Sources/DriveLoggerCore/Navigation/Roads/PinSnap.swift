import Foundation

/// A manual fix ("pin") snapped to the road (prompt 46 Part B,
/// docs/NAVIGATION.md "Manual fix", snapping).
///
/// A double tap near a road snaps to the nearest drivable edge of the road
/// network the engine uses (every edge of a pack is drivable: the builder
/// keeps only drivable `highway` classes, `RoadClass`), within a touch radius
/// of `Parameters.touchRadiusPt` on screen. Points are converted to metres
/// with the visible span: `mapSpanM` is the viewport height in metres (the
/// `manualFix` row's `mapSpanM`), so one point is `mapSpanM / viewportHeightPt`
/// metres.
///
/// The rule, in order:
/// 1. No network → `.noNetwork`. No edge within the radius (or no usable
///    span or viewport) → `.noEdgeInRadius`.
/// 2. **Junction.** A node that is an end of at least two candidate edges
///    (edges within the radius), within `junctionRadiusPt` of the tap → the
///    pin is that node (`.node`). The nearest such node wins.
/// 3. **Nearest edge.** Otherwise the nearest candidate edge N. Its
///    competitors are the nearest edge of every *other road*: another OSM way,
///    whose nearest point is not a node of N's way (two roads meeting at a
///    junction share that node; a pin there is on both, so it is not a
///    competitor). Packs carry no road names, so "another road" means another
///    way: two carriageways of one dual road are two roads here.
///    - No competitor, or the nearest competitor at least
///      `clearlyNearerRatio` (2×) as far as N (and further than N) → N.
///    - Otherwise the **cloud** decides between N and every competitor
///      nearer than `clearlyNearerRatio` × N's distance: a candidate's
///      support is the weight of the particles within
///      `cloudRadiusSigmas` × σ_pin (2σ) of its snapped point whose heading
///      is within `headingToleranceDeg` (45°) of the edge's bearing, either
///      travel direction. The candidate with at least `cloudRatio` (2×) the
///      support of each other one (and some support) wins, even if it is
///      not the nearest.
///    - Otherwise `.ambiguous`.
///
/// Pure and deterministic: candidates are ordered by distance, then by
/// edge reference; nothing depends on dictionary order. σ_pin is the
/// engine's isotropic manual-fix σ without the speed term:
/// max(`sigmaMinM`, `mapSpanM` / `spanDivisor`).
///
/// Whether a pin is accepted at all (span rules) is `placement(...)`.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public enum PinSnap {
    /// The rule's constants. The defaults are the agreed design (prompt 46).
    public struct Parameters: Hashable, Sendable {
        /// Touch radius, points on screen.
        public var touchRadiusPt = 44.0
        /// A junction node this close to the tap (points) is the pin.
        public var junctionRadiusPt = 8.0
        /// The nearest edge wins outright when every other road is at least
        /// this many times as far from the tap.
        public var clearlyNearerRatio = 2.0
        /// The cloud decides when one candidate has at least this many times
        /// the support of each other one.
        public var cloudRatio = 2.0
        /// Particles within this many σ_pin of a candidate's snapped point
        /// support it.
        public var cloudRadiusSigmas = 2.0
        /// Heading consistency, degrees, either travel direction.
        public var headingToleranceDeg = 45.0
        /// σ_pin = max(sigmaMinM, mapSpanM / spanDivisor): the engine's
        /// default `manualFixSigmaMinM` / `manualFixSpanDivisor`.
        public var sigmaMinM = 30.0
        public var spanDivisor = 12.0
        /// A snapped pin is accepted up to this span (σ = 1500 / 12 = 125 m).
        public var maxSnappedSpanM = 1500.0
        /// A pin that did not snap is accepted up to this span (the rule
        /// before snapping).
        public var maxUnsnappedSpanM = 300.0

        public init() {}
    }

    /// A road edge within the touch radius, at its nearest point to the tap.
    public struct Candidate: Hashable, Sendable {
        /// The edge (pack in the network's canonical order, edge index).
        public var edge: RoadNetwork.EdgeRef
        public var osmWayID: Int64
        public var highwayClass: RoadClass
        public var level: Int8
        public var isOneway: Bool
        /// The nearest point of the edge to the tap.
        public var latitude: Double
        public var longitude: Double
        /// Tap → nearest point, metres.
        public var distanceM: Double
        /// Bearing of the edge at that point, degrees clockwise from north,
        /// in the edge's stored point order (driving order for a oneway).
        public var bearingDeg: Double
        /// The nearest point is an end node of the edge: its E7 key
        /// (`latE7 << 32 | lonE7` as bit patterns); nil when interior.
        var endNodeKey: UInt64?
        /// The E7 keys of the edge's two end nodes.
        var nodeKeys: [UInt64]
    }

    /// How a snap was decided.
    public enum Decision: String, Hashable, Sendable, Codable {
        /// The only road within the radius.
        case onlyRoad
        /// The nearest road, every other road at least `clearlyNearerRatio` as far.
        case clearlyNearer
        /// The particle cloud's support (may not be the nearest road).
        case cloud
        /// A junction node within `junctionRadiusPt`.
        case junction
    }

    /// A snapped pin.
    public struct Snap: Hashable, Sendable {
        /// The pin: the point on the edge, or the junction node.
        public var latitude: Double
        public var longitude: Double
        /// Tap → pin, metres.
        public var distanceM: Double
        /// The edge snapped to (for a junction: the nearest candidate edge
        /// that ends at the node).
        public var candidate: Candidate
        public var decision: Decision
    }

    public enum Result: Hashable, Sendable {
        /// Snapped to a point on an edge.
        case edge(Snap)
        /// Snapped to a junction node.
        case node(Snap)
        /// Two or more roads at similar distance and the cloud did not
        /// decide: no snap.
        case ambiguous
        /// No edge within the touch radius (or no usable span/viewport).
        case noEdgeInRadius
        /// No road network (no packs loaded or attached).
        case noNetwork

        /// The snapped pin, for `.edge` and `.node`.
        public var snap: Snap? {
            switch self {
            case .edge(let s), .node(let s): s
            case .ambiguous, .noEdgeInRadius, .noNetwork: nil
            }
        }
    }

    /// The result and what it was decided from (replay statistics, logs).
    public struct Outcome: Hashable, Sendable {
        public var result: Result
        /// Touch radius and junction radius, metres; 0 without a usable
        /// span or viewport.
        public var radiusM: Double
        public var junctionRadiusM: Double
        /// σ_pin used for the cloud support radius.
        public var sigmaM: Double
        /// The nearest edge to the tap, if any is within the radius.
        public var nearest: Candidate?
        /// The candidates the ambiguity rule weighed (N first, then the
        /// competitors nearer than `clearlyNearerRatio` × N's distance), one
        /// per road; empty when it was not needed.
        public var contested: [Candidate]
        /// The cloud support of each `contested` candidate (same order);
        /// empty when the cloud was not consulted or not available.
        public var support: [Double]
    }

    /// One particle of the engine's cloud (geodetic), for the tie-break.
    public struct Particle: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// Radians clockwise from north.
        public var headingRad: Double
        /// Normalised weight (the cloud's weights sum to 1).
        public var weight: Double

        public init(latitude: Double, longitude: Double, headingRad: Double, weight: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.headingRad = headingRad
            self.weight = weight
        }
    }

    // MARK: Conversions

    /// Metres per screen point: `mapSpanM / viewportHeightPt`; nil unless
    /// both are finite and positive.
    public static func metresPerPoint(mapSpanM: Double?, viewportHeightPt: Double) -> Double? {
        guard let mapSpanM, mapSpanM.isFinite, mapSpanM > 0, viewportHeightPt.isFinite, viewportHeightPt > 0 else {
            return nil
        }
        return mapSpanM / viewportHeightPt
    }

    /// `points` on screen in metres at this span and viewport; nil when the
    /// span or viewport is not usable.
    public static func radiusM(points: Double, mapSpanM: Double?, viewportHeightPt: Double) -> Double? {
        metresPerPoint(mapSpanM: mapSpanM, viewportHeightPt: viewportHeightPt).map { points * $0 }
    }

    /// σ_pin = max(sigmaMinM, mapSpanM / spanDivisor); sigmaMinM without a
    /// usable span.
    public static func sigmaM(mapSpanM: Double?, parameters: Parameters = Parameters()) -> Double {
        guard let mapSpanM, mapSpanM.isFinite, mapSpanM >= 0, parameters.spanDivisor > 0 else {
            return parameters.sigmaMinM
        }
        return max(parameters.sigmaMinM, mapSpanM / parameters.spanDivisor)
    }

    // MARK: Snap

    /// Snaps a tap at (`latitude`, `longitude`) on a map `mapSpanM` tall
    /// (metres) in a viewport `viewportHeightPt` tall (points). `cloud`:
    /// the engine's particles (`NavigationEngine.pinSnapCloud()`), nil when
    /// it has none; then a contested tap is `.ambiguous`.
    public static func snap(
        latitude: Double, longitude: Double, mapSpanM: Double?, viewportHeightPt: Double,
        network: RoadNetwork?, cloud: [Particle]?, parameters: Parameters = Parameters()
    ) -> Outcome {
        let sigma = sigmaM(mapSpanM: mapSpanM, parameters: parameters)
        var outcome = Outcome(result: .noNetwork, radiusM: 0, junctionRadiusM: 0, sigmaM: sigma,
                              nearest: nil, contested: [], support: [])
        guard let network else { return outcome }
        outcome.result = .noEdgeInRadius
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180,
              let radius = radiusM(points: parameters.touchRadiusPt, mapSpanM: mapSpanM, viewportHeightPt: viewportHeightPt),
              let junctionRadius = radiusM(points: parameters.junctionRadiusPt, mapSpanM: mapSpanM,
                                           viewportHeightPt: viewportHeightPt)
        else { return outcome }
        outcome.radiusM = radius
        outcome.junctionRadiusM = junctionRadius

        let candidates = Self.candidates(latitude: latitude, longitude: longitude, radiusM: radius, network: network)
        guard let nearest = candidates.first else { return outcome }
        outcome.nearest = nearest
        let frame = LocalFrame(latitude: latitude, longitude: longitude)

        // 2. Junction: a node that ends at least two candidate edges.
        var nodeEdges: [UInt64: [Candidate]] = [:]
        for c in candidates {
            for key in Set(c.nodeKeys) { nodeEdges[key, default: []].append(c) }
        }
        var bestNode: (key: UInt64, distance: Double)?
        for (key, edges) in nodeEdges where Set(edges.map(\.edge)).count >= 2 {
            let p = frame.offset(Self.point(ofKey: key))
            let d = (p.x * p.x + p.y * p.y).squareRoot()
            guard d <= junctionRadius else { continue }
            if let b = bestNode, (b.distance, b.key) <= (d, key) { continue }
            bestNode = (key, d)
        }
        if let node = bestNode, let edge = nodeEdges[node.key]?.min(by: Self.isBefore) {
            let p = Self.point(ofKey: node.key)
            outcome.result = .node(Snap(latitude: p.latitude, longitude: p.longitude, distanceM: node.distance,
                                        candidate: edge, decision: .junction))
            return outcome
        }

        // 3. Nearest edge against the nearest edge of every other road.
        let nearestWayNodes = Set(candidates.filter { $0.osmWayID == nearest.osmWayID }.flatMap(\.nodeKeys))
        var competitors: [Candidate] = []
        var seenWays: Set<Int64> = [nearest.osmWayID]
        for c in candidates where !seenWays.contains(c.osmWayID) {
            seenWays.insert(c.osmWayID)  // candidates are by distance: the first of a way is its nearest
            if let key = c.endNodeKey, nearestWayNodes.contains(key) { continue }
            competitors.append(c)
        }
        let ratio = parameters.clearlyNearerRatio
        guard let rival = competitors.first, !(rival.distanceM > nearest.distanceM && rival.distanceM >= ratio * nearest.distanceM)
        else {
            outcome.result = .edge(Snap(latitude: nearest.latitude, longitude: nearest.longitude,
                                        distanceM: nearest.distanceM, candidate: nearest,
                                        decision: competitors.isEmpty ? .onlyRoad : .clearlyNearer))
            return outcome
        }
        let contested = [nearest] + competitors.filter { !($0.distanceM > nearest.distanceM && $0.distanceM >= ratio * nearest.distanceM) }
        outcome.contested = contested
        outcome.result = .ambiguous
        guard let cloud, !cloud.isEmpty else { return outcome }

        // The cloud's support of each contested candidate.
        let reach = parameters.cloudRadiusSigmas * sigma
        let reach2 = reach * reach
        let tolerance = parameters.headingToleranceDeg * .pi / 180
        let targets = contested.map { c -> (x: Double, y: Double, bearing: Double) in
            let p = frame.offset(latitude: c.latitude, longitude: c.longitude)
            return (p.x, p.y, c.bearingDeg * .pi / 180)
        }
        var support = [Double](repeating: 0, count: contested.count)
        for particle in cloud where particle.weight > 0 && particle.weight.isFinite {
            let p = frame.offset(latitude: particle.latitude, longitude: particle.longitude)
            for (k, target) in targets.enumerated() {
                let dx = p.x - target.x, dy = p.y - target.y
                guard dx * dx + dy * dy <= reach2 else { continue }
                if RoadGeometry.headingDifference(heading: particle.headingRad, bearing: target.bearing, oneway: false)
                    <= tolerance {
                    support[k] += particle.weight
                }
            }
        }
        outcome.support = support
        var best = 0
        for k in support.indices where support[k] > support[best] { best = k }
        let decided = support[best] > 0
            && support.indices.allSatisfy { $0 == best || support[best] >= parameters.cloudRatio * support[$0] }
        if decided {
            let c = contested[best]
            outcome.result = .edge(Snap(latitude: c.latitude, longitude: c.longitude, distanceM: c.distanceM,
                                        candidate: c, decision: .cloud))
        }
        return outcome
    }

    // MARK: Accept / refuse

    /// What the app does with a double tap.
    public enum Placement: Hashable, Sendable {
        /// Record the pin at (`latitude`, `longitude`). `tap` is the raw tap
        /// when the pin snapped (the `manualFix` row's `tapLatitude`/
        /// `tapLongitude`), nil otherwise.
        case place(latitude: Double, longitude: Double, tapLatitude: Double?, tapLongitude: Double?)
        /// Refuse: ask for a zoom (the span is too large or unknown).
        case zoomIn
    }

    /// The accept/refuse rule (agreed design): a snapped pin (`.edge` or
    /// `.node`) is placed at the snapped point up to `maxSnappedSpanM`;
    /// anything else (no network, no edge in radius, ambiguous, or a snap
    /// above `maxSnappedSpanM`) follows the rule before snapping: the raw tap
    /// up to `maxUnsnappedSpanM`, else zoom in. An unknown or non-finite span
    /// is always `.zoomIn`.
    public static func placement(
        tapLatitude: Double, tapLongitude: Double, mapSpanM: Double?, result: Result,
        parameters: Parameters = Parameters()
    ) -> Placement {
        guard let span = mapSpanM, span.isFinite, span >= 0 else { return .zoomIn }
        if let snap = result.snap, span <= parameters.maxSnappedSpanM {
            return .place(latitude: snap.latitude, longitude: snap.longitude,
                          tapLatitude: tapLatitude, tapLongitude: tapLongitude)
        }
        if span <= parameters.maxUnsnappedSpanM {
            return .place(latitude: tapLatitude, longitude: tapLongitude, tapLatitude: nil, tapLongitude: nil)
        }
        return .zoomIn
    }

    // MARK: Candidates

    /// Every edge with a segment within `radiusM` true metres of the tap, at
    /// its nearest point, ordered by distance then edge reference.
    static func candidates(latitude: Double, longitude: Double, radiusM: Double, network: RoadNetwork) -> [Candidate] {
        let grid = network.grid
        let frame = LocalFrame(latitude: latitude, longitude: longitude)
        // Frame metres can be larger than true metres away from the grid's
        // reference latitude: widen the cell search by the frame's scale.
        let margin = (radiusM + grid.cellSizeM) / 100_000
        let scale = grid.maximumScale(minLatitude: latitude - margin, maxLatitude: latitude + margin)
        let searchRadius = radiusM * scale * (1 + RoadGrid.radiusSlackRelative) + RoadGrid.radiusSlackM
        let centre = grid.frame(latitude: latitude, longitude: longitude)
        let r2 = radiusM * radiusM
        var best: [RoadNetwork.EdgeRef: (d2: Double, x: Double, y: Double, ax: Double, ay: Double, bx: Double, by: Double,
                                         start: Int, t: Double)] = [:]
        grid.forEachCell(nearSegmentFrom: centre, to: centre, radius: searchRadius) { cx, cy in
            network.forEachSegment(inCellX: cx, y: cy) { ref in
                let s = network.segment(ref)
                let a = frame.offset(s.a), b = frame.offset(s.b)
                let p = RoadGeometry.project(px: 0, py: 0, ax: a.x, ay: a.y, bx: b.x, by: b.y)
                guard p.distanceSquared <= r2 else { return }
                let edge = RoadNetwork.EdgeRef(pack: ref.pack, edge: s.edgeIndex)
                if let old = best[edge], (old.d2, old.start) <= (p.distanceSquared, s.startPoint) { return }
                best[edge] = (p.distanceSquared, p.qx, p.qy, a.x, a.y, b.x, b.y, s.startPoint, p.t)
            }
        }
        var out: [Candidate] = []
        out.reserveCapacity(best.count)
        for (edge, hit) in best {
            let pack = network.packs[edge.pack]
            let record = pack.edge(edge.edge)
            let from = pack.node(Int(record.from)), to = pack.node(Int(record.to))
            let first = Int(record.firstPoint), last = first + Int(record.pointCount) - 2
            var endNode: UInt64?
            if hit.t <= 0, hit.start == first { endNode = key(from) }
            if hit.t >= 1, hit.start == last { endNode = key(to) }
            let geo = frame.geodetic(x: hit.x, y: hit.y)
            // An end node is the pin exactly (its E7 point), not a rounded copy.
            let point = endNode.map { Self.point(ofKey: $0) }
            out.append(Candidate(
                edge: edge, osmWayID: record.osmWayID, highwayClass: record.highwayClass, level: record.level,
                isOneway: record.isOneway,
                latitude: point?.latitude ?? geo.latitude, longitude: point?.longitude ?? geo.longitude,
                distanceM: hit.d2.squareRoot(),
                bearingDeg: RoadGeometry.bearing(east: hit.bx - hit.ax, north: hit.by - hit.ay) * 180 / .pi,
                endNodeKey: endNode, nodeKeys: [key(from), key(to)]
            ))
        }
        out.sort(by: isBefore)
        return out
    }

    static func isBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        a.distanceM != b.distanceM ? a.distanceM < b.distanceM : a.edge < b.edge
    }

    @inline(__always)
    static func key(_ p: RoadPoint) -> UInt64 {
        UInt64(UInt32(bitPattern: p.latE7)) << 32 | UInt64(UInt32(bitPattern: p.lonE7))
    }

    static func point(ofKey key: UInt64) -> RoadPoint {
        RoadPoint(latE7: Int32(bitPattern: UInt32(truncatingIfNeeded: key >> 32)),
                  lonE7: Int32(bitPattern: UInt32(truncatingIfNeeded: key)))
    }

    /// True metres east/north of the tap (equirectangular at the tap's
    /// latitude: exact enough within a touch radius).
    struct LocalFrame {
        let latE7: Double
        let lonE7: Double
        let k: (lat: Double, lon: Double)

        init(latitude: Double, longitude: Double) {
            latE7 = latitude * 1e7
            lonE7 = longitude * 1e7
            k = RoadGrid.trueMetresPerE7(latitude: latitude)
        }

        func offset(_ p: RoadPoint) -> (x: Double, y: Double) {
            ((Double(p.lonE7) - lonE7) * k.lon, (Double(p.latE7) - latE7) * k.lat)
        }

        func offset(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
            ((longitude * 1e7 - lonE7) * k.lon, (latitude * 1e7 - latE7) * k.lat)
        }

        func geodetic(x: Double, y: Double) -> (latitude: Double, longitude: Double) {
            ((latE7 + y / k.lat) / 1e7, (lonE7 + x / k.lon) / 1e7)
        }
    }
}
