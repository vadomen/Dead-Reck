import Foundation

/// Prompt 50, observe-only: how far each location fix the engine considers
/// lies from the estimate, as a squared Mahalanobis distance M², and which
/// path then handled the fixes over a threshold. Nothing here feeds back
/// into the engine: it reads the state, never writes it, and draws no
/// random number, so a run with the observation on is bit-identical to one
/// with it off (`NavigationEngine.fixJumps` nil, the default; the app never
/// turns it on). `replay_nav` turns it on and reports it in `metrics.json`
/// and the run summary only: not in the sidecar, the log or the app.
///
/// Measured fixes: those `ingestLocation` gets past every filter (invalid,
/// older than the restored save, stale or held, and the GPS switch, which
/// withholds before `ingestLocation`) while a position estimate exists
/// (the engine is initialised, including from an unconfirmed restored
/// prior), before any path acts on the fix: the restore judge, the road
/// fix gate, a reseed, the N3-FIXPIN win-back and the update itself.
///
/// M² = rᵀ (P + R)⁻¹ r, with
/// - r: the fix shifted to now by the cloud's motion since its `t` (the
///   update's target) minus the cloud's weighted mean;
/// - P: the cloud's mixture covariance (weighted per-particle covariance
///   plus the spread of the particle means), the one the restore judge
///   uses: the predictive covariance of the estimate as a whole;
/// - R: what the ordinary update would use for this fix, from the state
///   before it: σ² (the fix's σ: accuracy scale and floor, network
///   inflation, stale growth) divided by the likelihood temper, which is
///   the network temper (time since the previous network fix over
///   `networkFixCorrelationS`) for a network fix, the N3-FIXPIN temper with
///   σ raised to the source's offset × `fixPinInflation` for a GNSS fix
///   from a down-weighted source, and 1 otherwise. A temper of 0 (a
///   network fix not after the previous one) is an infinite R: M² 0.
/// `mahalanobis2Untempered` is the same with R = σ² (the restore judge's
/// form), for comparison.
///
/// Cost per measured fix: one pass over the particles for the cloud's
/// moments (the update itself makes one), O(1) memory: counts, the
/// maximum and a list capped at `listCap`.
public struct FixJumpObservation: Hashable, Sendable, Codable {
    /// What handled a fix after it was measured.
    public enum Path: String, Hashable, Sendable, Codable {
        /// The restore judge rejected the unconfirmed prior; the fix then
        /// initialised the engine as a first fix.
        case restoreRejected
        /// The road fix gate rejected it (no compatible road near it).
        case rejectedOffRoad
        /// A clean fix: part of the cloud was reseeded on it, then the update.
        case reseed
        /// N3-FIXPIN: a reseed was blocked (the source is down-weighted),
        /// then the down-weighted update.
        case reseedBlocked
        /// N3-FIXPIN: the update with the source down-weighted.
        case updateDownweighted
        /// The ordinary update.
        case update
    }

    /// One measured fix.
    public struct Hit: Hashable, Sendable, Codable {
        /// Arrival, session seconds: when the engine considered the fix.
        public var t: Double
        /// The fix's own `t`, session seconds.
        public var fixT: Double
        public var mahalanobis2: Double
        public var mahalanobis2Untempered: Double
        /// Distance from the estimate's mean to the shifted fix, metres.
        public var innovationM: Double
        /// The fix's claimed horizontal accuracy, metres.
        public var accuracyM: Double
        /// R's σ before tempering, metres, and the temper (1: none).
        public var sigmaM: Double
        public var temper: Double
        /// No valid Doppler speed: a cell-tower or Wi-Fi fix; else GNSS.
        public var network: Bool
        public var path: Path
        /// The restore judge's outcome when the restored prior was
        /// unconfirmed at the fix; nil when the judge did not run.
        public var restore: NavigationRestore.Status?
        /// The fix extended the run of moving fixes against the current
        /// run of OBD zeros (N4B1-1, the `zuptFixGate` evidence).
        public var zeroGateEvidence: Bool
    }

    /// M² above which a fix is a hit (strictly greater).
    public var chi2Threshold: Double
    /// Most hits kept in `list`; later hits are counted only.
    public var listCap: Int
    /// Fixes measured (every fix that reached a path with an estimate).
    public var fixesMeasured = 0
    /// Fixes with M² > `chi2Threshold`.
    public var hits = 0
    /// The measured fix with the largest M² (hit or not); nil before one.
    public var max: Hit?
    /// The first `listCap` hits, in the order measured.
    public var list: [Hit] = []

    public init(chi2Threshold: Double, listCap: Int) {
        self.chi2Threshold = chi2Threshold
        self.listCap = Swift.max(0, listCap)
    }

    /// Records a measured fix; returns whether it went to `max` and whether
    /// it was appended to `list`, so `resolve` can fill in its path.
    mutating func record(_ hit: Hit) -> (isMax: Bool, listed: Bool) {
        fixesMeasured += 1
        var isMax = false
        if hit.mahalanobis2 > (max?.mahalanobis2 ?? -.infinity) {
            max = hit
            isMax = true
        }
        guard hit.mahalanobis2 > chi2Threshold else { return (isMax, false) }
        hits += 1
        guard list.count < listCap else { return (isMax, false) }
        list.append(hit)
        return (isMax, true)
    }

    /// Fills in the path (and restore outcome) of the fix just recorded.
    mutating func resolve(isMax: Bool, listed: Bool, path: Path, restore: NavigationRestore.Status?) {
        if isMax {
            max?.path = path
            max?.restore = restore
        }
        if listed, !list.isEmpty {
            list[list.count - 1].path = path
            list[list.count - 1].restore = restore
        }
    }
}
