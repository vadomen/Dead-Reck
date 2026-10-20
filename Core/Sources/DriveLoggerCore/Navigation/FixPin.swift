import Foundation

/// One GNSS source's state for the pin-vs-fix arbitration (N3-FIXPIN,
/// docs/NAVIGATION.md "Pin against a GNSS source"): its recent fixes, and
/// whether it is down-weighted with an offset estimate. `NavigationEngine`
/// keeps one per `Kind`, in an array indexed by `Kind.rawValue` (never a
/// dictionary: iteration order must not reach a result), and only while
/// `roadFixPinCheck` or `fixPinTwoPinCheck` is on.
struct FixPinSource: Sendable {
    /// A GNSS source: a fix with a valid speed, split by
    /// `LocationSample.accessory`. Network fixes (no valid speed) belong to
    /// neither and are never judged.
    enum Kind: Int, CaseIterable, Sendable {
        case accessory = 0
        case phone = 1

        /// true: the accessory (CarPlay); false or nil: the phone.
        init(accessory: Bool?) { self = accessory == true ? .accessory : .phone }

        var name: String { self == .accessory ? "accessory" : "phone" }
    }

    /// A fix as received: its own position (not latency-shifted) in the
    /// engine plane, its course (plane frame, radians) when the engine
    /// would use it, and its claimed per-axis σ.
    struct Fix: Sendable {
        var ns: Int64
        var east: Double
        var north: Double
        var course: Double?
        var sigma: Double
        /// Inside the road packs' coverage; nil until a road check asks.
        var covered: Bool?
        /// The road arbiter's capped distances, cached: as given (A), and
        /// shifted by `FixPinSource.roadShift` (B). Pure functions of the
        /// fix, the shift, the plane and the packs, so a cached value is
        /// the value a new query would return; a re-anchor clears them.
        var roadA: Double?
        var roadB: Double?
    }

    /// An independent pin as this source's two-pin arbiter remembers it.
    struct Pin: Sendable {
        var ns: Int64
        /// Pin minus the prior mean, metres.
        var dEast: Double
        var dNorth: Double
        /// Prior covariance plus the pin's σ², m².
        var ee: Double
        var en: Double
        var nn: Double
        /// The engine's cumulative OBD distance (m) and gyro yaw (rad) at it.
        var obdM: Double
        var yaw: Double
    }

    /// The fixes of the last `fixPinWindowS`, oldest first.
    private(set) var ring: [Fix] = []
    /// Set while down-weighted: the offset estimate (pin minus prior mean),
    /// metres. nil: the source is used as claimed.
    var offset: (east: Double, north: Double)?
    /// The last fix of this source that reached the position update.
    var lastPositionNs: Int64?
    /// Win-back by agreement: start of the current run of agreeing fixes and
    /// its length.
    var agreeStartNs: Int64?
    var agreeCount = 0
    /// Win-back by roads: the last re-evaluation.
    var lastRoadCheckNs: Int64?
    /// The last independent pin evaluated against this source.
    var lastPin: Pin?
    /// The shift every cached `Fix.roadB` was computed with.
    var roadShift: (east: Double, north: Double)?

    var isDownweighted: Bool { offset != nil }

    mutating func append(_ fix: Fix, windowNs: Int64) {
        ring.append(fix)
        prune(before: fix.ns - windowNs)
    }

    /// Drops fixes older than `ns`.
    mutating func prune(before ns: Int64) {
        var k = 0
        while k < ring.count && ring[k].ns < ns { k += 1 }
        if k > 0 { ring.removeFirst(k) }
    }

    mutating func setCovered(_ index: Int, _ value: Bool) { ring[index].covered = value }

    /// Forgets fix `index`'s coverage: the packs changed (`extendRoads`).
    mutating func clearCovered(_ index: Int) { ring[index].covered = nil }

    /// Caches fix `index`'s road distances.
    mutating func setRoadDistances(_ index: Int, a: Double, b: Double) {
        ring[index].roadA = a
        ring[index].roadB = b
    }

    mutating func clearRoadDistances(_ index: Int) {
        ring[index].roadA = nil
        ring[index].roadB = nil
    }

    /// Forgets every cached B: the shift changes.
    mutating func setRoadShift(_ shift: (east: Double, north: Double)) {
        roadShift = shift
        for k in ring.indices { ring[k].roadB = nil }
    }

    /// After a re-anchor: positions through the exact plane map, the
    /// offset and the pin's vector and covariance through its Jacobian
    /// J = [[jee, jen], [jne, jnn]], courses as the engine maps headings.
    mutating func transform(map: (Double, Double) -> (Double, Double),
                            jee: Double, jen: Double, jne: Double, jnn: Double) {
        roadShift = nil
        for k in ring.indices {
            ring[k].roadA = nil
            ring[k].roadB = nil
            (ring[k].east, ring[k].north) = map(ring[k].east, ring[k].north)
            if let c = ring[k].course {
                let s = sin(c), co = cos(c)
                ring[k].course = NavigationEngine.wrap2Pi(atan2(jee * s + jen * co, jne * s + jnn * co))
            }
        }
        if let o = offset { offset = (jee * o.east + jen * o.north, jne * o.east + jnn * o.north) }
        if var p = lastPin {
            (p.dEast, p.dNorth) = (jee * p.dEast + jen * p.dNorth, jne * p.dEast + jnn * p.dNorth)
            let aee = jee * p.ee + jen * p.en, aen = jee * p.en + jen * p.nn
            let ane = jne * p.ee + jnn * p.en, ann = jne * p.en + jnn * p.nn
            (p.ee, p.en, p.nn) = (aee * jee + aen * jen, aee * jne + aen * jnn, ane * jne + ann * jnn)
            lastPin = p
        }
    }
}

/// What the engine decided at one manual fix about each GNSS source
/// (N3-FIXPIN): `NavigationEngine.lastFixPinDecision`, and the replay's
/// per-pin record. Relative metres and bearings only, never a position.
/// nil whenever both checks are off.
public struct FixPinDecision: Hashable, Sendable, Codable {
    public enum Verdict: String, Hashable, Sendable, Codable {
        /// The pin is right, the source is off: down-weight it.
        case pin
        /// The source is right, the pin is off: counted only.
        case fixes
    }

    /// The road arbiter over the source's recent fixes.
    public struct Road: Hashable, Sendable, Codable {
        /// Fixes inside pack coverage, and their path, metres.
        public var fixes: Int
        public var pathM: Double
        /// Mean capped distance to a heading-compatible road of the fixes
        /// as given (A) and shifted by the offset (B); nil with too few
        /// fixes or too short a path.
        public var asGivenM: Double?
        public var shiftedM: Double?
        public var verdict: Verdict?
    }

    /// The two-pin arbiter against the source's previous independent pin.
    public struct TwoPin: Hashable, Sendable, Codable {
        public var previousT: Double
        /// χ² (2 dof) of the difference of the two offsets.
        public var chi2: Double
        /// OBD distance and net gyro heading change between the pins.
        public var pathM: Double
        public var turnDeg: Double
        public var verdict: Verdict?
    }

    public struct Source: Hashable, Sendable, Codable {
        /// "accessory" or "phone".
        public var source: String
        public var fixesInWindow: Int
        /// Down-weighted when the pin arrived.
        public var wasDownweighted: Bool
        public var road: Road?
        public var twoPin: TwoPin?
        /// This pin down-weighted the source.
        public var downweighted: Bool = false
        /// Win-back by a pin: χ² of the pin against the source's newest fix
        /// (claimed σ² + pin σ²), and whether it restored the source.
        public var sourceChi2: Double?
        public var restored: Bool = false
    }

    /// The pin's `t`, session seconds.
    public var t: Double
    /// Within `NavigationEngine.fixPinRefinementWindowS` of the previous
    /// manual fix: not judged.
    public var refinement: Bool
    /// Pin minus the prior mean (east, north), metres, and its χ² (2 dof)
    /// against the prior covariance plus the pin's σ².
    public var offsetEastM: Double
    public var offsetNorthM: Double
    public var chi2: Double
    public var significant: Bool
    /// One entry per source with at least one fix in the window.
    public var sources: [Source]

    public var offsetM: Double { (offsetEastM * offsetEastM + offsetNorthM * offsetNorthM).squareRoot() }
    /// Degrees clockwise from north, [0, 360).
    public var offsetBearingDeg: Double {
        let b = atan2(offsetEastM, offsetNorthM) * 180 / .pi
        return b < 0 ? b + 360 : b
    }

    /// "fix-pin: offset 298 m @64°, χ² 9123 (significant); accessory 58 fixes:
    /// roads A 45.1 / B 6.2 m (58 fixes, 512 m) pin → down-weighted".
    public var text: String {
        func f0(_ v: Double) -> String { String(format: "%.0f", v) }
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        var parts = ["fix-pin: offset \(f0(offsetM)) m @\(f0(offsetBearingDeg))°, χ² \(f1(chi2))"
            + (refinement ? " (refinement, not judged)" : significant ? " (significant)" : " (not significant)")]
        if sources.isEmpty { parts.append("no GNSS source in the window") }
        for s in sources {
            var p = "\(s.source) \(s.fixesInWindow) fixes" + (s.wasDownweighted ? ", down-weighted" : "")
            if let r = s.road {
                p += ": roads "
                if let a = r.asGivenM, let b = r.shiftedM {
                    p += "A \(f1(a)) / B \(f1(b)) m (\(r.fixes) fixes, \(f0(r.pathM)) m) \(r.verdict?.rawValue ?? "none")"
                } else {
                    p += "too little (\(r.fixes) fixes, \(f0(r.pathM)) m)"
                }
            }
            if let w = s.twoPin {
                p += "; two-pin vs t \(f1(w.previousT)) s: χ² \(f1(w.chi2)), \(f0(w.pathM)) m, turn \(f0(w.turnDeg))° "
                    + (w.verdict?.rawValue ?? "none")
            }
            if let c = s.sourceChi2 { p += "; pin vs newest fix χ² \(f1(c))" }
            if s.downweighted { p += " → down-weighted" }
            if s.restored { p += " → restored" }
            parts.append(p)
        }
        return parts.joined(separator: "; ")
    }
}
