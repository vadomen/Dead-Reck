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
    /// The engine already has a road network; it keeps it for the run.
    case alreadyAttached
    /// `config.validated(roads:)` with this network would change these
    /// keys (sorted); the config never changes mid-run.
    case configWouldChange(keys: [String])

    public var description: String {
        switch self {
        case .alreadyAttached:
            "the engine already has a road network"
        case .configWouldChange(let keys):
            "these packs would change the validated config (keys: \(keys.joined(separator: ", "))); "
                + "the config never changes mid-run"
        }
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

    public init(latitude: Double, longitude: Double, radiusM: Double, afterInputs: Int, t: MonotonicTimestamp) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusM = radiusM
        self.afterInputs = afterInputs
        self.t = t
    }
}

/// When a run asks for road packs (N3.3 amendment, "Pack selection"):
/// - after the ingest at which the engine first initialises;
/// - while no network is attached, after every later ingest in which the
///   engine used a position: a location fix (`counters.fixesUsed`, a held
///   stale fix released by an OBD reply included) or a manual fix
///   (`counters.manualFixes`);
/// - never once a network is attached, including after a manual reset of
///   the cloud: the network stays for the run.
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

    /// The latest request; nil before the first one and once a network is
    /// attached.
    public private(set) var request: RoadSelectionRequest?

    public init() {}

    /// After an ingest: the request this ingest raised, or nil. `inputs`:
    /// inputs handed to the run so far, this one included.
    public mutating func observe(_ engine: NavigationEngine, before: Before, inputs: Int) -> RoadSelectionRequest? {
        guard engine.roadNetwork == nil else {
            request = nil
            return nil
        }
        guard engine.isInitialized else { return nil }
        let firstInitialisation = !before.initialized
        let usedPosition = engine.counters.fixesUsed != before.fixesUsed
            || engine.counters.manualFixes != before.manualFixes
        guard firstInitialisation || usedPosition, let t = engine.latestArrival,
              let estimate = engine.estimate(at: t) else { return nil }
        let raised = RoadSelectionRequest(latitude: estimate.latitude, longitude: estimate.longitude,
                                          radiusM: estimate.ellipse.semiMajorM, afterInputs: inputs, t: t)
        request = raised
        return raised
    }

    /// A network was attached: no request is raised again.
    public mutating func attached() {
        request = nil
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
