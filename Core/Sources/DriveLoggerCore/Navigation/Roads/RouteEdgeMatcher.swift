import Foundation

/// Every threshold of the route-to-roads matcher, in one place
/// (docs/ROUTING_PLAN.md, prompt 51 = R1 item C).
///
/// **The three decided values** (set by the user from the R1 spike: MapKit
/// routes sit within 15 m of pack roads everywhere, 70 % of vertices within
/// 0.5 m, and vertices can be 3.6 km apart on motorways):
/// - `resampleSpacingM` = 10: the route is sampled every 10 m along its
///   polyline, so sparse vertices cannot skip a junction;
/// - `matchDistanceM` = 15: a sample counts as matched when the Viterbi
///   path's road is within 15 m of it;
/// - `weakCoverageBelow` = 0.90: below this share of the route length
///   matched, the result is weak (prompt 53 then uses the route for guidance
///   and display only, not as an edge prior).
///
/// **Tuning** (synthetic tests; not decided by the user):
/// - `candidateRadiusM` 25: roads searched around each sample (more than
///   `matchDistanceM`, so the path can follow a road through a stretch
///   where the route drifts off it, and that stretch then counts as a gap).
///   Clamped to the pack grid's guaranteed `searchRadiusM`.
/// - `maxHeadingDifferenceDegrees` 60: a road is a candidate only in a
///   travel direction within 60° of the route's direction there (measured
///   over ±`headingChordM` = 5 m along the route); a oneway road only
///   forwards. So a cross street is never a candidate, and a oneway against
///   the route never matches.
/// - Emission cost `d²/(2·emissionSigmaM²) + (Δψ/headingSigma)²/2` with
///   σ = 5 m and 30°.
/// - Transition cost `|network distance − route distance| / transitionScaleM`
///   (5 m), the network distance along graph edges (oneway respected), at
///   most `2 · route distance + transitionSlackM` (30 m); a backward step
///   of up to `backtrackToleranceM` (2 m) on the same edge is allowed for
///   noise.
/// - `breakCost` 20: the path may restart anywhere at this cost instead of
///   following a transition; the interval across a restart is unmatched.
public struct RouteMatchThresholds: Hashable, Sendable {
    public var resampleSpacingM: Double
    public var matchDistanceM: Double
    public var weakCoverageBelow: Double
    public var candidateRadiusM: Double
    public var maxHeadingDifferenceDegrees: Double
    public var headingChordM: Double
    public var emissionSigmaM: Double
    public var headingSigmaDegrees: Double
    public var transitionScaleM: Double
    public var transitionSlackM: Double
    public var backtrackToleranceM: Double
    public var breakCost: Double

    public init(
        resampleSpacingM: Double = 10,
        matchDistanceM: Double = 15,
        weakCoverageBelow: Double = 0.90,
        candidateRadiusM: Double = 25,
        maxHeadingDifferenceDegrees: Double = 60,
        headingChordM: Double = 5,
        emissionSigmaM: Double = 5,
        headingSigmaDegrees: Double = 30,
        transitionScaleM: Double = 5,
        transitionSlackM: Double = 30,
        backtrackToleranceM: Double = 2,
        breakCost: Double = 20
    ) {
        self.resampleSpacingM = resampleSpacingM
        self.matchDistanceM = matchDistanceM
        self.weakCoverageBelow = weakCoverageBelow
        self.candidateRadiusM = candidateRadiusM
        self.maxHeadingDifferenceDegrees = maxHeadingDifferenceDegrees
        self.headingChordM = headingChordM
        self.emissionSigmaM = emissionSigmaM
        self.headingSigmaDegrees = headingSigmaDegrees
        self.transitionScaleM = transitionScaleM
        self.transitionSlackM = transitionSlackM
        self.backtrackToleranceM = backtrackToleranceM
        self.breakCost = breakCost
    }

    public static let standard = RouteMatchThresholds()
}

/// A route matched onto the pack graph.
public struct RouteEdgeMatch: Hashable, Sendable {
    /// The edges the route follows, in route order. Only matched stretches:
    /// an unmatched stretch is a gap. An edge crossed between two samples
    /// (a short junction connector) is included with no samples.
    public var edges: [RouteMatchedEdge]
    /// Unmatched stretches of the route, in order.
    public var gaps: [RouteMatchGap]
    /// Geometric route length (`RoutePolyline.lengthM`).
    public var routeLengthM: Double
    public var matchedLengthM: Double
    /// `matchedLengthM / routeLengthM` (0 for a route of no length).
    public var coverage: Double
    /// Coverage below `RouteMatchThresholds.weakCoverageBelow`.
    public var isWeak: Bool
    public var sampleCount: Int
    public var thresholds: RouteMatchThresholds
}

/// One stretch of the route on one pack edge.
///
/// Keyed for a pack rebuild by `osmWayID` + `wayPointOffset` (the edge's
/// first point in the way's normalised node list) and, finer,
/// `segmentIndices`: the way's segment indices touched, i.e. the
/// cross-pack segment keys (`RoadSegmentKey`) `(osmWayID, i)`. `edge` is the
/// network-local reference, valid only for the network that matched.
public struct RouteMatchedEdge: Hashable, Sendable {
    public var osmWayID: Int64
    public var wayPointOffset: UInt32
    public var pointCount: UInt32
    /// Travelled in the edge's point order (the way's order; driving order
    /// for a oneway).
    public var forward: Bool
    /// Along-edge range covered, metres from the edge's first point: where
    /// the route enters (`edgeFromM`) and leaves (`edgeToM`). Forward:
    /// `edgeFromM ≤ edgeToM`.
    public var edgeFromM: Double
    public var edgeToM: Double
    public var segmentIndices: ClosedRange<UInt32>
    /// Route range on this edge, metres along the route polyline.
    public var routeFromM: Double
    public var routeToM: Double
    /// Route samples matched on this stretch, and their distance to the edge
    /// (nil with no samples).
    public var sampleCount: Int
    public var meanDistanceM: Double?
    public var maxDistanceM: Double?
    public var highwayClass: RoadClass
    public var flags: RoadEdgeFlags
    public var level: Int8
    public var edge: RoadNetwork.EdgeRef
}

/// An unmatched stretch of the route, metres along its polyline.
public struct RouteMatchGap: Hashable, Sendable {
    public var startM: Double
    public var endM: Double
    public var lengthM: Double { endM - startM }

    public init(startM: Double, endM: Double) {
        self.startM = startM
        self.endM = endM
    }
}

/// Maps a route polyline onto the pack graph: Viterbi over candidate road
/// positions at samples every `resampleSpacingM`, with transitions along
/// the graph (prompt 51 item C).
///
/// - **Candidates** come from the network's de-duplicated cell lists, so a
///   segment shadowed by an earlier pack is never one (docs/ROAD_PACK.md,
///   "Duplicates across packs"). A candidate is an (edge, travel direction,
///   position) within `candidateRadiusM` whose direction is within
///   `maxHeadingDifferenceDegrees` of the route's; a oneway only forwards.
/// - **Transitions** follow the graph: along an edge, and from edge to edge
///   at a shared node — in a pack, the edges incident to a node; across
///   packs, points with equal coordinates where one of the two is an edge
///   end (`RoadNetwork.adjacentEdges`'s rule), so a road of one pack can
///   leave a border way at a point that is only a shape point in the other.
///   Oneway edges are entered forwards only. Shadowed copies may be crossed
///   (their geometry is the same).
/// - **Level** needs no separate rule: a bridge and the road under it share
///   no node, so no transition links them and the path cannot jump between
///   levels; it can only restart (`breakCost`), which leaves a gap.
///
/// Deterministic: candidates and connections are sorted, dictionaries are
/// only looked up, ties go to the lower index. Data: © OpenStreetMap
/// contributors, ODbL 1.0.
public struct RouteEdgeMatcher: Sendable {
    public let network: RoadNetwork
    public let thresholds: RouteMatchThresholds

    public init(network: RoadNetwork, thresholds: RouteMatchThresholds = .standard) {
        self.network = network
        self.thresholds = thresholds
    }

    public func match(_ route: Route) -> RouteEdgeMatch {
        match(RoutePolyline(route: route))
    }

    public func match(_ polyline: RoutePolyline) -> RouteEdgeMatch {
        let work = MatchWork(network: network, thresholds: thresholds)
        return work.run(polyline)
    }

    /// Road context at each step's maneuver (`RouteManeuver.computed`'s
    /// `roadContexts`), from a match of the same route. The incoming and
    /// outgoing edges are the two sides of the matched edge boundary nearest
    /// the maneuver (within `resampleSpacingM`), or the matched edge through
    /// it when there is no boundary that close. They give the link flags
    /// (merge, exit ramp) and the roundabout flag; for a roundabout, the
    /// exit number when the whole passage through it is matched. Nil where
    /// the route is unmatched at the maneuver. Exits are counted within one
    /// pack: a ring node counts when an edge other than the ring leaves it
    /// in a drivable direction.
    public func roadContexts(for route: Route, match: RouteEdgeMatch) -> [RouteManeuverRoadContext?] {
        let geometry = RouteGeometry(route: route)
        let edges = match.edges
        return route.steps.indices.map { index in
            let s = geometry.maneuverDistanceAlongM[index]
            var boundary: Int?
            var nearest = thresholds.resampleSpacingM
            for i in edges.indices.dropLast() where Self.contiguous(edges, i, i + 1) {
                let d = abs(edges[i].routeToM - s)
                if d <= nearest, boundary.map({ d < abs(edges[$0].routeToM - s) }) ?? true {
                    boundary = i
                    nearest = d
                }
            }
            let incoming: Int, outgoing: Int
            if let boundary {
                incoming = boundary
                outgoing = boundary + 1
            } else if let through = edges.firstIndex(where: { $0.routeFromM <= s && $0.routeToM >= s }) {
                incoming = through
                outgoing = through
            } else {
                return nil
            }
            let a = edges[incoming], b = edges[outgoing]
            var context = RouteManeuverRoadContext(
                incomingIsLink: a.flags.contains(.link), outgoingIsLink: b.flags.contains(.link)
            )
            if b.flags.contains(.roundabout) || a.flags.contains(.roundabout) {
                context.roundabout = true
                context.roundaboutExit = roundaboutExit(edges, around: b.flags.contains(.roundabout) ? outgoing : incoming)
            }
            return context
        }
    }

    static func contiguous(_ edges: [RouteMatchedEdge], _ i: Int, _ j: Int) -> Bool {
        abs(edges[i].routeToM - edges[j].routeFromM) < 1e-6
    }

    /// The exit number of the roundabout passage containing `edges[index]`:
    /// the ring nodes passed with a drivable exit, up to and including the
    /// node where the route leaves. Nil unless the passage is matched from
    /// the edge before it to the edge after it, contiguously, in one pack.
    func roundaboutExit(_ edges: [RouteMatchedEdge], around index: Int) -> Int? {
        func contiguous(_ i: Int, _ j: Int) -> Bool { Self.contiguous(edges, i, j) }
        var first = index, last = index
        while first > 0, edges[first - 1].flags.contains(.roundabout), contiguous(first - 1, first) { first -= 1 }
        while last + 1 < edges.count, edges[last + 1].flags.contains(.roundabout), contiguous(last, last + 1) { last += 1 }
        guard first > 0, last + 1 < edges.count, contiguous(first - 1, first), contiguous(last, last + 1) else { return nil }
        let pack = edges[first].edge.pack
        guard (first - 1...last + 1).allSatisfy({ edges[$0].edge.pack == pack }) else { return nil }
        let p = network.packs[pack]
        var exits = 0
        for i in first...last {
            let record = p.edge(edges[i].edge.edge)
            let node = Int(edges[i].forward ? record.to : record.from)
            let next = edges[i + 1].edge.edge
            if i == last {
                exits += 1
                break
            }
            let hasExit = p.incidentEdges(node).contains { f in
                guard f != edges[i].edge.edge, f != next else { return false }
                let r = p.edge(f)
                if r.flags.contains(.roundabout) { return false }
                return !r.isOneway || Int(r.from) == node
            }
            if hasExit { exits += 1 }
        }
        return exits
    }
}

// MARK: - Work

/// One match: caches (edge geometry, connections) and the Viterbi. Not
/// shared; dictionaries are lookup-only.
private final class MatchWork {
    typealias EdgeRef = RoadNetwork.EdgeRef

    let network: RoadNetwork
    let t: RouteMatchThresholds
    let candidateRadius: Double

    init(network: RoadNetwork, thresholds: RouteMatchThresholds) {
        self.network = network
        t = thresholds
        candidateRadius = min(thresholds.candidateRadiusM, network.grid.searchRadiusM)
    }

    // MARK: Edge geometry

    struct EdgeGeometry {
        let record: RoadEdgeRecord
        let points: [RoadPoint]
        /// Metres from the first point, per point.
        let cumulative: [Double]
        var last: Int { points.count - 1 }
        var length: Double { cumulative[cumulative.count - 1] }
    }

    private var geometryCache: [EdgeRef: EdgeGeometry] = [:]

    func geometry(_ e: EdgeRef) -> EdgeGeometry {
        if let g = geometryCache[e] { return g }
        let pack = network.packs[e.pack]
        let record = pack.edge(e.edge)
        let points = (0..<Int(record.pointCount)).map { pack.point(Int(record.firstPoint) + $0) }
        var cumulative = [0.0]
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + RoadGeometry.distanceM(from: points[i - 1], to: points[i]))
        }
        let g = EdgeGeometry(record: record, points: points, cumulative: cumulative)
        geometryCache[e] = g
        return g
    }

    // MARK: Connections

    struct Connection: Comparable {
        let atPoint: Int
        let to: EdgeRef
        let toPoint: Int

        static func < (a: Connection, b: Connection) -> Bool {
            (a.atPoint, a.to, a.toPoint) < (b.atPoint, b.to, b.toPoint)
        }
    }

    private var connectionCache: [EdgeRef: [Connection]] = [:]

    /// Where a car on edge `e` can move onto another edge (or onto `e`
    /// again at another point, for a loop), sorted.
    func connections(_ e: EdgeRef) -> [Connection] {
        if let c = connectionCache[e] { return c }
        let pack = network.packs[e.pack]
        let g = geometry(e)
        var out: [Connection] = []
        for (i, node) in [(0, Int(g.record.from)), (g.last, Int(g.record.to))] {
            for f in pack.incidentEdges(node) {
                let r = pack.edge(f)
                let fLast = Int(r.pointCount) - 1
                for (j, n) in [(0, Int(r.from)), (fLast, Int(r.to))] where n == node {
                    if f == e.edge && j == i { continue }
                    out.append(Connection(atPoint: i, to: EdgeRef(pack: e.pack, edge: f), toPoint: j))
                }
            }
        }
        if network.packs.count > 1 {
            var index: [UInt64: [Int]] = [:]
            for (i, p) in g.points.enumerated() { index[Self.key(p), default: []].append(i) }
            for f in network.adjacentEdges(of: e) where f.pack != e.pack {
                let fg = geometry(f)
                for (j, p) in fg.points.enumerated() {
                    guard let mine = index[Self.key(p)] else { continue }
                    for i in mine where i == 0 || i == g.last || j == 0 || j == fg.last {
                        out.append(Connection(atPoint: i, to: f, toPoint: j))
                    }
                }
            }
        }
        out.sort()
        var unique: [Connection] = []
        for c in out where unique.last != c { unique.append(c) }
        connectionCache[e] = unique
        return unique
    }

    static func key(_ p: RoadPoint) -> UInt64 {
        UInt64(UInt32(bitPattern: p.latE7)) << 32 | UInt64(UInt32(bitPattern: p.lonE7))
    }

    // MARK: Candidates

    struct Candidate {
        let edge: EdgeRef
        let forward: Bool
        /// Metres from the edge's first point.
        let offset: Double
        let distance: Double
        let emission: Double
    }

    struct Sample {
        let along: Double
        let latitude: Double
        let longitude: Double
        /// Route bearing, radians clockwise from north.
        let bearing: Double
    }

    private var lastCellKey: UInt64?
    private var lastCellSegments: [RoadNetwork.SegmentRef] = []

    func candidates(_ s: Sample) -> [Candidate] {
        let cell = network.grid.cell(latitude: s.latitude, longitude: s.longitude)
        let cellKey = RoadGrid.key(cx: cell.cx, cy: cell.cy)
        if cellKey != lastCellKey {
            var segments: [RoadNetwork.SegmentRef] = []
            network.forEachSegment(inCellX: cell.cx, y: cell.cy) { segments.append($0) }
            lastCellSegments = segments
            lastCellKey = cellKey
        }
        let k = RoadGrid.trueMetresPerE7(latitude: s.latitude)
        let qLat = s.latitude * 1e7, qLon = s.longitude * 1e7
        let maxDiff = t.maxHeadingDifferenceDegrees * .pi / 180
        let sigma2 = 2 * t.emissionSigmaM * t.emissionSigmaM
        let headingSigma = t.headingSigmaDegrees * .pi / 180
        var best: [Candidate] = []
        for ref in lastCellSegments {
            let segment = network.segment(ref)
            let ax = (Double(segment.a.lonE7) - qLon) * k.lon, ay = (Double(segment.a.latE7) - qLat) * k.lat
            let bx = (Double(segment.b.lonE7) - qLon) * k.lon, by = (Double(segment.b.latE7) - qLat) * k.lat
            let projection = RoadGeometry.project(px: 0, py: 0, ax: ax, ay: ay, bx: bx, by: by)
            let distance = projection.distance
            guard distance <= candidateRadius else { continue }
            let e = EdgeRef(pack: ref.pack, edge: segment.edgeIndex)
            let g = geometry(e)
            let i = segment.startPoint - Int(g.record.firstPoint)
            let offset = g.cumulative[i] + projection.t * (g.cumulative[i + 1] - g.cumulative[i])
            let beta = RoadGeometry.bearing(east: bx - ax, north: by - ay)
            for forward in [true, false] {
                if !forward && g.record.isOneway { continue }
                let diff = abs(RoadGeometry.wrapPi(s.bearing - beta - (forward ? 0 : .pi)))
                guard diff <= maxDiff else { continue }
                let emission = distance * distance / sigma2 + (diff / headingSigma) * (diff / headingSigma) / 2
                let c = Candidate(edge: e, forward: forward, offset: offset, distance: distance, emission: emission)
                if let existing = best.firstIndex(where: { $0.edge == e && $0.forward == forward }) {
                    if emission < best[existing].emission { best[existing] = c }
                } else {
                    best.append(c)
                }
            }
        }
        best.sort { ($0.edge, $0.forward ? 0 : 1) < ($1.edge, $1.forward ? 0 : 1) }
        return best
    }

    // MARK: Graph search

    struct Piece {
        let edge: EdgeRef
        let forward: Bool
        let from: Double
        let to: Double
        var length: Double { abs(to - from) }
    }

    private struct VisitKey: Hashable {
        let edge: EdgeRef
        let forward: Bool
        let entry: Int
    }

    private struct Node {
        let edge: EdgeRef
        let forward: Bool
        let entryPoint: Int  // -1 for the start
        let entryOffset: Double
        let g: Double
        let parent: Int
        let parentExit: Double
    }

    /// Network distance from `start` to each target (nil when not reachable
    /// within `limit`), and the pieces of the path to `pathTarget`.
    func search(from start: Candidate, to targets: [Candidate], limit: Double, pathTarget: Int? = nil)
        -> (distances: [Double?], path: [Piece])
    {
        var nodes = [Node(edge: start.edge, forward: start.forward, entryPoint: -1, entryOffset: start.offset,
                          g: 0, parent: -1, parentExit: 0)]
        var open = [0]
        var visited: [VisitKey: Double] = [:]
        var best = [Double?](repeating: nil, count: targets.count)
        var bestNode = [Int](repeating: -1, count: targets.count)
        while !open.isEmpty {
            var pick = 0
            for k in 1..<open.count where nodes[open[k]].g < nodes[open[pick]].g { pick = k }
            let index = open.remove(at: pick)
            let node = nodes[index]
            if node.g > limit { break }
            if best.allSatisfy({ $0 != nil && $0! <= node.g }) { break }
            let isStart = node.entryPoint < 0
            for (k, target) in targets.enumerated() where target.edge == node.edge && target.forward == node.forward {
                let ahead = node.forward ? target.offset - node.entryOffset : node.entryOffset - target.offset
                guard ahead >= (isStart ? -t.backtrackToleranceM : -1e-9) else { continue }
                let d = node.g + ahead
                if d <= limit, best[k].map({ d < $0 }) ?? true {
                    best[k] = d
                    bestNode[k] = index
                }
            }
            let g = geometry(node.edge)
            for c in connections(node.edge) {
                if !isStart && c.atPoint == node.entryPoint { continue }
                let at = g.cumulative[c.atPoint]
                let ahead = node.forward ? at - node.entryOffset : node.entryOffset - at
                guard ahead >= -1e-9 else { continue }
                let g2 = node.g + max(ahead, 0)
                guard g2 <= limit else { continue }
                let fg = geometry(c.to)
                for forward in [true, false] {
                    if forward ? c.toPoint >= fg.last : (c.toPoint <= 0 || fg.record.isOneway) { continue }
                    let key = VisitKey(edge: c.to, forward: forward, entry: c.toPoint)
                    if let seen = visited[key], seen <= g2 { continue }
                    visited[key] = g2
                    nodes.append(Node(edge: c.to, forward: forward, entryPoint: c.toPoint,
                                      entryOffset: fg.cumulative[c.toPoint], g: g2, parent: index, parentExit: at))
                    open.append(nodes.count - 1)
                }
            }
        }
        var path: [Piece] = []
        if let p = pathTarget, bestNode[p] >= 0 {
            var index = bestNode[p]
            var exit = targets[p].offset
            while index >= 0 {
                let node = nodes[index]
                path.append(Piece(edge: node.edge, forward: node.forward, from: node.entryOffset, to: exit))
                exit = node.parentExit
                index = node.parent
            }
            path.reverse()
        }
        return (best, path)
    }

    // MARK: Viterbi

    func run(_ polyline: RoutePolyline) -> RouteEdgeMatch {
        let length = polyline.lengthM
        let spacing = max(t.resampleSpacingM, 0.1)
        let count = max(Int((length / spacing).rounded(.up)), 1) + 1
        let samples: [Sample] = (0..<count).map { k in
            let u = min(Double(k) * spacing, length)
            let p = polyline.position(atDistanceAlongM: u)
            let a = polyline.position(atDistanceAlongM: u - t.headingChordM)
            let b = polyline.position(atDistanceAlongM: u + t.headingChordM)
            let kk = RoadGrid.trueMetresPerE7(latitude: p.latitude)
            let bearing = RoadGeometry.bearing(
                east: RoutePolyline.lonDeltaE7((b.longitude - a.longitude) * 1e7) * kk.lon,
                north: (b.latitude - a.latitude) * 1e7 * kk.lat
            )
            return Sample(along: u, latitude: p.latitude, longitude: p.longitude, bearing: bearing)
        }
        let layers = samples.map(candidates)
        var cost: [[Double]] = layers.map { [Double](repeating: .infinity, count: $0.count) }
        var back: [[Int]] = layers.map { [Int](repeating: -1, count: $0.count) }
        var connected: [[Bool]] = layers.map { [Bool](repeating: false, count: $0.count) }
        var previousLayer = [Int](repeating: -1, count: count)
        var lastNonEmpty = -1
        for k in 0..<count {
            previousLayer[k] = lastNonEmpty
            guard !layers[k].isEmpty else { continue }
            defer { lastNonEmpty = k }
            let p = lastNonEmpty
            guard p >= 0 else {
                cost[k] = layers[k].map(\.emission)
                continue
            }
            var bestPrevious = 0
            for i in cost[p].indices where cost[p][i] < cost[p][bestPrevious] { bestPrevious = i }
            for j in layers[k].indices {
                cost[k][j] = cost[p][bestPrevious] + t.breakCost + layers[k][j].emission
                back[k][j] = bestPrevious
            }
            guard p == k - 1 else { continue }
            let du = samples[k].along - samples[p].along
            let limit = 2 * du + t.transitionSlackM
            for i in layers[p].indices where cost[p][i].isFinite {
                let reach = search(from: layers[p][i], to: layers[k], limit: limit).distances
                for j in layers[k].indices {
                    guard let d = reach[j] else { continue }
                    let c = cost[p][i] + abs(d - du) / t.transitionScaleM + layers[k][j].emission
                    if c < cost[k][j] {
                        cost[k][j] = c
                        back[k][j] = i
                        connected[k][j] = true
                    }
                }
            }
        }
        // Backtrack.
        var chosen = [Int](repeating: -1, count: count)
        var linked = [Bool](repeating: false, count: count)
        if lastNonEmpty >= 0 {
            var k = lastNonEmpty
            var j = 0
            for x in cost[k].indices where cost[k][x] < cost[k][j] { j = x }
            while k >= 0 {
                chosen[k] = j
                linked[k] = connected[k][j]
                let p = previousLayer[k]
                if p < 0 { break }
                j = back[k][j]
                k = p
            }
        }
        return assemble(polyline: polyline, samples: samples, layers: layers, chosen: chosen, linked: linked)
    }

    // MARK: Output

    private struct Run {
        var edge: EdgeRef
        var forward: Bool
        var from: Double
        var to: Double
        var routeFrom: Double
        var routeTo: Double
        var distances: [Double]
        var interval: Int
    }

    func assemble(
        polyline: RoutePolyline, samples: [Sample], layers: [[Candidate]], chosen: [Int], linked: [Bool]
    ) -> RouteEdgeMatch {
        let count = samples.count
        func matched(_ k: Int) -> Bool { chosen[k] >= 0 && layers[k][chosen[k]].distance <= t.matchDistanceM }
        var runs: [Run] = []
        var gaps: [RouteMatchGap] = []
        var matchedLength = 0.0
        var attached = [Bool](repeating: false, count: count)
        for k in 1..<max(count, 1) {
            let a = samples[k - 1].along, b = samples[k].along
            guard matched(k - 1), matched(k), linked[k] else {
                if b > a {
                    if let lastGap = gaps.last, lastGap.endM == a {
                        gaps[gaps.count - 1].endM = b
                    } else {
                        gaps.append(RouteMatchGap(startM: a, endM: b))
                    }
                }
                continue
            }
            matchedLength += b - a
            let from = layers[k - 1][chosen[k - 1]], to = layers[k][chosen[k]]
            let du = b - a
            let pieces = search(from: from, to: [to], limit: 2 * du + t.transitionSlackM, pathTarget: 0).path
            let total = pieces.reduce(0) { $0 + $1.length }
            var position = a
            for (n, piece) in pieces.enumerated() {
                let share = total > 0 ? piece.length / total : 1 / Double(pieces.count)
                let end = n == pieces.count - 1 ? b : position + share * du
                if let last = runs.last, last.edge == piece.edge, last.forward == piece.forward,
                   last.interval >= k - 1, last.routeTo == position {
                    runs[runs.count - 1].to = piece.forward ? max(last.to, piece.to) : min(last.to, piece.to)
                    runs[runs.count - 1].routeTo = end
                    runs[runs.count - 1].interval = k
                } else {
                    runs.append(Run(edge: piece.edge, forward: piece.forward, from: piece.from, to: piece.to,
                                    routeFrom: position, routeTo: end, distances: [], interval: k))
                }
                if n == 0, !attached[k - 1] {
                    runs[runs.count - 1].distances.append(from.distance)
                    attached[k - 1] = true
                }
                if n == pieces.count - 1, !attached[k] {
                    runs[runs.count - 1].distances.append(to.distance)
                    attached[k] = true
                }
                position = end
            }
        }
        let edges = runs.map { run -> RouteMatchedEdge in
            let g = geometry(run.edge)
            func segmentIndex(_ offset: Double) -> UInt32 {
                var i = 0
                while i + 1 < g.last, g.cumulative[i + 1] <= offset { i += 1 }
                return g.record.wayPointOffset + UInt32(i)
            }
            let s0 = segmentIndex(run.from), s1 = segmentIndex(run.to)
            let n = run.distances.count
            return RouteMatchedEdge(
                osmWayID: g.record.osmWayID, wayPointOffset: g.record.wayPointOffset, pointCount: g.record.pointCount,
                forward: run.forward, edgeFromM: run.from, edgeToM: run.to,
                segmentIndices: min(s0, s1)...max(s0, s1),
                routeFromM: run.routeFrom, routeToM: run.routeTo,
                sampleCount: n,
                meanDistanceM: n > 0 ? run.distances.reduce(0, +) / Double(n) : nil,
                maxDistanceM: run.distances.max(),
                highwayClass: g.record.highwayClass, flags: g.record.flags, level: g.record.level, edge: run.edge
            )
        }
        let length = polyline.lengthM
        let coverage = length > 0 ? min(matchedLength / length, 1) : 0
        return RouteEdgeMatch(
            edges: edges, gaps: gaps, routeLengthM: length, matchedLengthM: matchedLength, coverage: coverage,
            isWeak: coverage < t.weakCoverageBelow, sampleCount: count, thresholds: t
        )
    }
}
