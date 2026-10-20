import Foundation

// Roads attached to a running engine (N3.3, docs/N3_PLAN.md "N3.3",
// amendment of 2026-10-15): why an attach is refused, the request that asks
// the caller to select packs, and the rule that raises it. The app, the
// as-live replay and the tests share this rule, so a run with a synchronous
// selector attaches at the same input in each.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.

/// Why `NavigationEngine.attachRoads(_:)` left the engine unchanged.
public enum RoadAttachRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// The engine already has a road network; it keeps it for the run
    /// (`attachRoads`; a larger set goes through `extendRoads`).
    case alreadyAttached
    /// `config.validated(roads:)` with this network would change these
    /// keys (sorted); the config never changes mid-run.
    case configWouldChange(keys: [String])
    /// `extendRoads` with no network attached (use `attachRoads`).
    case notAttached
    /// `extendRoads` with a network that is not a strict superset of the
    /// attached one: these attached packs (content hashes, 16 hex digits,
    /// sorted) are missing from it, or none (it adds nothing). A network is
    /// never detached or replaced mid-run.
    case notSuperset(missing: [String])

    public var description: String {
        switch self {
        case .alreadyAttached:
            "the engine already has a road network"
        case .configWouldChange(let keys):
            "these packs would change the validated config (keys: \(keys.joined(separator: ", "))); "
                + "the config never changes mid-run"
        case .notAttached:
            "no road network is attached to extend"
        case .notSuperset(let missing):
            missing.isEmpty
                ? "the packs add nothing to the attached set"
                : "the packs do not include the attached \(missing.joined(separator: ", ")); "
                    + "a network is never replaced mid-run"
        }
    }
}

/// Why a run asked for road packs beyond the N3.3 rule (prompt 38). An open
/// string set, written as the `roadsSelection` line's optional `trigger`;
/// nil for the N3.3 rule (the engine initialised, or used a position while
/// no network was attached).
public struct RoadSelectionTrigger: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The set of verified packs changed (a download, a removal) while the
    /// run was going: `LiveNavigationRun.libraryChanged(_:)`.
    public static let libraryChanged = RoadSelectionTrigger(rawValue: "libraryChanged")
    /// The estimate's circle started to intersect a verified pack the run
    /// has not attached (`RoadCoverageWatch`).
    public static let coverageEntered = RoadSelectionTrigger(rawValue: "coverageEntered")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A request to select road packs for a run: where the engine believes it
/// is, and how uncertain it is. Raised by `RoadSelectionRule`.
public struct RoadSelectionRequest: Hashable, Sendable {
    /// The estimate's centre, WGS-84 degrees.
    public var latitude: Double
    public var longitude: Double
    /// The estimate's 95 % ellipse semi-major axis, metres.
    public var radiusM: Double
    /// Inputs handed to the run when the request was raised (its
    /// `LiveNavigationRun.inputs`): attaching right away attaches after
    /// this many inputs.
    public var afterInputs: Int
    /// The engine's latest accepted arrival when it was raised.
    public var t: MonotonicTimestamp
    /// Why, beyond the N3.3 rule; nil for it.
    public var trigger: RoadSelectionTrigger?

    public init(latitude: Double, longitude: Double, radiusM: Double, afterInputs: Int, t: MonotonicTimestamp,
                trigger: RoadSelectionTrigger? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusM = radiusM
        self.afterInputs = afterInputs
        self.t = t
        self.trigger = trigger
    }

    /// The engine's estimate at its latest accepted arrival, after
    /// `inputs` inputs; nil before initialisation.
    public init?(_ engine: NavigationEngine, inputs: Int, trigger: RoadSelectionTrigger? = nil) {
        guard engine.isInitialized, let t = engine.latestArrival, let estimate = engine.estimate(at: t) else {
            return nil
        }
        self.init(latitude: estimate.latitude, longitude: estimate.longitude, radiusM: estimate.ellipse.semiMajorM,
                  afterInputs: inputs, t: t, trigger: trigger)
    }
}

/// When a run asks for road packs (N3.3 amendment, "Pack selection"):
/// - after the ingest at which the engine first initialises;
/// - while no network is attached, after every later ingest in which the
///   engine used a position: a location fix (`counters.fixesUsed`, a held
///   stale fix released by an OBD reply included) or a manual fix
///   (`counters.manualFixes`);
/// - once a network is attached, not for these (a manual reset of the cloud
///   included).
///
/// Prompt 38 adds two triggers, with or without a network, both driven by
/// the inputs and the watched packs only, so a replay given the same packs
/// at the same inputs decides the same:
/// - `libraryChanged(_:engine:inputs:)`: the verified packs changed (the
///   caller says so between two inputs); a request at once
///   (`RoadSelectionTrigger.libraryChanged`) if the engine is initialised;
/// - coverage entered (`RoadCoverageWatch`): after an ingest that raised no
///   other request, at most once per whole second of the latest arrival,
///   when the estimate's circle intersects a watched pack that is not
///   attached and did not at the previous check
///   (`RoadSelectionTrigger.coverageEntered`). Edge-triggered: a pack that
///   stays intersecting raises nothing more. Without watched packs (or with
///   every one attached) nothing is computed at all.
///
/// The request is the engine's estimate at its latest accepted arrival:
/// the centre and the 95 % semi-major axis.
public struct RoadSelectionRule: Hashable, Sendable {
    /// What the rule needs from the engine before an ingest.
    public struct Before: Hashable, Sendable {
        var initialized: Bool
        var fixesUsed: Int
        var manualFixes: Int

        public init(_ engine: NavigationEngine) {
            initialized = engine.isInitialized
            fixesUsed = engine.counters.fixesUsed
            manualFixes = engine.counters.manualFixes
        }
    }

    /// The latest request; nil before the first one and after an attach or
    /// an extension (until the next request).
    public private(set) var request: RoadSelectionRequest?
    /// The packs the coverage trigger watches.
    public private(set) var watch = RoadCoverageWatch()

    public init() {}

    /// After an ingest: the request this ingest raised, or nil. `inputs`:
    /// inputs handed to the run so far, this one included.
    public mutating func observe(_ engine: NavigationEngine, before: Before, inputs: Int) -> RoadSelectionRequest? {
        guard engine.isInitialized else { return nil }
        if engine.roadNetwork == nil {
            let firstInitialisation = !before.initialized
            let usedPosition = engine.counters.fixesUsed != before.fixesUsed
                || engine.counters.manualFixes != before.manualFixes
            if firstInitialisation || usedPosition {
                guard let raised = RoadSelectionRequest(engine, inputs: inputs) else { return nil }
                request = raised
                watch.prime(raised, engine: engine)
                return raised
            }
        }
        guard let raised = watch.observe(engine, inputs: inputs) else { return nil }
        request = raised
        return raised
    }

    /// The packs to watch from now on (a library scan), with no request.
    /// With an initialised `engine`, the packs its estimate's circle
    /// intersects now count as seen: they were there for the selection
    /// that already ran (the app's first sync can come after the first
    /// request), so they do not raise `coverageEntered` at the next check.
    public mutating func setWatchedPacks(_ packs: [RoadCoverageWatch.Pack], engine: NavigationEngine? = nil) {
        watch.setPacks(packs)
        if let engine, let now = RoadSelectionRequest(engine, inputs: 0) { watch.prime(now, engine: engine) }
    }

    /// The verified packs changed, between two inputs (`inputs` handed to
    /// the run so far): they are watched from now on, and a request
    /// (`libraryChanged`) is raised at once; nil before initialisation.
    public mutating func libraryChanged(_ packs: [RoadCoverageWatch.Pack], engine: NavigationEngine,
                                        inputs: Int) -> RoadSelectionRequest? {
        watch.setPacks(packs)
        guard let raised = RoadSelectionRequest(engine, inputs: inputs, trigger: .libraryChanged) else { return nil }
        request = raised
        watch.prime(raised, engine: engine)
        return raised
    }

    /// A network was attached or extended: no request is pending.
    public mutating func attached() {
        request = nil
    }
}

/// The coverage trigger (prompt 38): which watched packs the estimate's
/// circle intersected at the last check. Cheap: a pack is tested exactly
/// (`RoadPackCoverage.intersects`, the selection's own test) only when the
/// circle reaches its bounding box, attached packs are never tested, and
/// nothing runs while every watched pack is attached.
public struct RoadCoverageWatch: Hashable, Sendable {
    /// A pack the trigger watches: its name (for reports), content hash and
    /// coverage, and the coverage's bounding box.
    public struct Pack: Hashable, Sendable {
        public let name: String
        public let contentHash: UInt64
        public let coverage: RoadPackCoverage
        /// The rings' (else the bounds') box; nil: covers nothing.
        let box: RoadPackBounds?

        public init(name: String, contentHash: UInt64, coverage: RoadPackCoverage) {
            self.name = name
            self.contentHash = contentHash
            self.coverage = coverage
            if let rings = coverage.rings {
                var south = Int32.max, west = Int32.max, north = Int32.min, east = Int32.min
                for ring in rings {
                    for p in ring {
                        south = min(south, p.latE7)
                        north = max(north, p.latE7)
                        west = min(west, p.lonE7)
                        east = max(east, p.lonE7)
                    }
                }
                box = south <= north ? RoadPackBounds(southLatE7: south, westLonE7: west, northLatE7: north,
                                                      eastLonE7: east) : nil
            } else {
                box = coverage.bounds
            }
        }

        public init(_ candidate: RoadPackSelection.Candidate) {
            self.init(name: candidate.name, contentHash: candidate.pack.contentHash, coverage: candidate.coverage)
        }

        /// Whether the circle can reach the box: the distance from the
        /// centre to the box's nearest point is within the radius, widened
        /// by 10 % and 100 m so the exact test is never skipped where it
        /// would intersect.
        func mayIntersect(latitude: Double, longitude: Double, radiusM: Double) -> Bool {
            guard let b = box else { return false }
            let lat = min(max(latitude * 1e7, Double(b.southLatE7)), Double(b.northLatE7)) / 1e7
            let lon = min(max(longitude * 1e7, Double(b.westLonE7)), Double(b.eastLonE7)) / 1e7
            if lat == latitude && lon == longitude { return true }
            let p = LocalTangentPlane(latitude: latitude, longitude: longitude).enu(latitude: lat, longitude: lon)
            return (p.east * p.east + p.north * p.north).squareRoot() <= radiusM * 1.1 + 100
        }

        func intersects(_ request: RoadSelectionRequest) -> Bool {
            mayIntersect(latitude: request.latitude, longitude: request.longitude, radiusM: request.radiusM)
                && coverage.intersects(latitude: request.latitude, longitude: request.longitude, radiusM: request.radiusM)
        }
    }

    public private(set) var packs: [Pack] = []
    /// Content hashes of the watched, unattached packs the circle
    /// intersected at the last check (or request).
    public private(set) var inside: Set<UInt64> = []
    /// The whole second (of the latest arrival) of the last check.
    private var lastCheckSecond: Int64?
    /// Checks run (each computed an estimate); for tests.
    public private(set) var checks = 0

    public init() {}

    /// Watches `packs` from now on; `inside` keeps the packs still watched.
    mutating func setPacks(_ packs: [Pack]) {
        self.packs = packs
        let hashes = Set(packs.map(\.contentHash))
        inside = inside.intersection(hashes)
    }

    private func unattached(_ engine: NavigationEngine) -> [Pack] {
        guard let network = engine.roadNetwork else { return packs }
        let attached = Set(network.packs.map(\.contentHash))
        return packs.filter { !attached.contains($0.contentHash) }
    }

    private func covering(_ request: RoadSelectionRequest, among packs: [Pack]) -> Set<UInt64> {
        Set(packs.filter { $0.intersects(request) }.map(\.contentHash))
    }

    /// A request was raised for another reason: the packs its circle
    /// intersects count as seen (they are being selected now).
    mutating func prime(_ request: RoadSelectionRequest, engine: NavigationEngine) {
        let open = unattached(engine)
        guard !open.isEmpty else { return }
        lastCheckSecond = NavigationEngine.floorToGrid(request.t.nanoseconds, 1_000_000_000)
        inside = covering(request, among: open)
    }

    /// After an ingest that raised no other request: a `coverageEntered`
    /// request when the circle now intersects an unattached watched pack it
    /// did not at the previous check; at most one check per whole second.
    mutating func observe(_ engine: NavigationEngine, inputs: Int) -> RoadSelectionRequest? {
        guard !packs.isEmpty, let t = engine.latestArrival else { return nil }
        let open = unattached(engine)
        guard !open.isEmpty else { return nil }
        let second = NavigationEngine.floorToGrid(t.nanoseconds, 1_000_000_000)
        guard second != lastCheckSecond else { return nil }
        lastCheckSecond = second
        guard let candidate = RoadSelectionRequest(engine, inputs: inputs, trigger: .coverageEntered) else { return nil }
        return check(candidate, among: open) ? candidate : nil
    }

    /// One check of `request`'s circle against `open` (the unattached
    /// watched packs): whether it entered one it was not in at the last
    /// check. Updates `inside`.
    mutating func check(_ request: RoadSelectionRequest, among open: [Pack]) -> Bool {
        checks += 1
        let now = covering(request, among: open)
        let entered = !now.isSubset(of: inside)
        inside = now
        return entered
    }
}

/// A network attached to a run (`LiveNavigationRun.roads`): when, and the
/// network.
public struct RoadAttachment: Sendable {
    public let network: RoadNetwork
    /// Inputs handed to the run before the attach (`LiveNavigationRun.inputs`
    /// then): the network is used from input number `afterInputs + 1` on.
    /// 0: attached before the first input.
    public let afterInputs: Int
    /// The engine's latest accepted arrival at the attach
    /// (`NavigationEngine.latestArrival`): the arrival of the last input
    /// ingested before it, unless that input was rejected as an implausible
    /// time jump, which does not move it. nil when `afterInputs` is 0.
    public let t: MonotonicTimestamp?

    public init(network: RoadNetwork, afterInputs: Int, t: MonotonicTimestamp?) {
        self.network = network
        self.afterInputs = afterInputs
        self.t = t
    }
}
