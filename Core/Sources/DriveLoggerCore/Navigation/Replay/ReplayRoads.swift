import Foundation

// Roads in a replay (N3.2b, docs/N3_PLAN.md "N3.2" and "Metrics added to
// replay_nav"): the road set a run uses and how it is named in every output.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.

/// The road network a replay gives its engine (`replay_nav --roads`).
/// Two road sets are equal when they hold the same packs (content hashes),
/// in whatever order they were passed: the network keeps them in canonical
/// order (ascending content hash), the identity a result records.
public struct ReplayRoadSet: Hashable, Sendable {
    public let network: RoadNetwork
    /// File names by content hash (`replay_nav --roads`): how the
    /// selector names the packs in `roadsSelection` lines, as the app
    /// names them. Not part of the set's identity.
    public let names: [UInt64: String]

    public init(_ network: RoadNetwork) {
        self.init(network, names: [:])
    }

    public init(_ network: RoadNetwork, names: [UInt64: String]) {
        self.network = network
        self.names = names
    }

    public static func == (a: ReplayRoadSet, b: ReplayRoadSet) -> Bool {
        a.network === b.network || a.network.packs.map(\.contentHash) == b.network.packs.map(\.contentHash)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(network.roadSetHash)
    }

    /// Per pack, in canonical order (ascending content hash): what a
    /// result records.
    public var packs: [ReplayRoadPack] { network.packs.map(ReplayRoadPack.init) }

    /// FNV-1a 64 over the packs' content hashes in ascending order, 16 hex
    /// digits.
    public var roadSetHashHex: String { network.roadSetHashHex }

    /// The mode label's suffix: `roads-` and the first 8 hex digits of
    /// `roadSetHash`, so runs with and without roads (or with another road
    /// set) never share a `metrics.json` row or a GeoJSON file.
    public var labelSuffix: String { "roads-" + String(roadSetHashHex.prefix(8)) }

    /// A selector over these packs (`ReplayRoadAttach.live`), each named by
    /// its file name (`names`), else its content hash. With every pack
    /// named, candidates are in file-name order, as the app's library
    /// lists them; else in canonical order. The order changes only the
    /// `roadsSelection` lines: the network is canonical either way. A pack
    /// whose coverage cannot be read covers nothing.
    public var selector: RoadPackSelector {
        var candidates = network.packs.map { pack in
            let name = names[pack.contentHash] ?? NavigationSeed.hex(pack.contentHash)
            let coverage = (try? RoadPackCoverage(pack: pack)) ?? RoadPackCoverage(rings: nil, bounds: nil)
            return RoadPackSelection.Candidate(name: name, pack: pack, coverage: coverage)
        }
        if network.packs.allSatisfy({ names[$0.contentHash] != nil }) { candidates.sort { $0.name < $1.name } }
        return RoadPackSelector(candidates: candidates)
    }
}

/// One road pack of a replay, as recorded in `metrics.json`, the summary
/// and the GeoJSON: enough to name the exact pack, nothing about where it
/// covers.
public struct ReplayRoadPack: Hashable, Sendable, Codable {
    /// 16 lowercase hex digits.
    public var contentHash: String
    public var formatVersion: Int
    /// The OSM data's replication timestamp, Unix seconds (0 when unknown).
    public var osmTimestamp: Int64
    /// 16 lowercase hex digits.
    public var gridID: String

    public init(contentHash: String, formatVersion: Int, osmTimestamp: Int64, gridID: String) {
        self.contentHash = contentHash
        self.formatVersion = formatVersion
        self.osmTimestamp = osmTimestamp
        self.gridID = gridID
    }

    public init(_ pack: RoadPack) {
        self.init(contentHash: NavigationSeed.hex(pack.contentHash), formatVersion: Int(pack.formatVersion),
                  osmTimestamp: pack.osmTimestamp, gridID: NavigationSeed.hex(pack.gridID))
    }

    /// "contentHash 0123…, format v1, OSM 2026-01-01T00:00:00Z, grid 89ab…".
    public var text: String {
        let date = osmTimestamp > 0
            ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(osmTimestamp)))
            : "unknown"
        return "contentHash \(contentHash), format v\(formatVersion), OSM \(date), grid \(gridID)"
    }
}

// MARK: - Road truth (offline, replay tooling only)

extension NavigationReplay {
    /// The road truth and road scoring rules (docs/N3_PLAN.md, "Metrics
    /// added to replay_nav"). **Offline:** the truth is matched with the
    /// fix itself, which the engine never received, and with the whole
    /// recording's clean fixes for the residuals; none of it reaches the
    /// engine. Frozen here, not read from the run's config, so a `--set` of
    /// a road key cannot move the truth it is scored against (as
    /// `cleanFixTruthAccM`, R19.2-1). The values are the N3.2 defaults of
    /// the engine's keys of the same meaning.
    public enum RoadTruth {
        /// A truth edge lies within this many metres of the fix (capped by
        /// the packs' guaranteed radius, so one cell lookup finds it).
        public static let searchRadiusM = 50.0
        /// Cross-track σ of a car about the OSM centreline (`roadSigmaM`).
        public static let roadSigmaM = 7.0
        /// Heading agreement σ and gate, degrees (`roadHeadingSigmaDeg`,
        /// `roadHeadingGateDeg`); oneways in their driving direction only.
        public static let headingSigmaDeg = 10.0
        public static let headingGateDeg = 45.0
        /// The fix's course σ is its `courseAccuracy`, at least this
        /// (`courseSigmaFloorDeg`).
        public static let courseSigmaFloorDeg = 2.0
        /// A fix has a usable course from this speed on (`courseMinSpeedMps`).
        public static let courseMinSpeedMps = 3.0
        /// The truth edge must be at least this many times as likely as the
        /// best edge of any other way; otherwise the fix is ambiguous and
        /// not scored.
        public static let marginRatio = 2.0
        /// Above this ambiguous share the plan asks for a Viterbi match over
        /// route distance instead; the summary says so (not implemented).
        public static let viterbiAmbiguousShare = 0.2
        /// The engine is "off" road below this `onRoadShare`.
        public static let onRoadShare = 0.5
        /// A withheld clean fix is "unmapped" (`UnmappedReason`) when no
        /// edge of any heading lies within this many metres (R21.1-11), or,
        /// with a usable course, when none within it is heading-compatible
        /// (N3.2c item 2). A fix with no usable course keeps the distance
        /// rule alone, so the widening never drops a fix.
        public static let unmappedDistanceM = 15.0
        /// The truth is on a road only within this many metres of its
        /// best heading-compatible edge (the same 15 m): a fix 40 m beside
        /// a mapped road is on an unmapped one, not on that road. So the
        /// residuals are censored at 15 m (measured p95 ≈ 7 m).
        public static let onRoadMaxM = 15.0
        /// "Captured" while the truth is unmapped: on a mapped edge with a
        /// 95 % ellipse narrower than this across it, and the truth outside
        /// that ellipse (R21.1-11; the cross-track threshold of N3.2 test 3).
        public static let capturedCrossTrackM = 25.0

        /// A usable course for the road truth: valid, at `courseMinSpeedMps`
        /// or more. A stopped or creeping car's course is not one (on the
        /// clean-long drive 115 of 277 withheld clean fixes: 63 stopped by
        /// OBD, 52 under 3 m/s by GNSS).
        public static func course(of sample: LocationSample) -> Double? {
            sample.hasValidCourse && sample.hasValidSpeed && sample.speed >= courseMinSpeedMps ? sample.course : nil
        }
    }
}

/// How a clean fix was matched to a road (offline truth).
public enum RoadTruthStatus: String, Hashable, Sendable, Codable {
    /// One edge, at least `RoadTruth.marginRatio` more likely than any
    /// other way's.
    case matched
    /// The best edge's margin over another way's is below the ratio: not scored.
    case ambiguous
    /// No heading-compatible edge within `RoadTruth.onRoadMaxM` (15 m): an
    /// unmapped road, a car park, or a junction the course does not fit.
    case noRoad
    /// No usable course (invalid, or under `RoadTruth.courseMinSpeedMps`).
    case noCourse
}

/// Why a withheld clean fix is unmapped (`RoadTruth.unmappedDistanceM`).
/// The two are disjoint; their sum is `ReplayRoadMetrics.unmapped`.
public enum UnmappedReason: String, Hashable, Sendable, Codable {
    /// Farther than 15 m from every edge, any heading (R21.1-11). The only
    /// rule for a fix with no usable course.
    case noRoadWithin15
    /// An edge lies within 15 m, but with a usable course none within 15 m
    /// is heading-compatible (road truth `noRoad`; N3.2c item 2): a car
    /// park or service road beside a mapped edge of another heading.
    case noCompatibleRoadWithin15

    /// The reason for a fix, from its road truth and its nearest edge of
    /// any heading; nil when the fix is not unmapped.
    public static func of(truth: RoadTruthStatus, nearestEdgeM: Double?) -> UnmappedReason? {
        typealias T = NavigationReplay.RoadTruth
        if (nearestEdgeM ?? .infinity) > T.unmappedDistanceM { return .noRoadWithin15 }
        // `noRoad`: a usable course and no heading-compatible edge within
        // `onRoadMaxM` (the same 15 m). `noCourse` never gets here.
        return truth == .noRoad ? .noCompatibleRoadWithin15 : nil
    }
}

/// The engine against the road truth at one withheld clean fix.
public enum WrongRoadVerdict: String, Hashable, Sendable, Codable, CaseIterable {
    /// On the truth's way, or within the wrong-road tolerance of the fix.
    case right
    /// On another mapped edge, farther than the tolerance from the fix.
    case wrong
    /// `onRoadShare` below 0.5 (0 included) while the truth is on a road.
    case off
    /// No road update engaged yet, or the cloud too wide (`onRoadShare` nil).
    case notEngaged
}

/// One withheld clean fix (≤ 15 m) of a run with roads.
public struct ReplayRoadFix: Hashable, Sendable, Codable {
    public var t: Double
    /// ∫ OBD speed up to `t`, metres.
    public var distanceM: Double
    /// OBD distance since the previous withheld clean fix with a usable
    /// course (0 for the first): this fix's share of "distance" in the
    /// distance-weighted wrong-road share.
    public var weightM: Double = 0
    public var accuracyM: Double
    /// Distance to the nearest segment of any heading within the search
    /// radius; nil when there is none.
    public var nearestEdgeM: Double?
    public var truth: RoadTruthStatus
    public var truthEdge: MatchedRoadEdge?
    /// OSM `highway` value of the truth edge (`_link` appended for links).
    public var truthClass: String?
    /// Distance from the fix to the truth edge, metres.
    public var crossTrackM: Double?
    /// ln(L_best / L_best-other-way); nil when no other way competes.
    public var logLikelihoodRatio: Double?
    /// The engine's last road update, as its estimate at `t` reports it.
    public var onRoadShare: Double?
    public var matchedEdge: MatchedRoadEdge?
    /// Distance from the fix to `matchedEdge`, metres.
    public var matchedEdgeDistanceM: Double?
    /// Set when the truth is `matched` and the engine had an estimate.
    public var verdict: WrongRoadVerdict?
    /// `unmappedReason != nil`: no edge within `RoadTruth.unmappedDistanceM`
    /// (R21.1-11), or no heading-compatible one with a usable course (N3.2c
    /// item 2). Files written before item 2 have the first rule only.
    public var unmapped = false
    /// Which rule made the fix unmapped; nil (absent) when it is not, and in
    /// files written before N3.2c item 2.
    public var unmappedReason: UnmappedReason?
    /// The 95 % ellipse's half-width across `matchedEdge` at the estimate.
    public var crossTrackSemiAxisM: Double?
    /// The truth inside the engine's 95 % ellipse.
    public var inside95: Bool?
    /// For an unmapped fix with an estimate: on a mapped edge (share ≥ 0.5),
    /// narrower than `RoadTruth.capturedCrossTrackM` across it, truth outside
    /// the 95 % ellipse.
    public var captured: Bool?

    public init(t: Double, distanceM: Double, accuracyM: Double, truth: RoadTruthStatus) {
        self.t = t
        self.distanceM = distanceM
        self.accuracyM = accuracyM
        self.truth = truth
    }
}

/// Percentiles of a set of distances, metres (nearest rank).
public struct DistanceStats: Hashable, Sendable, Codable {
    public var count: Int
    public var p50M: Double
    public var p95M: Double
    public var maxM: Double

    /// nil for an empty set.
    public init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double { sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
        count = sorted.count
        p50M = rank(0.5)
        p95M = rank(0.95)
        maxM = sorted[sorted.count - 1]
    }
}

/// The road metrics of one run with roads (`metrics.json` `roadMetrics`).
public struct ReplayRoadMetrics: Hashable, Sendable, Codable {
    public struct Count: Hashable, Sendable, Codable {
        public var fixes = 0
        public var distanceM = 0.0
        public init() {}
    }

    public var wrongRoadToleranceM: Double
    /// Withheld clean fixes (≤ 15 m) scored for roads.
    public var withheldCleanFixes = 0
    /// Road truth status counts over them.
    public var truth: [String: Int] = [:]
    /// ambiguous / (matched + ambiguous); nil when neither.
    public var ambiguousShare: Double?
    /// Verdict counts and distances over fixes with a matched truth and an
    /// estimate, keyed by `WrongRoadVerdict` raw value.
    public var verdicts: [String: Count] = [:]
    /// wrong / scored, by fixes and by distance; nil when nothing is scored.
    public var wrongShare: Double?
    public var wrongShareByDistance: Double?
    public var offShare: Double?
    public var offShareByDistance: Double?
    /// Unmapped withheld clean fixes (`UnmappedReason`), how many of those
    /// had an estimate, and how many of those were captured. Before N3.2c
    /// item 2 these counted fixes > 15 m from every edge only.
    public var unmapped = 0
    public var unmappedWithEstimate = 0
    public var unmappedCaptured = 0
    /// N3.2c item 2: `unmapped` and `unmappedCaptured` by reason, so the
    /// R21.1-11 figure (`noRoadWithin15`) stays visible. nil (absent) in
    /// files written before item 2.
    public var unmappedNoRoadWithin15: Int?
    public var unmappedNoCompatibleRoadWithin15: Int?
    public var unmappedCapturedNoRoadWithin15: Int?
    public var unmappedCapturedNoCompatibleRoadWithin15: Int?
    /// Offline: cross-track distance of every clean fix (used or withheld,
    /// usable course, matched truth) to its truth edge, per highway class
    /// and over all. Censored at `RoadTruth.onRoadMaxM` (15 m).
    public var residuals: [String: DistanceStats] = [:]
    public var residualsAll: DistanceStats?
    /// 1 Hz track samples after initialisation: how many, how many with a
    /// road update engaged (`onRoadShare` set), how many on road (≥ 0.5),
    /// and the mean share over the engaged ones.
    public var trackSamples = 0
    public var trackEngaged = 0
    public var trackOnRoad = 0
    public var meanOnRoadShare: Double?
    /// `roadCandidateTests` per road update, and per particle and update.
    public var candidateTestsPerUpdate: Double?
    public var candidateTestsPerParticle: Double?
    /// Fixes the engine ignored as off-road (`fixesRejectedOffRoad`): t, accuracy.
    public var rejectedFixes: [[Double]] = []
    public var fixes: [ReplayRoadFix] = []

    public init(wrongRoadToleranceM: Double) {
        self.wrongRoadToleranceM = wrongRoadToleranceM
    }

    public var scored: Int { verdicts.values.reduce(0) { $0 + $1.fixes } }

    public func count(_ verdict: WrongRoadVerdict) -> Count { verdicts[verdict.rawValue] ?? Count() }
}

// MARK: - Matcher

/// The offline road truth and the road geometry the replay needs: the
/// truth edge of a fix, distances to an edge, an ellipse's width across an
/// edge, an edge's coordinates. Each query works in a local plane at its
/// own point. Replay only; the engine has its own `RoadMatcher`.
struct RoadTruthMatcher {
    typealias T = NavigationReplay.RoadTruth
    let network: RoadNetwork

    var radius: Double { min(T.searchRadiusM, network.grid.searchRadiusM) }

    struct Near {
        var edge: MatchedRoadEdge
        var key: RoadSegmentKey
        var distance: Double
        /// Unit forward direction (east, north).
        var ux: Double, uy: Double
        var oneway: Bool
    }

    /// Every de-duplicated segment within `radius` of the point, any heading.
    func nearby(latitude: Double, longitude: Double) -> [Near] {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        var out: [Near] = []
        for ref in network.segments(nearLatitude: latitude, longitude: longitude) {
            let pack = network.packs[ref.pack]
            let s = pack.segment(startingAt: ref.startPoint)
            let a = plane.enu(latitude: s.a.latitude, longitude: s.a.longitude)
            let b = plane.enu(latitude: s.b.latitude, longitude: s.b.longitude)
            let dx = b.east - a.east, dy = b.north - a.north
            let length = (dx * dx + dy * dy).squareRoot()
            let ux = length > 0 ? dx / length : 0, uy = length > 0 ? dy / length : 1
            let d = RoadMatcher.nearest(px: 0, py: 0, ax: a.east, ay: a.north, ux: ux, uy: uy, length: length)
                .distanceSquared.squareRoot()
            guard d <= radius else { continue }
            let record = pack.edge(s.edgeIndex)
            out.append(Near(edge: MatchedRoadEdge(pack: ref.pack, edge: s.edgeIndex, osmWayID: record.osmWayID),
                            key: s.key, distance: d, ux: ux, uy: uy, oneway: record.isOneway))
        }
        return out
    }

    struct Match {
        var status: RoadTruthStatus
        var nearestM: Double?
        var edge: MatchedRoadEdge?
        var crossTrackM: Double?
        var logLikelihoodRatio: Double?
    }

    /// The truth edge of a fix: the heading-compatible segment within
    /// `RoadTruth.onRoadMaxM` (competitors: every heading-compatible
    /// segment within the search radius) with the
    /// largest likelihood N(d; σ_fix² + σr²) · N(Δψ; σ_course² + σψ²) (ties
    /// to the lower segment key), matched when its way beats every other
    /// way by `RoadTruth.marginRatio`. `courseDeg` nil: no usable course.
    func match(latitude: Double, longitude: Double, accuracyM: Double, courseDeg: Double?,
               courseAccuracyDeg: Double) -> Match {
        let near = nearby(latitude: latitude, longitude: longitude)
        let nearest = near.map(\.distance).min()
        guard let courseDeg else { return Match(status: .noCourse, nearestM: nearest) }
        let c = courseDeg * .pi / 180
        let sinC = sin(c), cosC = cos(c)
        let cosGate = cos(T.headingGateDeg * .pi / 180)
        let sigmaFix = max(accuracyM, 0) / NavigationReplay.accuracyPerSigma
        let s = sigmaFix * sigmaFix + T.roadSigmaM * T.roadSigmaM
        let sc = max(courseAccuracyDeg, T.courseSigmaFloorDeg) * .pi / 180
        let sh = T.headingSigmaDeg * .pi / 180
        let sPsi = sc * sc + sh * sh
        var scored: [(logL: Double, near: Near)] = []
        for n in near {
            let dot = sinC * n.ux + cosC * n.uy
            guard n.oneway ? dot >= cosGate : abs(dot) >= cosGate else { continue }
            let cross = sinC * n.uy - cosC * n.ux
            let dPsi = atan2(abs(cross), n.oneway ? dot : abs(dot))
            scored.append((-0.5 * n.distance * n.distance / s - 0.5 * dPsi * dPsi / sPsi, n))
        }
        // The truth edge lies within `onRoadMaxM`; every heading-compatible
        // edge within the search radius competes for the margin.
        let onRoad = scored.filter { $0.near.distance <= T.onRoadMaxM }
        guard var best = onRoad.first else { return Match(status: .noRoad, nearestM: nearest) }
        for candidate in onRoad.dropFirst()
        where candidate.logL > best.logL || (candidate.logL == best.logL && candidate.near.key < best.near.key) {
            best = candidate
        }
        let other = scored.filter { $0.near.edge.osmWayID != best.near.edge.osmWayID }.map(\.logL).max()
        let ratio = other.map { best.logL - $0 }
        return Match(status: (ratio ?? .infinity) >= log(T.marginRatio) ? .matched : .ambiguous, nearestM: nearest,
                     edge: best.near.edge, crossTrackM: best.near.distance, logLikelihoodRatio: ratio)
    }

    /// The edge's shape points, in order.
    func points(of edge: MatchedRoadEdge) -> [RoadPoint] {
        let pack = network.packs[edge.pack]
        let record = pack.edge(edge.edge)
        return (0..<Int(record.pointCount)).map { pack.point(Int(record.firstPoint) + $0) }
    }

    /// OSM `highway` value of the edge, `_link` appended for a link.
    func roadClass(of edge: MatchedRoadEdge) -> String {
        let record = network.packs[edge.pack].edge(edge.edge)
        return record.highwayClass.osmValue + (record.flags.contains(.link) ? "_link" : "")
    }

    /// The edge's nearest segment to the point: distance and unit direction.
    func nearestSegment(latitude: Double, longitude: Double, of edge: MatchedRoadEdge)
        -> (distance: Double, ux: Double, uy: Double) {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        let p = points(of: edge).map { plane.enu(latitude: $0.latitude, longitude: $0.longitude) }
        var best = (distance: Double.infinity, ux: 0.0, uy: 1.0)
        for k in 0..<max(0, p.count - 1) {
            let dx = p[k + 1].east - p[k].east, dy = p[k + 1].north - p[k].north
            let length = (dx * dx + dy * dy).squareRoot()
            let ux = length > 0 ? dx / length : 0, uy = length > 0 ? dy / length : 1
            let d = RoadMatcher.nearest(px: 0, py: 0, ax: p[k].east, ay: p[k].north, ux: ux, uy: uy, length: length)
                .distanceSquared.squareRoot()
            if d < best.distance { best = (d, ux, uy) }
        }
        return best
    }

    /// Half-width of a 95 % ellipse across the edge (along the normal of
    /// the edge's segment nearest to the ellipse centre): the support
    /// √(a² (n·m)² + b² (n·m⊥)²) of the ellipse in that direction.
    func semiAxisAcross(_ ellipse: ErrorEllipse, latitude: Double, longitude: Double,
                        edge: MatchedRoadEdge) -> Double {
        let s = nearestSegment(latitude: latitude, longitude: longitude, of: edge)
        return Self.support(ellipse, normalEast: -s.uy, normalNorth: s.ux)
    }

    /// The ellipse's half-width along the unit direction (east, north).
    static func support(_ ellipse: ErrorEllipse, normalEast ne: Double, normalNorth nn: Double) -> Double {
        let b = ellipse.orientationDeg * .pi / 180
        let along = ne * sin(b) + nn * cos(b)
        let across = -ne * cos(b) + nn * sin(b)
        let a2 = ellipse.semiMajorM * ellipse.semiMajorM, b2 = ellipse.semiMinorM * ellipse.semiMinorM
        return (a2 * along * along + b2 * across * across).squareRoot()
    }
}
