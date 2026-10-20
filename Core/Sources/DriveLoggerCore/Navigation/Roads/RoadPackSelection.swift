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

    /// One selection attempt for `request`, recorded for the sidecar's
    /// `roadsSelection` line (`RoadSelectionAttempt`). Pure and Sendable:
    /// the app runs it off its actor, where it ran `select` before.
    /// - `candidates`: the verified, opened packs (`candidates(from:).candidates`);
    /// - `refusedAtScan`: the files refused when scanned or opened
    ///   (`candidates(from:).refused`), listed in the line as refused;
    /// - `knownRefusals`: pack sets this run refused before (a failed build
    ///   or attach). A covering set equal to one of them (names, in
    ///   candidate order) is not built again; its refusal is the outcome.
    ///
    /// - `attached`, `attachedNames`: the run's network and its packs' names
    ///   (candidate order; the hex content hashes when unknown), for an
    ///   extension (prompt 38): the set is the attached packs, the **same
    ///   open instances**, plus every covering candidate not attached,
    ///   except a newer version of an attached pack (same pack name,
    ///   `packIdentity`, another content hash), which waits for the next
    ///   start.
    ///
    /// The outcome, in this order: `unusableRequest` (no usable circle),
    /// `noPacks` (no verified candidate), `noneCovering`; with a network
    /// attached, `noNewPacks` (every covering pack is attached) or
    /// `notSuperset` (the only new covering packs are newer versions of
    /// attached ones: `packs` names them); then `refused` (known, or the
    /// network cannot be built), else `selected` with the network
    /// (`packs`: the whole set, attached ones first).
    public static func attempt(_ candidates: [Candidate], refusedAtScan: [Refusal] = [], request: RoadSelectionRequest,
                               knownRefusals: [Refusal] = [], attached: RoadNetwork? = nil,
                               attachedNames: [String] = []) -> RoadSelectionAttempt {
        let chosen = covering(candidates, latitude: request.latitude, longitude: request.longitude,
                              radiusM: request.radiusM)
        let covered = Set(chosen ?? [])
        var listed = candidates.indices.map { i in
            NavSidecar.RoadsSelection.Candidate(name: candidates[i].name, state: .verified, covering: covered.contains(i))
        }
        for refusal in refusedAtScan {
            for name in refusal.names {
                listed.append(NavSidecar.RoadsSelection.Candidate(name: name, state: .refused, reason: refusal.reason))
            }
        }
        func made(_ outcome: NavSidecar.RoadsSelection.Outcome, network: RoadNetwork? = nil, packs: [String]? = nil,
                  reason: String? = nil) -> RoadSelectionAttempt {
            RoadSelectionAttempt(request: request, candidates: listed, outcome: outcome, network: network,
                                 packs: packs, reason: reason)
        }
        guard let chosen else { return made(.unusableRequest) }
        guard !candidates.isEmpty else { return made(.noPacks) }
        guard !chosen.isEmpty else { return made(.noneCovering) }
        if let attached {
            let labels = attachedNames.count == attached.packs.count
                ? attachedNames : attached.packs.map { NavigationSeed.hex($0.contentHash) }
            let hashes = Set(attached.packs.map(\.contentHash))
            let identities = Set(labels.map(packIdentity))
            let new = chosen.filter { !hashes.contains(candidates[$0].pack.contentHash) }
            let updates = new.filter { identities.contains(packIdentity(candidates[$0].name)) }
            let additions = new.filter { !identities.contains(packIdentity(candidates[$0].name)) }
            guard !additions.isEmpty else {
                if updates.isEmpty { return made(.noNewPacks, packs: labels) }
                return made(.notSuperset, packs: updates.map { candidates[$0].name },
                            reason: "newer versions of attached packs: used from the next start")
            }
            let names = labels + additions.map { candidates[$0].name }
            if let known = knownRefusals.first(where: { $0.names == names }) {
                return made(.refused, packs: known.names, reason: known.reason)
            }
            do {
                let network = try RoadNetwork(packs: attached.packs + additions.map { candidates[$0].pack })
                return made(.selected, network: network, packs: names)
            } catch {
                return made(.refused, packs: names, reason: String(describing: error))
            }
        }
        let names = chosen.map { candidates[$0].name }
        if let known = knownRefusals.first(where: { $0.names == names }) {
            return made(.refused, packs: known.names, reason: known.reason)
        }
        switch build(candidates, chosen) {
        case .selected(let network, let names): return made(.selected, network: network, packs: names)
        case .refused(let refusal): return made(.refused, packs: refusal.names, reason: refusal.reason)
        case .noneCovering, .unusableRequest: return made(.noneCovering)  // not reached: chosen is not empty
        }
    }

    /// A pack's identity across versions: the `<name>` of a store file name
    /// (`<name>-<contentHash>.roadpack`), else the whole name.
    public static func packIdentity(_ name: String) -> String {
        RoadPackStoreRules.parseFileName(name)?.name ?? name
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

/// One road selection attempt (`RoadPackSelection.attempt`): what was
/// decided off the run, and the `roadsSelection` line it becomes. Hand it
/// to `LiveNavigationRun.finishSelection(_:emit:)`, which attaches the
/// network of a `selected` attempt and writes the line unless it repeats
/// the last one written (then it is counted; an attach's line is always
/// written, and the `roads` line after it).
public struct RoadSelectionAttempt: Sendable {
    public let request: RoadSelectionRequest
    /// The line's `candidates`.
    public let candidates: [NavSidecar.RoadsSelection.Candidate]
    /// Never `unfinished` (that is `NavSidecar.RoadsSelection(unfinished:recordedAfterInputs:)`).
    public let outcome: NavSidecar.RoadsSelection.Outcome
    /// The covering packs' network, for `selected` only.
    public let network: RoadNetwork?
    /// The pack names involved, for `selected` and `refused`.
    public let packs: [String]?
    /// Why, for `refused`.
    public let reason: String?

    public init(request: RoadSelectionRequest, candidates: [NavSidecar.RoadsSelection.Candidate],
                outcome: NavSidecar.RoadsSelection.Outcome, network: RoadNetwork?, packs: [String]?, reason: String?) {
        self.request = request
        self.candidates = candidates
        self.outcome = outcome
        self.network = network
        self.packs = packs
        self.reason = reason
    }

    /// The line as decided, recorded after `recordedAfterInputs` inputs.
    /// (A `selected` attempt whose attach the run refuses is recorded by
    /// `LiveNavigationRun.finishSelection` as `refused`.)
    public func line(recordedAfterInputs: Int) -> NavSidecar.RoadsSelection {
        NavSidecar.RoadsSelection(t: request.t, afterInputs: request.afterInputs,
                                  recordedAfterInputs: recordedAfterInputs,
                                  request: NavSidecar.RoadsSelection.Request(radiusM: request.radiusM),
                                  candidates: candidates, outcome: outcome, packs: packs, reason: reason,
                                  trigger: request.trigger)
    }
}

/// A synchronous selector over fixed candidates (`replay_nav --as-live
/// --roads`, tests; the app runs the same `RoadPackSelection.attempt` off
/// its actor): at each request it selects the covering packs and returns
/// the attempt, with their network if selected. A set already refused (a
/// failed build, or an attach refused and passed to `remember`) is not
/// built again; its refusal is returned again.
public struct RoadPackSelector: Sendable {
    public private(set) var candidates: [RoadPackSelection.Candidate]
    /// Files refused before selection; listed in each attempt's line.
    public let refusedAtScan: [RoadPackSelection.Refusal]
    /// The latest attempt (diagnostics); nil before the first request.
    public private(set) var lastAttempt: RoadSelectionAttempt?
    /// Requests answered so far.
    public private(set) var requests = 0
    /// Pack sets refused so far.
    public private(set) var knownRefusals: [RoadPackSelection.Refusal] = []

    public init(candidates: [RoadPackSelection.Candidate], refusedAtScan: [RoadPackSelection.Refusal] = []) {
        self.candidates = candidates
        self.refusedAtScan = refusedAtScan
    }

    /// The latest outcome (diagnostics); nil before the first request.
    public var lastOutcome: RoadPackSelection.Outcome? {
        guard let attempt = lastAttempt else { return nil }
        switch attempt.outcome {
        case .selected:
            if let network = attempt.network { return .selected(network, names: attempt.packs ?? []) }
            return nil
        case .refused: return .refused(RoadPackSelection.Refusal(names: attempt.packs ?? [], reason: attempt.reason ?? ""))
        case .unusableRequest: return .unusableRequest
        default: return .noneCovering
        }
    }

    /// The candidates as the coverage trigger watches them.
    public var watchedPacks: [RoadCoverageWatch.Pack] { candidates.map(RoadCoverageWatch.Pack.init) }

    /// More packs become selectable (`replay_nav --inject-roads`: a pack
    /// installed during the run). A candidate whose content hash is already
    /// there is not added twice. Candidates stay in file-name order when
    /// every one is named by file (`ReplayRoadSet.selector`).
    public mutating func add(_ more: [RoadPackSelection.Candidate], sortByName: Bool) {
        let known = Set(candidates.map(\.pack.contentHash))
        candidates += more.filter { !known.contains($0.pack.contentHash) }
        if sortByName { candidates.sort { $0.name < $1.name } }
    }

    /// The attempt for `request`; with `attached`, an extension of that
    /// network (`RoadPackSelection.attempt`). A refused set is remembered.
    public mutating func attempt(for request: RoadSelectionRequest, attached: RoadNetwork? = nil,
                                 attachedNames: [String] = []) -> RoadSelectionAttempt {
        requests += 1
        let attempt = RoadPackSelection.attempt(candidates, refusedAtScan: refusedAtScan, request: request,
                                                knownRefusals: knownRefusals, attached: attached,
                                                attachedNames: attachedNames)
        if attempt.outcome == .refused, let packs = attempt.packs, let reason = attempt.reason {
            remember(RoadPackSelection.Refusal(names: packs, reason: reason))
        }
        lastAttempt = attempt
        return attempt
    }

    /// The network to attach for `request`, or nil (`attempt(for:)`).
    public mutating func network(for request: RoadSelectionRequest) -> RoadNetwork? {
        attempt(for: request).network
    }

    /// A refused set (an attach the run refused): not built again.
    public mutating func remember(_ refusal: RoadPackSelection.Refusal) {
        guard !knownRefusals.contains(where: { $0.names == refusal.names }) else { return }
        knownRefusals.append(refusal)
    }
}
