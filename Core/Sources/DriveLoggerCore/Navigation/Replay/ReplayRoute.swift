import Foundation

// Routes in replay_nav (docs/ROUTING_PLAN.md, prompt 51 = R1 item E). The
// engine ignores the route: replay_nav loads it, matches it onto the given
// packs (`RouteEdgeMatcher`) and reports how far the estimate track ran
// from it. Offline analysis only; nothing here reaches the engine.

/// A route's polyline for the GeoJSON: (longitude, latitude) pairs.
public struct ReplayRoutePolyline: Hashable, Sendable, Codable {
    public var id: String
    public var coordinates: [[Double]]

    public init(_ route: Route) {
        id = route.id
        coordinates = route.polyline.map { [$0.longitude, $0.latitude] }
    }
}

/// A closed interval of session seconds.
public struct ReplayTimeWindow: Hashable, Sendable, Codable {
    public var fromT: Double
    public var toT: Double

    public init(fromT: Double, toT: Double) {
        self.fromT = fromT
        self.toT = toT
    }

    public func contains(_ t: Double) -> Bool { t >= fromT && t <= toT }
    public var durationS: Double { toT - fromT }
}

// MARK: - Reference route from clean GNSS

/// Which fixes make a reference route (the R1 drive survey's definition,
/// prompt 51 E): horizontal accuracy in (0, `maxAccuracyM`], a valid speed
/// (`LocationSample.hasValidSpeed`: speed and its accuracy ≥ 0), and a valid
/// course (`hasValidCourse`) when moving at `movingSpeedMps` or more; not
/// simulated. Consecutive clean fixes at most `joinGapS` apart form one
/// span; a span needs `minSpanFixes` fixes.
public struct ReferenceRouteRule: Hashable, Sendable {
    public var maxAccuracyM: Double
    public var movingSpeedMps: Double
    public var joinGapS: Double
    public var minSpanFixes: Int

    public init(maxAccuracyM: Double = 20, movingSpeedMps: Double = 2, joinGapS: Double = 5, minSpanFixes: Int = 2) {
        self.maxAccuracyM = maxAccuracyM
        self.movingSpeedMps = movingSpeedMps
        self.joinGapS = joinGapS
        self.minSpanFixes = minSpanFixes
    }

    public static let standard = ReferenceRouteRule()

    public func isClean(_ s: LocationSample) -> Bool {
        guard s.simulated != true, s.latitude.isFinite, s.longitude.isFinite else { return false }
        guard s.horizontalAccuracy > 0, s.horizontalAccuracy <= maxAccuracyM else { return false }
        guard s.speed.isFinite, s.hasValidSpeed else { return false }
        if s.speed >= movingSpeedMps { return s.course.isFinite && s.hasValidCourse }
        return true
    }
}

/// A reference route built from a recording's clean GNSS fixes: one
/// polyline through every span's fixes in time order (a straight chord
/// joins consecutive spans; it is not part of any span), with each span's
/// time window and along-route range.
public struct ReferenceRoute: Hashable, Sendable {
    public struct Span: Hashable, Sendable {
        public var window: ReplayTimeWindow
        /// Polyline vertex range of this span's fixes.
        public var vertices: ClosedRange<Int>
        /// Metres along the polyline covered by the span.
        public var alongM: ClosedRange<Double>
        public var fixes: Int
    }

    public var route: Route
    public var spans: [Span]
    /// Location rows read, and the clean ones that went into spans.
    public var fixesSeen: Int
    public var fixesUsed: Int
    /// Clean fixes left out by the truth file's `excludeFixes`.
    public var fixesExcludedByTruth: Int

    public var windows: [ReplayTimeWindow] { spans.map(\.window) }

    /// The spans' along ranges for `RoutePolyline.project(alongRangeM:)`,
    /// each narrowed by one ulp at both ends so the chord segments that
    /// only touch a span are not searched.
    public var projectionRanges: [ClosedRange<Double>] {
        spans.map { s in
            s.alongM.upperBound > s.alongM.lowerBound ? s.alongM.lowerBound.nextUp...s.alongM.upperBound.nextDown : s.alongM
        }
    }
}

public enum ReferenceRouteBuilder {
    /// The reference route of a recording, from every location input
    /// (whatever the GPS mode withholds from the engine), or nil with no
    /// span. Fixes in `excluded` (truth `excludeFixes`, by fix time) are
    /// never used. Fix time is the sample's `t`; duplicates of the previous
    /// point are kept as zero-length segments.
    public static func build(
        inputs: [NavigationInput], id: String = "reference", excluded: [TruthFile.ExcludedFixRange] = [],
        rule: ReferenceRouteRule = .standard
    ) -> ReferenceRoute? {
        var seen = 0, excludedCount = 0
        var clean: [(t: Double, point: RoutePoint)] = []
        for input in inputs {
            guard case .location(let sample, let at) = input else { continue }
            seen += 1
            guard rule.isClean(sample), let point = RoutePoint(latitude: sample.latitude, longitude: sample.longitude)
            else { continue }
            let t = at.seconds
            if excluded.contains(where: { t >= $0.fromT && t <= $0.toT }) {
                excludedCount += 1
                continue
            }
            clean.append((t, point))
        }
        // Time order; ties keep input order.
        clean = clean.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        var groups: [[(t: Double, point: RoutePoint)]] = []
        for fix in clean {
            if let last = groups.last?.last, fix.t - last.t <= rule.joinGapS {
                groups[groups.count - 1].append(fix)
            } else {
                groups.append([fix])
            }
        }
        groups = groups.filter { $0.count >= max(rule.minSpanFixes, 2) }
        guard !groups.isEmpty else { return nil }
        var points: [RoutePoint] = []
        var ranges: [ClosedRange<Int>] = []
        for group in groups {
            let first = points.count
            points.append(contentsOf: group.map(\.point))
            ranges.append(first...(points.count - 1))
        }
        guard let polyline = try? RoutePolyline(points) else { return nil }
        let cumulative = polyline.cumulativeDistanceM
        let spans = zip(groups, ranges).map { group, range in
            ReferenceRoute.Span(
                window: ReplayTimeWindow(fromT: group.first!.t, toT: group.last!.t), vertices: range,
                alongM: cumulative[range.lowerBound]...cumulative[range.upperBound], fixes: group.count
            )
        }
        let last = points.count - 1
        guard let route = try? Route(
            id: id, polyline: points,
            steps: [
                RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart),
                RouteStep(instruction: "", distanceM: polyline.lengthM, polylineRange: 0...last, maneuver: .arrive),
            ],
            distanceM: polyline.lengthM, expectedTravelTimeS: max(spans.last!.window.toT - spans[0].window.fromT, 0),
            source: .synthetic
        ) else { return nil }
        return ReferenceRoute(route: route, spans: spans, fixesSeen: seen, fixesUsed: groups.reduce(0) { $0 + $1.count },
                              fixesExcludedByTruth: excludedCount)
    }
}

// MARK: - Routes recorded in a v7 log

public enum ReplayRecordedRoutes {
    /// The recording's `route` rows with the time each was active: from its
    /// row to the next `route` or `routeCleared` row, or to `endT`.
    public static func routes<S: Sequence>(in events: S, endT: Double) -> [(route: Route, window: ReplayTimeWindow)]
        where S.Element == LogEvent
    {
        var out: [(route: Route, window: ReplayTimeWindow)] = []
        var open: (route: Route, fromT: Double)?
        for event in events {
            let t = event.timestamp.seconds
            switch event.payload {
            case .route(let sample):
                if let o = open { out.append((o.route, ReplayTimeWindow(fromT: o.fromT, toT: t))) }
                open = (sample.route, t)
            case .routeCleared:
                if let o = open { out.append((o.route, ReplayTimeWindow(fromT: o.fromT, toT: t))) }
                open = nil
            default:
                continue
            }
        }
        if let o = open { out.append((o.route, ReplayTimeWindow(fromT: o.fromT, toT: max(endT, o.fromT)))) }
        return out
    }
}

// MARK: - Deliberately wrong routes

/// `replay_nav --route-perturb` (prompt 53's robustness runs). Both modes
/// need the base route matched onto the packs, and are deterministic: the
/// candidate places are listed in route order and the `seed`-th one (seed
/// modulo their count) is taken.
public enum RoutePerturbation: String, Hashable, Sendable, Codable, CaseIterable {
    /// The route goes straight where the drive turned. Candidates: matched
    /// edge boundaries at a pack node where the route turns by at least
    /// `minTurnDegrees` and a drivable edge leaves the node within
    /// `straightDegrees` of the incoming direction. The perturbed route is
    /// the base up to that node, then straight on for `missedTurnLengthM`
    /// (at each later node the drivable edge nearest straight on, within
    /// `straightDegrees`), and ends there.
    case missedTurn = "missed-turn"
    /// A neighbouring street. Candidates: matched edges the route follows
    /// for at least `parallelMinLengthM`; for each, the nearest other road
    /// segment 25–150 m to the side of the stretch's midpoint, within 20°
    /// of its direction (a oneway only forwards), not on the route. The
    /// perturbed route leaves the base at the stretch's start, follows that
    /// road's edge over the projection of the stretch, and rejoins the base
    /// at the stretch's end.
    case parallel

    public static let minTurnDegrees = 45.0
    public static let straightDegrees = 30.0
    public static let missedTurnLengthM = 500.0
    public static let parallelMinLengthM = 150.0
    public static let parallelLateralM: ClosedRange<Double> = 25...150
    public static let parallelHeadingDegrees = 20.0
}

/// What the perturbation did, in relative terms only.
public struct ReplayRoutePerturbation: Hashable, Sendable, Codable {
    public var mode: String
    public var seed: UInt64
    public var candidates: Int
    public var chosen: Int
    /// Where the perturbed route leaves the base, metres along the base.
    public var atAlongM: Double
    /// Length of the wrong part, metres.
    public var wrongLengthM: Double
    /// `parallel`: lateral offset of the neighbouring street at the
    /// stretch's midpoint, metres.
    public var lateralM: Double?
}

public enum RoutePerturber {
    public static func perturb(
        _ base: Route, mode: RoutePerturbation, match: RouteEdgeMatch, network: RoadNetwork, seed: UInt64
    ) -> (route: Route, info: ReplayRoutePerturbation)? {
        switch mode {
        case .missedTurn: missedTurn(base, match: match, network: network, seed: seed)
        case .parallel: parallel(base, match: match, network: network, seed: seed)
        }
    }

    typealias XY = (east: Double, north: Double)

    /// Offset from a to b in metres at a's latitude.
    static func offset(_ a: RoadPoint, _ b: RoadPoint) -> XY {
        let k = RoadGrid.trueMetresPerE7(latitude: a.latitude)
        return (RoutePolyline.lonDeltaE7(Double(b.lonE7) - Double(a.lonE7)) * k.lon,
                (Double(b.latE7) - Double(a.latE7)) * k.lat)
    }

    static func bearingDeg(_ d: XY) -> Double { RoadGeometry.bearing(east: d.east, north: d.north) * 180 / .pi }

    static func diffDeg(_ a: Double, _ b: Double) -> Double {
        RoadGeometry.wrapPi((a - b) * .pi / 180) * 180 / .pi
    }

    /// Points of edge `e` in travel order.
    static func travelPoints(_ network: RoadNetwork, _ e: RoadNetwork.EdgeRef, forward: Bool) -> [RoadPoint] {
        let pack = network.packs[e.pack]
        let r = pack.edge(e.edge)
        let points = (0..<Int(r.pointCount)).map { pack.point(Int(r.firstPoint) + $0) }
        return forward ? points : points.reversed()
    }

    /// Bearing of the first `chordM` of a point list (or its whole length).
    static func headBearing(_ points: [RoadPoint], chordM: Double = 20) -> Double {
        var travelled = 0.0
        var end = points[min(1, points.count - 1)]
        for i in 1..<points.count {
            travelled += RoadGeometry.distanceM(from: points[i - 1], to: points[i])
            end = points[i]
            if travelled >= chordM { break }
        }
        return bearingDeg(offset(points[0], end))
    }

    /// Drivable edges leaving pack node `node` other than `exclude`, with
    /// their points in travel order (from the node).
    static func leaving(_ network: RoadNetwork, pack p: Int, node: Int, exclude: Set<Int>)
        -> [(edge: RoadNetwork.EdgeRef, points: [RoadPoint])]
    {
        let pack = network.packs[p]
        var out: [(edge: RoadNetwork.EdgeRef, points: [RoadPoint])] = []
        for f in pack.incidentEdges(node) where !exclude.contains(f) {
            let r = pack.edge(f)
            let ref = RoadNetwork.EdgeRef(pack: p, edge: f)
            if Int(r.from) == node { out.append((ref, travelPoints(network, ref, forward: true))) }
            if Int(r.to) == node, !r.isOneway, r.from != r.to {
                out.append((ref, travelPoints(network, ref, forward: false)))
            }
        }
        return out
    }

    static func missedTurn(_ base: Route, match: RouteEdgeMatch, network: RoadNetwork, seed: UInt64)
        -> (route: Route, info: ReplayRoutePerturbation)?
    {
        let edges = match.edges
        struct Candidate { var along: Double; var node: RoadPoint; var straight: [RoadPoint]; var pack: Int; var nodeIndex: Int; var incoming: Double }
        var candidates: [Candidate] = []
        for i in edges.indices.dropLast() {
            let a = edges[i], b = edges[i + 1]
            guard RouteEdgeMatcher.contiguous(edges, i, i + 1), a.edge.pack == b.edge.pack else { continue }
            let pack = network.packs[a.edge.pack]
            let ra = pack.edge(a.edge.edge)
            let lengthA = Double(ra.lengthDm) / 10
            // The route must leave a at its end node.
            let atEnd = a.forward ? a.edgeToM >= lengthA - 1 : a.edgeToM <= 1
            guard atEnd else { continue }
            let node = Int(a.forward ? ra.to : ra.from)
            let inPoints = Array(travelPoints(network, a.edge, forward: !a.forward))  // from the node backwards
            let incoming = (headBearing(inPoints) + 180).truncatingRemainder(dividingBy: 360)
            let outRoute = headBearing(travelPoints(network, b.edge, forward: b.forward))
            guard abs(diffDeg(outRoute, incoming)) >= RoutePerturbation.minTurnDegrees else { continue }
            let options = leaving(network, pack: a.edge.pack, node: node, exclude: [a.edge.edge, b.edge.edge])
                .map { ($0, abs(diffDeg(headBearing($0.points), incoming))) }
                .filter { $0.1 <= RoutePerturbation.straightDegrees }
            guard let best = options.min(by: { ($0.1, $0.0.edge) < ($1.1, $1.0.edge) }) else { continue }
            candidates.append(Candidate(along: a.routeToM, node: pack.node(node), straight: best.0.points,
                                        pack: a.edge.pack, nodeIndex: node, incoming: incoming))
        }
        guard !candidates.isEmpty else { return nil }
        let chosen = Int(seed % UInt64(candidates.count))
        let c = candidates[chosen]
        // Straight on for missedTurnLengthM.
        var wrong: [RoadPoint] = [c.node]
        var length = 0.0
        var current = c.straight
        var heading = c.incoming
        var visitedNodes: Set<Int> = [c.nodeIndex]
        let pack = network.packs[c.pack]
        walk: while true {
            for p in current.dropFirst() {
                let previous = wrong[wrong.count - 1]
                let step = RoadGeometry.distanceM(from: previous, to: p)
                let left = RoutePerturbation.missedTurnLengthM - length
                if step >= left {
                    // End exactly missedTurnLengthM from the junction.
                    let f = step > 0 ? left / step : 0
                    wrong.append(RoadPoint(
                        latE7: Int32((Double(previous.latE7) + f * Double(Int64(p.latE7) - Int64(previous.latE7))).rounded()),
                        lonE7: Int32((Double(previous.lonE7) + f * Double(Int64(p.lonE7) - Int64(previous.lonE7))).rounded())
                    ))
                    length += left
                    break walk
                }
                length += step
                wrong.append(p)
            }
            guard current.count >= 2 else { break }
            heading = bearingDeg(offset(current[current.count - 2], current[current.count - 1]))
            // The node at the end of this edge.
            let endPoint = current[current.count - 1]
            guard let endNode = nodeIndex(pack, at: endPoint), visitedNodes.insert(endNode).inserted else { break }
            let next = leaving(network, pack: c.pack, node: endNode, exclude: [])
                .filter { $0.points.count >= 2 && $0.points[1] != current[current.count - 2] }
                .map { ($0, abs(diffDeg(headBearing($0.points), heading))) }
                .filter { $0.1 <= RoutePerturbation.straightDegrees }
                .min { ($0.1, $0.0.edge) < ($1.1, $1.0.edge) }
            guard let next else { break }
            current = next.0.points
        }
        let basePolyline = RoutePolyline(route: base)
        var points = basePolyline.points.enumerated().filter { basePolyline.cumulativeDistanceM[$0.offset] < c.along }.map(\.element)
        if points.isEmpty { points = [basePolyline.points[0]] }
        let junction = points.count
        points.append(contentsOf: wrong.map { RoutePoint(latE7: $0.latE7, lonE7: $0.lonE7) })
        guard let route = makeRoute(base, points: points, breaks: [junction], suffix: "missed-turn") else { return nil }
        return (route, ReplayRoutePerturbation(mode: RoutePerturbation.missedTurn.rawValue, seed: seed,
                                               candidates: candidates.count, chosen: chosen, atAlongM: c.along,
                                               wrongLengthM: length, lateralM: nil))
    }

    /// The node of `pack` at `point`, found through the edges listed in the
    /// point's cell (an edge end with equal coordinates).
    static func nodeIndex(_ pack: RoadPack, at point: RoadPoint) -> Int? {
        let cell = pack.grid.cell(latitude: point.latitude, longitude: point.longitude)
        var found: Int?
        pack.forEachSegment(inCellX: cell.cx, y: cell.cy) { start in
            guard found == nil else { return }
            let r = pack.edge(pack.edgeOfPoint(start))
            if pack.node(Int(r.from)) == point { found = Int(r.from) } else if pack.node(Int(r.to)) == point { found = Int(r.to) }
        }
        return found
    }

    static func parallel(_ base: Route, match: RouteEdgeMatch, network: RoadNetwork, seed: UInt64)
        -> (route: Route, info: ReplayRoutePerturbation)?
    {
        let basePolyline = RoutePolyline(route: base)
        var onRoute: Set<RoadSegmentKey> = []
        for e in match.edges { for i in e.segmentIndices { onRoute.insert(RoadSegmentKey(osmWayID: e.osmWayID, index: i)) } }
        struct Candidate { var from: Double; var to: Double; var clip: [RoadPoint]; var lateral: Double }
        var candidates: [Candidate] = []
        for e in match.edges where e.routeToM - e.routeFromM >= RoutePerturbation.parallelMinLengthM {
            let s0 = e.routeFromM, s1 = e.routeToM
            let a = basePolyline.position(atDistanceAlongM: s0), b = basePolyline.position(atDistanceAlongM: s1)
            let mid = basePolyline.position(atDistanceAlongM: (s0 + s1) / 2)
            guard let pa = RoutePoint(latitude: a.latitude, longitude: a.longitude),
                  let pb = RoutePoint(latitude: b.latitude, longitude: b.longitude),
                  let pm = RoutePoint(latitude: mid.latitude, longitude: mid.longitude) else { continue }
            let ra = RoadPoint(latE7: pa.latE7, lonE7: pa.lonE7), rb = RoadPoint(latE7: pb.latE7, lonE7: pb.lonE7)
            let rm = RoadPoint(latE7: pm.latE7, lonE7: pm.lonE7)
            let direction = bearingDeg(offset(ra, rb))
            var best: (lateral: Double, edge: RoadNetwork.EdgeRef, forward: Bool)?
            for ref in segmentsAround(network, rm, radiusM: RoutePerturbation.parallelLateralM.upperBound) {
                let seg = network.segment(ref)
                guard seg.key.osmWayID != e.osmWayID, !onRoute.contains(seg.key) else { continue }
                let edgeRef = RoadNetwork.EdgeRef(pack: ref.pack, edge: seg.edgeIndex)
                let record = network.packs[ref.pack].edge(seg.edgeIndex)
                let sa = offset(rm, seg.a), sb = offset(rm, seg.b)
                let projection = RoadGeometry.project(px: 0, py: 0, ax: sa.east, ay: sa.north, bx: sb.east, by: sb.north)
                let lateral = projection.distance
                guard RoutePerturbation.parallelLateralM.contains(lateral) else { continue }
                let segBearing = bearingDeg((sb.east - sa.east, sb.north - sa.north))
                let forwardDiff = abs(diffDeg(segBearing, direction))
                let forward: Bool
                if forwardDiff <= RoutePerturbation.parallelHeadingDegrees {
                    forward = true
                } else if !record.isOneway, abs(diffDeg(segBearing + 180, direction)) <= RoutePerturbation.parallelHeadingDegrees {
                    forward = false
                } else {
                    continue
                }
                if best.map({ (lateral, edgeRef) < ($0.lateral, $0.edge) }) ?? true { best = (lateral, edgeRef, forward) }
            }
            guard let best else { continue }
            // The parallel edge between the projections of the stretch's ends.
            let points = travelPoints(network, best.edge, forward: best.forward)
            guard let line = try? RoutePolyline(points.map { RoutePoint(latE7: $0.latE7, lonE7: $0.lonE7) }),
                  let qa = line.project(latitude: a.latitude, longitude: a.longitude),
                  let qb = line.project(latitude: b.latitude, longitude: b.longitude),
                  qb.distanceAlongM - qa.distanceAlongM >= 0.5 * (s1 - s0) else { continue }
            var clip: [RoutePoint] = []
            if let p = RoutePoint(latitude: qa.latitude, longitude: qa.longitude) { clip.append(p) }
            for (i, s) in line.cumulativeDistanceM.enumerated() where s > qa.distanceAlongM && s < qb.distanceAlongM {
                clip.append(line.points[i])
            }
            if let p = RoutePoint(latitude: qb.latitude, longitude: qb.longitude) { clip.append(p) }
            candidates.append(Candidate(from: s0, to: s1, clip: clip.map { RoadPoint(latE7: $0.latE7, lonE7: $0.lonE7) },
                                        lateral: best.lateral))
        }
        guard !candidates.isEmpty else { return nil }
        let chosen = Int(seed % UInt64(candidates.count))
        let c = candidates[chosen]
        let cumulative = basePolyline.cumulativeDistanceM
        var points = basePolyline.points.enumerated().filter { cumulative[$0.offset] < c.from }.map(\.element)
        if points.isEmpty { points = [basePolyline.points[0]] }
        let leave = points.count
        points.append(contentsOf: c.clip.map { RoutePoint(latE7: $0.latE7, lonE7: $0.lonE7) })
        let rejoin = points.count
        points.append(contentsOf: basePolyline.points.enumerated().filter { cumulative[$0.offset] > c.to }.map(\.element))
        guard points.count >= 2,
              let route = makeRoute(base, points: points, breaks: rejoin < points.count ? [leave, rejoin] : [leave], suffix: "parallel")
        else { return nil }
        let wrongLength = (try? RoutePolyline(c.clip.map { RoutePoint(latE7: $0.latE7, lonE7: $0.lonE7) }).lengthM) ?? 0
        return (route, ReplayRoutePerturbation(mode: RoutePerturbation.parallel.rawValue, seed: seed,
                                               candidates: candidates.count, chosen: chosen, atAlongM: c.from,
                                               wrongLengthM: wrongLength, lateralM: c.lateral))
    }

    /// Segments listed in every grid cell within `radiusM` of a point,
    /// de-duplicated, in cell order.
    static func segmentsAround(_ network: RoadNetwork, _ p: RoadPoint, radiusM: Double) -> [RoadNetwork.SegmentRef] {
        let k = RoadGrid.trueMetresPerE7(latitude: p.latitude)
        let dLat = radiusM / k.lat / 1e7, dLon = radiusM / k.lon / 1e7
        let sw = network.grid.cell(latitude: p.latitude - dLat, longitude: p.longitude - dLon)
        let ne = network.grid.cell(latitude: p.latitude + dLat, longitude: p.longitude + dLon)
        var seen: Set<RoadNetwork.SegmentRef> = []
        var out: [RoadNetwork.SegmentRef] = []
        for cy in min(sw.cy, ne.cy)...max(sw.cy, ne.cy) {
            for cx in min(sw.cx, ne.cx)...max(sw.cx, ne.cx) {
                network.forEachSegment(inCellX: cx, y: cy) { ref in
                    if seen.insert(ref).inserted { out.append(ref) }
                }
            }
        }
        return out
    }

    /// A synthetic route over `points` with a step ending at each break
    /// vertex (maneuvers from geometry), depart and arrive.
    static func makeRoute(_ base: Route, points: [RoutePoint], breaks: [Int], suffix: String) -> Route? {
        guard let polyline = try? RoutePolyline(points) else { return nil }
        let last = points.count - 1
        var ranges: [ClosedRange<Int>] = [0...0]
        var from = 0
        for b in breaks.map({ min(max($0, 0), last) }) + [last] where b >= from {
            ranges.append(from...b)
            from = b
        }
        guard let maneuvers = try? RouteManeuver.computed(polyline: polyline, stepRanges: ranges) else { return nil }
        let steps = ranges.enumerated().map { i, r in
            RouteStep(instruction: "", distanceM: polyline.cumulativeDistanceM[r.upperBound] - polyline.cumulativeDistanceM[r.lowerBound],
                      polylineRange: r, maneuver: maneuvers[i])
        }
        let scale = base.distanceM > 0 ? polyline.lengthM / base.distanceM : 1
        return try? Route(id: base.id + "-" + suffix, polyline: points, steps: steps, distanceM: polyline.lengthM,
                          expectedTravelTimeS: base.expectedTravelTimeS * scale, source: .synthetic, label: base.label)
    }
}

// MARK: - Evaluation (E.3)

/// A route used in a replay: where it came from, its match, and when it
/// applies.
public struct ReplayActiveRoute: Sendable {
    public var route: Route
    public var match: RouteEdgeMatch
    public var windows: [ReplayTimeWindow]
    /// Along-route ranges the estimate is projected onto (a reference
    /// route's spans, so the chords between spans never count); nil: the
    /// whole polyline.
    public var alongRanges: [ClosedRange<Double>]?

    public init(route: Route, match: RouteEdgeMatch, windows: [ReplayTimeWindow], alongRanges: [ClosedRange<Double>]? = nil) {
        self.route = route
        self.match = match
        self.windows = windows
        self.alongRanges = alongRanges
    }
}

/// How the estimate track ran against the route, over the route's time.
public struct ReplayRouteStats: Hashable, Sendable, Codable {
    /// 1 Hz track points evaluated.
    public var samples: Int
    /// |cross-track| from the estimate to the route, metres (nearest rank).
    public var crossTrackMedianM: Double?
    public var crossTrackP95M: Double?
    public var crossTrackMaxM: Double?
    /// Share of samples whose estimate is on a route edge: the nearest road
    /// segment within `onEdgeDistanceM`, direction within
    /// `onEdgeHeadingDegrees` of the estimate's heading (either way), is one
    /// of the matched route's segments.
    public var onRouteEdgeShare: Double?
    /// Share of samples with no such segment at all (off the mapped roads).
    public var offRoadShare: Double?
}

/// `metrics.json` `route`, the summary's `Route` lines.
public struct ReplayRouteReport: Hashable, Sendable, Codable {
    public struct Entry: Hashable, Sendable, Codable {
        public var id: String
        public var source: String
        public var points: Int
        public var lengthM: Double
        public var coverage: Double
        public var isWeak: Bool
        public var matchedLengthM: Double
        public var gaps: [RouteMatchGap]
        public var edges: Int
        public var windows: [ReplayTimeWindow]
    }

    /// `file`, `reference` or `recording`.
    public var from: String
    public var routes: [Entry]
    public var perturbation: ReplayRoutePerturbation?
    /// Reference routes: clean fixes read and used (`ReferenceRouteRule`).
    public var referenceFixesSeen: Int?
    public var referenceFixesUsed: Int?
    public var referenceFixesExcludedByTruth: Int?
    /// Over every route window.
    public var estimate: ReplayRouteStats
    /// The same restricted to the time the GPS mode withholds fixes from the
    /// engine (after `withheldFromT`); nil when it withholds none by time.
    public var withheldFromT: Double?
    public var estimateWhileWithheld: ReplayRouteStats?

    public init(
        from: String, routes: [Entry], perturbation: ReplayRoutePerturbation? = nil,
        referenceFixesSeen: Int? = nil, referenceFixesUsed: Int? = nil, referenceFixesExcludedByTruth: Int? = nil,
        estimate: ReplayRouteStats, withheldFromT: Double? = nil, estimateWhileWithheld: ReplayRouteStats? = nil
    ) {
        self.from = from
        self.routes = routes
        self.perturbation = perturbation
        self.referenceFixesSeen = referenceFixesSeen
        self.referenceFixesUsed = referenceFixesUsed
        self.referenceFixesExcludedByTruth = referenceFixesExcludedByTruth
        self.estimate = estimate
        self.withheldFromT = withheldFromT
        self.estimateWhileWithheld = estimateWhileWithheld
    }
}

public enum ReplayRouteEvaluation {
    public static let onEdgeDistanceM = 15.0
    public static let onEdgeHeadingDegrees = 45.0

    /// The E.3 numbers for a run's track against its routes.
    public static func stats(
        track: [ReplayResult.TrackPoint], routes: [ReplayActiveRoute], network: RoadNetwork,
        from fromT: Double? = nil
    ) -> ReplayRouteStats {
        let polylines = routes.map { RoutePolyline(route: $0.route) }
        let keys: [Set<RoadSegmentKey>] = routes.map { r in
            var set: Set<RoadSegmentKey> = []
            for e in r.match.edges { for i in e.segmentIndices { set.insert(RoadSegmentKey(osmWayID: e.osmWayID, index: i)) } }
            return set
        }
        var cross: [Double] = []
        var onEdge = 0, offRoad = 0
        for point in track {
            if let fromT, point.t <= fromT { continue }
            guard let r = routes.indices.first(where: { routes[$0].windows.contains { $0.contains(point.t) } }) else { continue }
            let ranges: [ClosedRange<Double>?] = routes[r].alongRanges.map { $0.map(Optional.some) } ?? [nil]
            var best: Double?
            for range in ranges {
                if let p = polylines[r].project(latitude: point.latitude, longitude: point.longitude, alongRangeM: range) {
                    let d = abs(p.crossTrackM)
                    if best.map({ d < $0 }) ?? true { best = d }
                }
            }
            guard let distance = best else { continue }
            cross.append(distance)
            switch nearestSegmentKey(network, latitude: point.latitude, longitude: point.longitude, headingDeg: point.headingDeg) {
            case .some(let key): if keys[r].contains(key) { onEdge += 1 }
            case .none: offRoad += 1
            }
        }
        let n = cross.count
        guard n > 0 else { return ReplayRouteStats(samples: 0) }
        let sorted = cross.sorted()
        func rank(_ q: Double) -> Double { sorted[min(max(Int((q * Double(n)).rounded(.up)) - 1, 0), n - 1)] }
        return ReplayRouteStats(
            samples: n, crossTrackMedianM: rank(0.5), crossTrackP95M: rank(0.95), crossTrackMaxM: sorted[n - 1],
            onRouteEdgeShare: Double(onEdge) / Double(n), offRoadShare: Double(offRoad) / Double(n)
        )
    }

    /// The key of the nearest segment within `onEdgeDistanceM` whose
    /// direction is within `onEdgeHeadingDegrees` of `headingDeg` (either
    /// way); nil when there is none.
    public static func nearestSegmentKey(
        _ network: RoadNetwork, latitude: Double, longitude: Double, headingDeg: Double
    ) -> RoadSegmentKey? {
        let k = RoadGrid.trueMetresPerE7(latitude: latitude)
        let qLat = latitude * 1e7, qLon = longitude * 1e7
        var best: (d: Double, key: RoadSegmentKey)?
        for ref in network.segments(nearLatitude: latitude, longitude: longitude) {
            let s = network.segment(ref)
            let ax = RoutePolyline.lonDeltaE7(Double(s.a.lonE7) - qLon) * k.lon, ay = (Double(s.a.latE7) - qLat) * k.lat
            let bx = RoutePolyline.lonDeltaE7(Double(s.b.lonE7) - qLon) * k.lon, by = (Double(s.b.latE7) - qLat) * k.lat
            let d = RoadGeometry.project(px: 0, py: 0, ax: ax, ay: ay, bx: bx, by: by).distance
            guard d <= onEdgeDistanceM else { continue }
            let beta = RoadGeometry.bearing(east: bx - ax, north: by - ay)
            let diff = RoadGeometry.headingDifference(heading: headingDeg * .pi / 180, bearing: beta, oneway: false)
            guard diff <= onEdgeHeadingDegrees * .pi / 180 else { continue }
            if best.map({ (d, s.key) < ($0.d, $0.key) }) ?? true { best = (d, s.key) }
        }
        return best?.key
    }

    public static func entry(_ active: ReplayActiveRoute) -> ReplayRouteReport.Entry {
        ReplayRouteReport.Entry(
            id: active.route.id, source: active.route.source.rawValue, points: active.route.polyline.count,
            lengthM: active.match.routeLengthM, coverage: active.match.coverage, isWeak: active.match.isWeak,
            matchedLengthM: active.match.matchedLengthM, gaps: active.match.gaps, edges: active.match.edges.count,
            windows: active.windows
        )
    }
}
