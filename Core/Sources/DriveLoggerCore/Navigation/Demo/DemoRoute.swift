import Foundation

// The demo drive's route (REL-DEMO): a closed loop over the bundled demo
// pack's roads, and its drivable geometry. No coordinates in source: the
// loop is given by via nodes, each named by an OSM way and a point index in
// that way's normalised node list (docs/ROAD_PACK.md "Segment key"), and
// joined by the cheapest legal path (oneway respected) over the pack.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.

/// The bundled demo road pack: `demo.roadpack` in the app bundle. Used only
/// by the demo drive; never installed into the pack library, listed in Maps
/// or loaded together with the user's packs.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public enum DemoRoadPack {
    /// Resource name and extension in the app bundle.
    public static let name = "demo"
    public static let fileExtension = "roadpack"
    /// Content hash of the bundled pack, the one the route was designed on.
    public static let contentHash: UInt64 = 0x0b58_275f_f514_7817

    /// The bundled pack's URL, or nil when `bundle` does not carry it.
    public static func url(in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension)
    }

    /// Memory-map and verify the pack at `url` (any read-only location, the
    /// app bundle included); refuses a pack other than the bundled one.
    public static func open(at url: URL) throws -> RoadPack {
        let pack = try RoadPack(contentsOf: url, verify: true)
        guard pack.contentHash == contentHash else { throw DemoDriveError.unexpectedPack(contentHash: pack.contentHash) }
        return pack
    }
}

/// Why a demo drive could not be built.
public enum DemoDriveError: Error, Equatable, Sendable {
    /// The pack is not the bundled demo pack (`DemoRoadPack.contentHash`).
    case unexpectedPack(contentHash: UInt64)
    /// A via of the route definition is not an edge end in the pack.
    case viaNotFound(index: Int)
    /// No legal path between two consecutive vias.
    case noPath(fromVia: Int)
    /// The route definition or its geometry is not usable.
    case badRoute(String)
}

/// The loop, as data: vias in driving order (the loop closes back to the
/// first), where the lap starts, and which via has the full stop.
struct DemoRouteDefinition: Hashable, Sendable {
    /// A pack node: the end of an edge of way `osmWayID` whose point index
    /// in the way's normalised node list is `pointIndex`.
    struct Via: Hashable, Sendable {
        var osmWayID: Int64
        var pointIndex: UInt32
    }

    var vias: [Via]
    /// The lap starts (stationary) this far along the route after `vias[0]`,
    /// so it starts and ends on a straight: heading is continuous at the wrap.
    var startOffsetM: Double
    /// The via with the full stop (a junction the route crosses).
    var stopVia: Int

    /// About 5.1 km over primary, secondary and tertiary streets: a long
    /// northbound straight with a junction stop in it, three right turns and
    /// the rest left turns, a short jog through a one-way grid.
    static let standard = DemoRouteDefinition(
        vias: [
            Via(osmWayID: 114_182_806, pointIndex: 5),
            Via(osmWayID: 248_424_679, pointIndex: 8),
            Via(osmWayID: 113_797_296, pointIndex: 6),
            Via(osmWayID: 145_628_937, pointIndex: 5),
            Via(osmWayID: 495_715_796, pointIndex: 4),
            Via(osmWayID: 45_603_011, pointIndex: 8),
            Via(osmWayID: 625_201_827, pointIndex: 2),
            Via(osmWayID: 79_825_808, pointIndex: 0),
            Via(osmWayID: 1_450_214_230, pointIndex: 5),
            Via(osmWayID: 1_376_411_314, pointIndex: 1),
            Via(osmWayID: 1_375_802_036, pointIndex: 2),
            Via(osmWayID: 495_721_372, pointIndex: 1),
        ],
        startOffsetM: 50,
        stopVia: 1
    )
}

/// Shaping and driving parameters of the demo drive. The defaults are what
/// the app uses; tests may vary them.
struct DemoDriveParameters: Hashable, Sendable {
    /// Stationary at the start of every lap (the app calibrates at a
    /// stationary start).
    var startDwellS = 5.0
    /// The full stop at `DemoRouteDefinition.stopVia`.
    var stopDwellS = 10.0
    /// The stop is this far before the junction (a stop line), m.
    var stopLineM = 6.0
    /// Acceleration and deceleration of a speed change, before smoothing
    /// (the smoothed profile never exceeds them).
    var accelerationMps2 = 1.6
    var decelerationMps2 = 1.8
    /// The speed profile's moving-average window, s (`DemoSpeedProfile`).
    var smoothingWindowS = 2.0
    /// Lateral acceleration a turn's speed is limited to, at its tightest.
    var lateralAccelerationMps2 = 2.0
    /// A junction turn is never tighter than this radius (at its apex)
    /// unless the road geometry leaves no room.
    var minimumTurnRadiusM = 7.0
    /// A bend is shaped so its apex stays within this of the road line;
    /// junction turns exceed it when `minimumTurnRadiusM` needs more.
    var maximumCornerCutM = 1.0
    /// Douglas–Peucker tolerance for the road polyline before shaping.
    var simplifyToleranceM = 0.25
    /// Two corners closer than this along the road are merged into one
    /// corner, if that stays within `maximumMergeDeviationM` of the road.
    var clusterLegM = 20.0
    /// The longest turn a gentle bend is shaped into, m.
    var maximumTurnLengthM = 80.0
    var maximumMergeDeviationM = 4.0

    /// Speed limit by road class, m/s.
    func speedLimit(_ roadClass: RoadClass) -> Double {
        switch roadClass {
        case .motorway, .trunk, .primary, .secondary: 50 / 3.6
        case .tertiary: 40 / 3.6
        case .unclassified, .residential: 30 / 3.6
        case .livingStreet, .service, .road: 20 / 3.6
        }
    }

    static let standard = DemoDriveParameters()
}

// MARK: - Routing

/// Cheapest legal paths over one pack: oneway edges only from `from` to
/// `to`, service roads never, minor classes penalised so the route keeps to
/// through streets. Deterministic: ties broken by node index.
enum DemoRouter {
    /// A directed edge traversal.
    struct Step: Hashable, Sendable {
        var edge: Int
        var forward: Bool
    }

    static func weight(_ roadClass: RoadClass) -> Double? {
        switch roadClass {
        case .motorway, .trunk, .primary, .secondary: 1.0
        case .tertiary: 1.05
        case .unclassified: 1.3
        case .residential: 1.5
        case .livingStreet, .road: 3.0
        case .service: nil
        }
    }

    /// The node named by `via`, or nil when no edge of the way ends there.
    static func node(of via: DemoRouteDefinition.Via, in pack: RoadPack) -> Int? {
        for e in pack.edgeRange(ofWay: via.osmWayID) {
            let r = pack.edge(e)
            if r.wayPointOffset == via.pointIndex { return Int(r.from) }
            if r.wayPointOffset + r.pointCount - 1 == via.pointIndex { return Int(r.to) }
        }
        return nil
    }

    /// The cheapest path from node `a` to node `b`; nil when there is none.
    /// Empty when `a == b`.
    static func path(from a: Int, to b: Int, in pack: RoadPack) -> [Step]? {
        if a == b { return [] }
        var cost = [Double](repeating: .infinity, count: pack.nodeCount)
        var previous = [(node: Int, step: Step)?](repeating: nil, count: pack.nodeCount)
        var heap = MinHeap()
        cost[a] = 0
        heap.push(0, a)
        while let (c, u) = heap.pop() {
            if c > cost[u] { continue }
            if u == b { break }
            for e in pack.incidentEdges(u) {
                let r = pack.edge(e)
                guard let w = weight(r.highwayClass) else { continue }
                let length = Double(r.lengthDm) / 10 * w
                var moves: [(Int, Bool)] = []
                if Int(r.from) == u { moves.append((Int(r.to), true)) }
                if Int(r.to) == u, !r.flags.contains(.oneway) { moves.append((Int(r.from), false)) }
                for (v, forward) in moves where c + length < cost[v] {
                    cost[v] = c + length
                    previous[v] = (u, Step(edge: e, forward: forward))
                    heap.push(c + length, v)
                }
            }
        }
        guard cost[b].isFinite else { return nil }
        var steps: [Step] = []
        var v = b
        while v != a, let p = previous[v] {
            steps.append(p.step)
            v = p.node
        }
        return steps.reversed()
    }

    /// A binary min-heap of (cost, node), ordered by cost, then node.
    struct MinHeap {
        private var items: [(Double, Int)] = []

        private static func less(_ x: (Double, Int), _ y: (Double, Int)) -> Bool {
            x.0 < y.0 || (x.0 == y.0 && x.1 < y.1)
        }

        mutating func push(_ cost: Double, _ node: Int) {
            items.append((cost, node))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard Self.less(items[i], items[parent]) else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> (Double, Int)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, Self.less(items[l], items[m]) { m = l }
                    if r < items.count, Self.less(items[r], items[m]) { m = r }
                    if m == i { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }
}

// MARK: - Path geometry

/// The drivable path of the loop in a local east/north plane: straights and
/// smooth turns, arc length from the lap start. A turn's curvature rises
/// and falls as sin² along it (zero at both ends), so heading and yaw rate
/// are continuous everywhere, and the turn is symmetric about the corner's
/// bisector, tangent to both road lines.
struct DemoPath: Sendable {
    /// One piece of the path.
    struct Piece: Hashable, Sendable {
        /// Arc length at the start of the piece.
        var s0: Double
        var length: Double
        /// Start position (east, north), metres in `plane`.
        var east0: Double
        var north0: Double
        /// Heading at the start, radians clockwise from north.
        var heading0: Double
        /// Signed heading change over the piece, + clockwise (right); 0 for
        /// a straight.
        var turn: Double
        /// Speed limit over the piece, m/s.
        var speedLimit: Double
        /// For a turn: the most it cuts the corner (apex to road line), m.
        var cornerCutM: Double

        var isTurn: Bool { turn != 0 }
    }

    let plane: LocalTangentPlane
    let pieces: [Piece]
    let length: Double
    /// Arc length of the full stop.
    let stopS: Double
    /// The road polyline the path was shaped from (lap start first and
    /// last), in pack coordinates.
    let roadShape: [RoadPoint]

    /// Position (east, north), heading (radians clockwise from north,
    /// [0, 2π)) and curvature (1/m, + clockwise) at arc length `s`, clamped
    /// to [0, length].
    func pose(at s: Double) -> (east: Double, north: Double, heading: Double, curvature: Double) {
        let s = min(max(s, 0), length)
        var lo = 0, hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pieces[mid].s0 <= s { lo = mid } else { hi = mid - 1 }
        }
        let p = pieces[lo]
        let u = min(max(s - p.s0, 0), p.length)
        if !p.isTurn {
            return (p.east0 + u * sin(p.heading0), p.north0 + u * cos(p.heading0), Self.wrap2Pi(p.heading0), 0)
        }
        let d = Self.turnOffset(turn: p.turn, length: p.length, heading0: p.heading0, at: u)
        let x = u / p.length
        let heading = p.heading0 + p.turn * (x - sin(2 * .pi * x) / (2 * .pi))
        let curvature = p.turn / p.length * (1 - cos(2 * .pi * x))
        return (p.east0 + d.east, p.north0 + d.north, Self.wrap2Pi(heading), curvature)
    }

    static func wrap2Pi(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 2 * .pi)
        return r < 0 ? r + 2 * .pi : r
    }

    // MARK: Turn shape

    /// Offset (east, north) from a turn's start after arc length `u`:
    /// ∫₀ᵘ (sin ψ, cos ψ) with ψ(v) = heading0 + turn·(v/ℓ − sin(2πv/ℓ)/2π),
    /// 16-point Gauss–Legendre (the integrand is smooth: exact to ~1e-12).
    static func turnOffset(turn: Double, length: Double, heading0: Double, at u: Double) -> (east: Double, north: Double) {
        guard u > 0 else { return (0, 0) }
        let half = u / 2
        var e = 0.0, n = 0.0
        for k in 0..<16 {
            let v = half * (1 + gaussNodes[k])
            let x = v / length
            let psi = heading0 + turn * (x - sin(2 * .pi * x) / (2 * .pi))
            e += gaussWeights[k] * sin(psi)
            n += gaussWeights[k] * cos(psi)
        }
        return (e * half, n * half)
    }

    /// For a unit-length turn of `turn` radians: the tangent length (corner
    /// to either end along the road lines) and the corner cut (apex to the
    /// road lines). Both scale linearly with the turn's length.
    static func unitTurn(_ turn: Double) -> (tangent: Double, cut: Double) {
        let a = abs(turn)
        let end = turnOffset(turn: a, length: 1, heading0: 0, at: 1)
        let chord = (end.east * end.east + end.north * end.north).squareRoot()
        let mid = turnOffset(turn: a, length: 1, heading0: 0, at: 0.5)
        return (chord / (2 * cos(a / 2)), mid.east)
    }

    static let gaussNodes: [Double] = [
        -0.989_400_934_991_649_9, -0.944_575_023_073_232_6, -0.865_631_202_387_831_7, -0.755_404_408_355_003_0,
        -0.617_876_244_402_643_7, -0.458_016_777_657_227_4, -0.281_603_550_779_258_9, -0.095_012_509_837_637_44,
        0.095_012_509_837_637_44, 0.281_603_550_779_258_9, 0.458_016_777_657_227_4, 0.617_876_244_402_643_7,
        0.755_404_408_355_003_0, 0.865_631_202_387_831_7, 0.944_575_023_073_232_6, 0.989_400_934_991_649_9,
    ]
    static let gaussWeights: [Double] = [
        0.027_152_459_411_754_09, 0.062_253_523_938_647_89, 0.095_158_511_682_492_78, 0.124_628_971_255_533_9,
        0.149_595_988_816_576_7, 0.169_156_519_395_002_5, 0.182_603_415_044_923_6, 0.189_450_610_455_068_5,
        0.189_450_610_455_068_5, 0.182_603_415_044_923_6, 0.169_156_519_395_002_5, 0.149_595_988_816_576_7,
        0.124_628_971_255_533_9, 0.095_158_511_682_492_78, 0.062_253_523_938_647_89, 0.027_152_459_411_754_09,
    ]

    // MARK: Building

    /// Route `definition` over `pack` and shape the drivable path.
    init(pack: RoadPack, definition: DemoRouteDefinition, parameters: DemoDriveParameters) throws {
        let vias = definition.vias
        guard vias.count >= 2, definition.stopVia > 0, definition.stopVia < vias.count else {
            throw DemoDriveError.badRoute("need at least two vias and a stop at a via after the first")
        }
        var nodes: [Int] = []
        for (i, via) in vias.enumerated() {
            guard let n = DemoRouter.node(of: via, in: pack) else { throw DemoDriveError.viaNotFound(index: i) }
            nodes.append(n)
        }

        // Road polyline from via 0 round to via 0: points, the class of the
        // segment that starts at each point, and the point index of each via.
        var points: [RoadPoint] = [pack.node(nodes[0])]
        var classes: [RoadClass] = []
        var viaPoint = [0]
        for i in 0..<nodes.count {
            guard let steps = DemoRouter.path(from: nodes[i], to: nodes[(i + 1) % nodes.count], in: pack) else {
                throw DemoDriveError.noPath(fromVia: i)
            }
            for step in steps {
                let r = pack.edge(step.edge)
                let first = Int(r.firstPoint), count = Int(r.pointCount)
                let indices = step.forward ? Array(first..<(first + count)) : Array((first..<(first + count)).reversed())
                for k in indices.dropFirst() {
                    let p = pack.point(k)
                    if p == points[points.count - 1] { continue }
                    classes.append(r.highwayClass)
                    points.append(p)
                }
            }
            if i + 1 < nodes.count { viaPoint.append(points.count - 1) }
        }
        guard points.count >= 4, points.first == points.last else { throw DemoDriveError.badRoute("the vias do not make a loop") }

        let plane = LocalTangentPlane(latitude: points[0].latitude, longitude: points[0].longitude)
        var xy = points.map { p -> (Double, Double) in
            let q = plane.enu(latitude: p.latitude, longitude: p.longitude)
            return (q.east, q.north)
        }

        // Rotate the loop to start `startOffsetM` after via 0, splitting the
        // segment it falls in.
        var walked = 0.0
        var split = -1
        var splitPoint = (0.0, 0.0)
        for j in 0..<(xy.count - 1) {
            let l = Self.distance(xy[j], xy[j + 1])
            if walked + l > definition.startOffsetM {
                let f = (definition.startOffsetM - walked) / l
                split = j
                splitPoint = (xy[j].0 + f * (xy[j + 1].0 - xy[j].0), xy[j].1 + f * (xy[j + 1].1 - xy[j].1))
                break
            }
            walked += l
        }
        guard split >= 0, viaPoint.allSatisfy({ $0 == 0 || $0 > split }) else {
            throw DemoDriveError.badRoute("the start offset passes a via")
        }
        // Loop points 0..<n (xy.last == xy.first): new order starts at the
        // split point, runs j+1 … n-1, 0 … j, and closes at the split point.
        let n = xy.count - 1
        var ring: [(Double, Double)] = [splitPoint]
        var ringClass: [RoadClass] = [classes[split]]
        var ringIsVia: [Bool] = [false]
        var ringIsStop: [Bool] = [false]
        let viaSet = Set(viaPoint.map { $0 % n })
        for k in 1...n {
            let j = (split + k) % n
            ring.append(xy[j])
            ringClass.append(classes[j])
            ringIsVia.append(viaSet.contains(j))
            ringIsStop.append(j == viaPoint[definition.stopVia])
        }
        ring.append(splitPoint)
        ringIsVia.append(false)
        ringIsStop.append(false)
        // ringClass[i] is the class of segment i → i+1.
        xy = []

        // Douglas–Peucker, keeping the vias and both ends.
        var keep = [Bool](repeating: false, count: ring.count)
        // Both ends of the road segment the lap start splits are kept, so the
        // first and last legs lie on one line: no heading change at the wrap.
        keep[0] = true
        keep[1] = true
        keep[ring.count - 2] = true
        keep[ring.count - 1] = true
        for i in ring.indices where ringIsVia[i] { keep[i] = true }
        var anchors = keep.indices.filter { keep[$0] }
        var stack: [(Int, Int)] = []
        for k in 0..<(anchors.count - 1) { stack.append((anchors[k], anchors[k + 1])) }
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = -1.0, at = -1
            for i in (a + 1)..<b {
                let d = Self.pointSegmentDistance(ring[i], ring[a], ring[b])
                if d > worst { worst = d; at = i }
            }
            if worst > parameters.simplifyToleranceM {
                keep[at] = true
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        anchors = keep.indices.filter { keep[$0] }

        // Vertices with the span of ring points they stand for, and the
        // speed limit of each leg: the lowest of the road segments it covers.
        var vertices: [Vertex] = anchors.map { Vertex(p: ring[$0], first: $0, last: $0, isStop: ringIsStop[$0], deviation: 0) }
        var legLimit: [Double] = []
        for k in 0..<(anchors.count - 1) {
            var limit = Double.infinity
            for i in anchors[k]..<anchors[k + 1] { limit = min(limit, parameters.speedLimit(ringClass[i])) }
            legLimit.append(limit)
        }

        // Corner clusters: two corners on a leg shorter than `clusterLegM`
        // (a rounded corner drawn as short kinks, a turn across a dual
        // carriageway) become one corner where the outer legs meet, when that
        // stays within `maximumMergeDeviationM` of the road. Repeated until
        // no pair merges; the lap start and end never move.
        var merging = true
        while merging {
            merging = false
            var k = 1
            while k + 2 < vertices.count {
                let a = vertices[k - 1].p, b = vertices[k].p, c = vertices[k + 1].p, d = vertices[k + 2].p
                defer { k += 1 }
                guard Self.distance(b, c) < parameters.clusterLegM,
                      let x = Self.intersection(a, b, c, d) else { continue }
                let span = vertices[k - 1].last...vertices[k + 2].first
                var deviation = 0.0
                for i in span {
                    deviation = max(deviation, min(Self.pointSegmentDistance(ring[i], a, x), Self.pointSegmentDistance(ring[i], x, d)))
                }
                var toRoad = Double.infinity
                for i in span.lowerBound..<span.upperBound {
                    toRoad = min(toRoad, Self.pointSegmentDistance(x, ring[i], ring[i + 1]))
                }
                deviation = max(deviation, toRoad, vertices[k].deviation, vertices[k + 1].deviation)
                guard deviation <= parameters.maximumMergeDeviationM else { continue }
                vertices[k] = Vertex(p: x, first: vertices[k].first, last: vertices[k + 1].last,
                                     isStop: vertices[k].isStop || vertices[k + 1].isStop, deviation: deviation)
                vertices.remove(at: k + 1)
                legLimit[k + 1] = min(legLimit[k + 1], legLimit[k])
                legLimit.remove(at: k)
                merging = true
            }
        }
        let stopVertex = vertices.firstIndex { $0.isStop } ?? -1
        guard stopVertex > 0 else { throw DemoDriveError.badRoute("the stop via is not on the loop") }

        // Corners: heading change, the turn each needs (no tighter than
        // `minimumTurnRadiusM`) and the turn it wants (also cutting the
        // corner by at most `maximumCornerCutM`). A leg too short for both
        // its corners' wants gives each its need first, then the rest in
        // proportion to the extra they want; too short for the needs, it is
        // split in proportion to them. A leg ending at the lap start (not a
        // corner) is all its corner's.
        let legs = vertices.count - 1
        var legLength: [Double] = []
        var legHeading: [Double] = []
        for k in 0..<legs {
            let a = vertices[k].p, b = vertices[k + 1].p
            legLength.append(Self.distance(a, b))
            legHeading.append(atan2(b.0 - a.0, b.1 - a.1))
        }
        guard legLength.allSatisfy({ $0 > 0 }) else { throw DemoDriveError.badRoute("zero-length leg") }
        // Turn at vertex k (1…legs-1): between leg k-1 and leg k.
        var turnAngle = [Double](repeating: 0, count: vertices.count)
        var unit = [(tangent: Double, cut: Double)](repeating: (0, 0), count: vertices.count)
        var neededTangent = [Double](repeating: 0, count: vertices.count)
        var wantedTangent = [Double](repeating: 0, count: vertices.count)
        for k in 1..<legs {
            let theta = RoadGeometry.wrapPi(legHeading[k] - legHeading[k - 1])
            guard abs(theta) > 1e-9 else { continue }
            guard abs(theta) < 0.9 * .pi else { throw DemoDriveError.badRoute("a corner of more than 162°") }
            turnAngle[k] = theta
            unit[k] = Self.unitTurn(theta)
            let needed = 2 * abs(theta) * parameters.minimumTurnRadiusM
            let wanted = min(max(parameters.maximumCornerCutM / unit[k].cut, needed), parameters.maximumTurnLengthM)
            neededTangent[k] = needed * unit[k].tangent
            wantedTangent[k] = max(wanted, needed) * unit[k].tangent
        }
        func share(ofLeg leg: Int, forVertex v: Int) -> Double {
            let other = v == leg ? leg + 1 : leg
            let length = legLength[leg]
            if other == 0 || other == legs { return length }
            if wantedTangent[v] + wantedTangent[other] <= length { return wantedTangent[v] }
            let needs = neededTangent[v] + neededTangent[other]
            if needs >= length { return length * neededTangent[v] / needs }
            let extra = wantedTangent[v] - neededTangent[v], extraOther = wantedTangent[other] - neededTangent[other]
            return neededTangent[v] + (length - needs) * extra / (extra + extraOther)
        }
        var tangent = [Double](repeating: 0, count: vertices.count)
        var turnLength = [Double](repeating: 0, count: vertices.count)
        var turnCut = [Double](repeating: 0, count: vertices.count)
        for k in 1..<legs where turnAngle[k] != 0 {
            tangent[k] = min(wantedTangent[k], share(ofLeg: k - 1, forVertex: k), share(ofLeg: k, forVertex: k))
            turnLength[k] = tangent[k] / unit[k].tangent
            turnCut[k] = turnLength[k] * unit[k].cut
        }

        // Pieces: straight of leg k (between the turns at its ends), then
        // the turn at vertex k+1.
        var pieces: [Piece] = []
        var s = 0.0
        var stopS = -1.0
        var position = vertices[0].p
        for k in 0..<legs {
            let straight = legLength[k] - tangent[k] - tangent[k + 1]
            guard straight >= -1e-9 else { throw DemoDriveError.badRoute("turns overlap on leg \(k)") }
            if straight > 1e-9 {
                pieces.append(Piece(s0: s, length: straight, east0: position.0, north0: position.1, heading0: legHeading[k],
                                    turn: 0, speedLimit: legLimit[k], cornerCutM: 0))
                position = (position.0 + straight * sin(legHeading[k]), position.1 + straight * cos(legHeading[k]))
                s += straight
            }
            let v = k + 1
            if v == stopVertex {
                // The stop line: `stopLineM` before the junction (the turn's
                // midpoint is the path's nearest point to the corner).
                stopS = s + turnLength[v] / 2 - parameters.stopLineM
            }
            if v < legs, turnLength[v] > 0 {
                let l = turnLength[v]
                let radius = l / (2 * abs(turnAngle[v]))
                let limit = min(legLimit[k], legLimit[v], (parameters.lateralAccelerationMps2 * radius).squareRoot())
                pieces.append(Piece(s0: s, length: l, east0: position.0, north0: position.1, heading0: legHeading[k],
                                    turn: turnAngle[v], speedLimit: limit, cornerCutM: turnCut[v]))
                let d = Self.turnOffset(turn: turnAngle[v], length: l, heading0: legHeading[k], at: l)
                position = (position.0 + d.east, position.1 + d.north)
                s += l
            }
        }
        guard stopS > 0 else { throw DemoDriveError.badRoute("no room for the stop") }
        let closure = Self.distance(position, vertices[0].p)
        guard closure < 1e-3 else { throw DemoDriveError.badRoute("the shaped loop does not close (\(closure) m)") }

        self.plane = plane
        self.pieces = pieces
        self.length = s
        self.stopS = stopS
        roadShape = ring.map { p in
            let g = plane.geodetic(east: p.0, north: p.1)
            return RoadPoint(latE7: Int32((g.latitude * 1e7).rounded()), lonE7: Int32((g.longitude * 1e7).rounded()))
        }
    }

    /// A vertex of the shaped polyline: the ring points `first…last` it
    /// stands for (more than one after a corner merge) and how far that
    /// merge is from the road.
    struct Vertex {
        var p: (Double, Double)
        var first: Int
        var last: Int
        var isStop: Bool
        var deviation: Double
    }

    /// Where line a→b meets line c→d, if ahead of a and before d (so both
    /// outer legs keep their direction); nil for (near-)parallel lines.
    static func intersection(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> (Double, Double)? {
        let r = (b.0 - a.0, b.1 - a.1), q = (d.0 - c.0, d.1 - c.1)
        let denominator = r.0 * q.1 - r.1 * q.0
        let scale = (r.0 * r.0 + r.1 * r.1).squareRoot() * (q.0 * q.0 + q.1 * q.1).squareRoot()
        guard abs(denominator) > 1e-6 * scale else { return nil }
        let w = (c.0 - a.0, c.1 - a.1)
        let alpha = (w.0 * q.1 - w.1 * q.0) / denominator
        let beta = (w.0 * r.1 - w.1 * r.0) / denominator
        guard alpha > 0, beta < 1 else { return nil }
        return (a.0 + alpha * r.0, a.1 + alpha * r.1)
    }

    static func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
    }

    static func pointSegmentDistance(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = RoadGeometry.project(px: p.0, py: p.1, ax: a.0, ay: a.1, bx: b.0, by: b.1)
        return r.distance
    }
}
