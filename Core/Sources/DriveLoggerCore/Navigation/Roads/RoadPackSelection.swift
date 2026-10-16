import Foundation

// Pack selection (N3.3 item 3, docs/N3_PLAN.md "N3.3" amendment, "Pack
// selection when the first fix is about 1414 m"): every verified pack whose
// coverage intersects the circle of a `RoadSelectionRequest` is selected,
// and the road network is built from them. A wrong choice costs at most the
// no-roads result: every failure is a refusal with a reason, never a trap.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.

/// Where a pack has roads: its `COVR` polygon (even-odd rule) if present,
/// else the shape points' bounding box.
public struct RoadPackCoverage: Hashable, Sendable {
    public var rings: [[RoadPoint]]?
    public var bounds: RoadPackBounds?

    public init(rings: [[RoadPoint]]?, bounds: RoadPackBounds?) {
        self.rings = rings
        self.bounds = bounds
    }

    /// From an open pack: `COVR` if present, else its bounding box
    /// (O(points)).
    public init(pack: RoadPack) throws {
        if let rings = try pack.coverageRings() {
            self.init(rings: rings, bounds: nil)
        } else {
            self.init(rings: nil, bounds: pack.pointBounds().map { RoadPackBounds(southWest: $0.southWest, northEast: $0.northEast) })
        }
    }

    /// Whether the circle of `radiusM` metres around the point intersects
    /// the coverage: the centre is inside, or some coverage edge is within
    /// `radiusM`. Distances are measured in a local tangent plane at the
    /// centre (exact enough for circles of a few km; a polygon edge tens of
    /// km long is measured as a plane chord). A bounding box is tested by
    /// the distance to its nearest point (the centre clamped into it). An
    /// unusable circle (non-finite, negative radius, latitude beyond ±90°)
    /// intersects nothing.
    public func intersects(latitude: Double, longitude: Double, radiusM: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite, radiusM.isFinite, radiusM >= 0,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        if let rings {
            if RoadNetwork.evenOddContains(rings: rings, latE7: latitude * 1e7, lonE7: longitude * 1e7) { return true }
            let r2 = radiusM * radiusM
            for ring in rings where !ring.isEmpty {
                let points = ring.map { plane.enu(latitude: $0.latitude, longitude: $0.longitude) }
                var j = points.count - 1
                for i in points.indices {
                    let d2 = RoadGeometry.distanceSquared(px: 0, py: 0, ax: points[j].east, ay: points[j].north,
                                                          bx: points[i].east, by: points[i].north)
                    if d2 <= r2 { return true }
                    j = i
                }
            }
            return false
        }
        guard let b = bounds else { return false }
        let lat = min(max(latitude * 1e7, Double(b.southLatE7)), Double(b.northLatE7)) / 1e7
        let lon = min(max(longitude * 1e7, Double(b.westLonE7)), Double(b.eastLonE7)) / 1e7
        let p = plane.enu(latitude: lat, longitude: lon)
        return (p.east * p.east + p.north * p.north).squareRoot() <= radiusM
    }
}

public enum RoadPackSelection {
    /// An open pack that may be selected.
    public struct Candidate: Sendable {
        /// The file name (or any label) for reports.
        public let name: String
        public let pack: RoadPack
        public let coverage: RoadPackCoverage

        public init(name: String, pack: RoadPack, coverage: RoadPackCoverage) {
            self.name = name
            self.pack = pack
            self.coverage = coverage
        }

        /// Coverage from the pack itself (`RoadPackCoverage(pack:)`).
        public init(name: String, pack: RoadPack) throws {
            self.init(name: name, pack: pack, coverage: try RoadPackCoverage(pack: pack))
        }
    }

    /// A pack or a pack set that is not used, and why.
    public struct Refusal: Hashable, Sendable {
        public var names: [String]
        public var reason: String

        public init(names: [String], reason: String) {
            self.names = names
            self.reason = reason
        }
    }

    /// The catalog's usable packs, opened memory-mapped WITHOUT the full
    /// verification the catalog already did (or found in its cache): each
    /// file's identity must still be the verified one, and its header's
    /// content hash the verified hash; otherwise the pack is refused. Its
    /// coverage: `COVR` from the file, else the cached bounding box.
    public static func candidates(from entries: [RoadPackCatalog.Entry]) -> (candidates: [Candidate], refused: [Refusal]) {
        var candidates: [Candidate] = []
        var refused: [Refusal] = []
        for entry in entries {
            let name = entry.url.lastPathComponent
            guard entry.isUsable, let identity = entry.identity, let verification = entry.verification else {
                refused.append(Refusal(names: [name], reason: entry.refusal ?? "not usable"))
                continue
            }
            guard (try? RoadPackFileIdentity(contentsOf: entry.url)) == identity else {
                refused.append(Refusal(names: [name], reason: "the file changed since it was verified"))
                continue
            }
            do {
                let pack = try RoadPack(contentsOf: entry.url, verify: false)
                let hash = NavigationSeed.hex(pack.contentHash)
                guard hash == verification.contentHash else {
                    refused.append(Refusal(names: [name], reason: "content hash \(hash) is not the verified "
                                           + "\(verification.contentHash ?? "none")"))
                    continue
                }
                let rings = try pack.coverageRings()
                candidates.append(Candidate(name: name, pack: pack,
                                            coverage: RoadPackCoverage(rings: rings, bounds: rings == nil ? verification.bounds : nil)))
            } catch {
                refused.append(Refusal(names: [name], reason: String(describing: error)))
            }
        }
        return (candidates, refused)
    }

    public enum Outcome: Sendable {
        /// No usable circle (a missing or non-finite centre or radius): no
        /// selection.
        case unusableRequest
        /// No candidate's coverage intersects the circle.
        case noneCovering
        /// The network of the covering packs (names in the order given).
        case selected(RoadNetwork, names: [String])
        /// The covering packs cannot be used together (different grids, the
        /// same pack twice): the run goes on without roads.
        case refused(Refusal)

        public var network: RoadNetwork? {
            if case .selected(let network, _) = self { return network }
            return nil
        }
    }

    /// The candidates whose coverage intersects the circle, by index in the
    /// order given; nil for an unusable circle.
    public static func covering(_ candidates: [Candidate], latitude: Double?, longitude: Double?,
                                radiusM: Double?) -> [Int]? {
        guard let latitude, let longitude, let radiusM, latitude.isFinite, longitude.isFinite, radiusM.isFinite,
              radiusM >= 0, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return candidates.indices.filter {
            candidates[$0].coverage.intersects(latitude: latitude, longitude: longitude, radiusM: radiusM)
        }
    }

    /// Selects every candidate covering the circle and builds their network.
    public static func select(_ candidates: [Candidate], latitude: Double?, longitude: Double?,
                              radiusM: Double?) -> Outcome {
        guard let chosen = covering(candidates, latitude: latitude, longitude: longitude, radiusM: radiusM) else {
            return .unusableRequest
        }
        return build(candidates, chosen)
    }

    /// `select` at the request's centre and 95 % semi-major axis.
    public static func select(_ candidates: [Candidate], request: RoadSelectionRequest) -> Outcome {
        select(candidates, latitude: request.latitude, longitude: request.longitude, radiusM: request.radiusM)
    }

    static func build(_ candidates: [Candidate], _ chosen: [Int]) -> Outcome {
        guard !chosen.isEmpty else { return .noneCovering }
        let names = chosen.map { candidates[$0].name }
        do {
            return .selected(try RoadNetwork(packs: chosen.map { candidates[$0].pack }), names: names)
        } catch {
            return .refused(Refusal(names: names, reason: String(describing: error)))
        }
    }
}

/// A synchronous selector over fixed candidates (`replay_nav --as-live
/// --roads`, tests; the app wraps the same calls in an actor): at each
/// request it selects the covering packs and returns their network. A set
/// already refused is not built again; its refusal is returned again.
public struct RoadPackSelector: Sendable {
    public let candidates: [RoadPackSelection.Candidate]
    /// The latest outcome (diagnostics); nil before the first request.
    public private(set) var lastOutcome: RoadPackSelection.Outcome?
    /// Requests answered so far.
    public private(set) var requests = 0
    private var refused: [(set: [Int], refusal: RoadPackSelection.Refusal)] = []

    public init(candidates: [RoadPackSelection.Candidate]) {
        self.candidates = candidates
    }

    /// The network to attach for `request`, or nil.
    public mutating func network(for request: RoadSelectionRequest) -> RoadNetwork? {
        requests += 1
        guard let chosen = RoadPackSelection.covering(candidates, latitude: request.latitude,
                                                      longitude: request.longitude, radiusM: request.radiusM) else {
            lastOutcome = .unusableRequest
            return nil
        }
        if let known = refused.first(where: { $0.set == chosen }) {
            lastOutcome = .refused(known.refusal)
            return nil
        }
        let outcome = RoadPackSelection.build(candidates, chosen)
        if case .refused(let refusal) = outcome { refused.append((chosen, refusal)) }
        lastOutcome = outcome
        return outcome.network
    }
}
