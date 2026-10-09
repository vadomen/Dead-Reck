import Foundation

/// `replay_nav --compare`: a sidecar the app wrote against the lines a
/// replay produces for the same recording (`NavigationReplay.liveLines`),
/// matched by `t` (R13.1-7).
///
/// Exact equality is the expectation when the replay runs as live (file
/// order, the header's seed, the same config) on hardware that gives the
/// same floating-point bits. Whether an arm64 Mac and an iPhone do is
/// verified on the device (docs/PLAN.md §6); until then a difference within
/// `Tolerance` passes, and the report says it was not exact. Known sources
/// of a real difference, reported alongside: inputs the live feed dropped
/// (`droppedInputs`) and navigation rows that failed to encode
/// (`encodingFailures`).
public struct SidecarComparison: Hashable, Sendable {
    /// Largest acceptable differences for a non-exact pass.
    public struct Tolerance: Hashable, Sendable {
        /// Position and ellipse semi-axes, metres.
        public var metres: Double
        /// Heading and heading std, degrees.
        public var degrees: Double

        public init(metres: Double, degrees: Double) {
            self.metres = metres
            self.degrees = degrees
        }

        /// `replay_nav`'s default: 1 m and 0.1°, far below what the map
        /// can show and far above floating-point noise that stayed noise.
        /// A filter whose resampling diverged differs by much more.
        public static let `default` = Tolerance(metres: 1, degrees: 0.1)
    }

    /// The largest differences over a set of matched estimates.
    public struct Differences: Hashable, Sendable {
        /// Matched by `t`.
        public var matched = 0
        public var positionM = 0.0
        public var headingDeg = 0.0
        public var headingStdDeg = 0.0
        /// Semi-major and semi-minor axes, metres.
        public var ellipseAxesM = 0.0
        /// Ellipse orientation, degrees (reported, not gated: it is
        /// ill-conditioned for a near-circular ellipse).
        public var ellipseOrientationDeg = 0.0
        public var speedScale = 0.0
        /// Estimates whose `converged` flag differs.
        public var convergedMismatches = 0
        /// Estimates that differ in any compared field, bit for bit.
        public var unequal = 0
        /// The first `t` at which any compared field differs.
        public var firstDifferenceT: MonotonicTimestamp?
        /// Where the largest position difference is.
        public var worstPositionT: MonotonicTimestamp?

        mutating func add(_ live: NavSidecar.Estimate, _ replay: NavSidecar.Estimate, at t: MonotonicTimestamp) {
            matched += 1
            let plane = LocalTangentPlane(latitude: live.latitude, longitude: live.longitude)
            let p = plane.enu(latitude: replay.latitude, longitude: replay.longitude)
            let distance = (p.east * p.east + p.north * p.north).squareRoot()
            if distance > positionM || (distance.isNaN && !positionM.isNaN) {
                positionM = distance
                worstPositionT = t
            }
            headingDeg = max(headingDeg, Self.angle(live.headingDeg, replay.headingDeg, period: 360))
            headingStdDeg = max(headingStdDeg, abs(live.headingStdDeg - replay.headingStdDeg))
            ellipseAxesM = max(ellipseAxesM, abs(live.semiMajorM - replay.semiMajorM),
                               abs(live.semiMinorM - replay.semiMinorM))
            ellipseOrientationDeg = max(ellipseOrientationDeg,
                                        Self.angle(live.orientationDeg, replay.orientationDeg, period: 180))
            speedScale = max(speedScale, abs(live.speedScale - replay.speedScale))
            if live.converged != replay.converged { convergedMismatches += 1 }
            if !Self.bitEqual(live, replay) {
                unequal += 1
                if firstDifferenceT == nil { firstDifferenceT = t }
            }
        }

        static func angle(_ a: Double, _ b: Double, period: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: period)
            if d > period / 2 { d = period - d }
            return d
        }

        /// Every compared field identical (timing and drops excluded).
        static func bitEqual(_ a: NavSidecar.Estimate, _ b: NavSidecar.Estimate) -> Bool {
            a.t == b.t && a.latitude.bitPattern == b.latitude.bitPattern
                && a.longitude.bitPattern == b.longitude.bitPattern
                && a.headingDeg.bitPattern == b.headingDeg.bitPattern
                && a.headingStdDeg.bitPattern == b.headingStdDeg.bitPattern
                && a.semiMajorM.bitPattern == b.semiMajorM.bitPattern
                && a.semiMinorM.bitPattern == b.semiMinorM.bitPattern
                && a.orientationDeg.bitPattern == b.orientationDeg.bitPattern
                && a.converged == b.converged
                && a.speedScale.bitPattern == b.speedScale.bitPattern
        }

        /// Every gated difference within `tolerance` (NaN never is).
        func within(_ tolerance: Tolerance) -> Bool {
            positionM <= tolerance.metres && ellipseAxesM <= tolerance.metres
                && headingDeg <= tolerance.degrees && headingStdDeg <= tolerance.degrees
                && convergedMismatches == 0
        }
    }

    /// Over the 1 Hz estimates.
    public var estimates = Differences()
    /// Over the pins' priors.
    public var pins = Differences()
    /// Estimates (by `t`) only in the sidecar, and only in the replay.
    public var sidecarOnly = 0
    public var replayOnly = 0
    /// Pins only in the sidecar or only in the replay (matched by `t`), and
    /// pins whose prior is present in one and absent in the other.
    public var pinsUnmatched = 0
    /// The sidecar's `droppedInputs` at its end.
    public var droppedInputs: Int
    /// Whether the sidecar's last line was cut short and dropped.
    public var truncatedLastLine: Bool
    /// The sidecar's config hash differs from the replay's.
    public var configHashMismatch: Bool
    /// Config keys whose values differ (sidecar vs replay), sorted.
    public var configDifferences: [String]
    /// The sidecar's seed differs from the replay's.
    public var seedMismatch: Bool
    /// Navigation rows that failed to encode (see type doc).
    public var encodingFailures: Int

    /// Nothing differs: every estimate and pin matched bit for bit, none
    /// missing on either side.
    public var exact: Bool {
        estimates.unequal == 0 && pins.unequal == 0 && sidecarOnly == 0 && replayOnly == 0 && pinsUnmatched == 0
            && estimates.matched > 0
    }

    /// Exact, or every difference within `tolerance` with nothing missing.
    public func passes(_ tolerance: Tolerance) -> Bool {
        exact || (estimates.matched > 0 && sidecarOnly == 0 && replayOnly == 0 && pinsUnmatched == 0
                  && estimates.within(tolerance) && pins.within(tolerance))
    }

    /// Compares `sidecar` with `replay` (header line optional, ignored).
    public init(sidecar: NavSidecar.Contents, replay: [NavSidecar.Line], replayConfig: NavigationConfig,
                encodingFailures: Int = 0) {
        droppedInputs = sidecar.droppedInputs
        truncatedLastLine = sidecar.truncatedLastLine
        configHashMismatch = sidecar.header.configHash != replayConfig.hashHex
        configDifferences = Self.configDifferences(sidecar.header.configJSON,
                                                   String(decoding: replayConfig.canonicalJSON(), as: UTF8.self))
        seedMismatch = sidecar.header.seed != replayConfig.seed
        self.encodingFailures = encodingFailures

        var replayEstimates: [MonotonicTimestamp: NavSidecar.Estimate] = [:]
        var replayPins: [MonotonicTimestamp: [NavSidecar.Pin]] = [:]
        for line in replay {
            switch line {
            case .estimate(let e): replayEstimates[e.t] = e
            case .pin(let p): replayPins[p.t, default: []].append(p)
            default: break
            }
        }
        var seen = Set<MonotonicTimestamp>()
        for live in sidecar.estimates {
            seen.insert(live.t)
            guard let replayed = replayEstimates[live.t] else {
                sidecarOnly += 1
                continue
            }
            estimates.add(live, replayed, at: live.t)
        }
        replayOnly = replayEstimates.keys.filter { !seen.contains($0) }.count

        var used: [MonotonicTimestamp: Int] = [:]
        for live in sidecar.pins {
            let index = used[live.t, default: 0]
            guard let candidates = replayPins[live.t], index < candidates.count else {
                pinsUnmatched += 1
                continue
            }
            used[live.t] = index + 1
            let replayed = candidates[index]
            switch (live.prior, replayed.prior) {
            case let (a?, b?): pins.add(a, b, at: live.t)
            case (nil, nil): pins.matched += 1
            default: pinsUnmatched += 1
            }
        }
        pinsUnmatched += replayPins.reduce(0) { $0 + max(0, $1.value.count - used[$1.key, default: 0]) }
    }

    /// Keys of two config JSON objects whose values differ (or are present
    /// in only one), sorted. Values compare as their JSON text.
    static func configDifferences(_ a: String, _ b: String) -> [String] {
        func object(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        let x = object(a), y = object(b)
        return Set(x.keys).union(y.keys).filter { key in
            switch (x[key], y[key]) {
            case let (u?, v?): return "\(u)" != "\(v)"
            default: return true
            }
        }.sorted()
    }

    /// Human-readable report: one block for `replay_nav`.
    public func report(tolerance: Tolerance) -> String {
        func row(_ name: String, _ d: Differences) -> String {
            name + String(format: " %d matched: position %.6g m, heading %.6g°, heading σ %.6g°, ellipse axes %.6g m, ellipse orientation %.6g°, speed scale %.3g, converged mismatches %d, unequal %d",
                   d.matched, d.positionM, d.headingDeg, d.headingStdDeg, d.ellipseAxesM,
                   d.ellipseOrientationDeg, d.speedScale, d.convergedMismatches, d.unequal)
                + (d.firstDifferenceT.map { String(format: ", first difference at t %.1f s", $0.seconds) } ?? "")
                + (d.worstPositionT.map { d.positionM > 0 ? String(format: ", largest position difference at t %.1f s", $0.seconds) : "" } ?? "")
        }
        var lines: [String] = []
        lines.append(row("Estimates    ", estimates))
        lines.append(row("Pins         ", pins))
        lines.append("Unmatched     estimates only in sidecar \(sidecarOnly), only in replay \(replayOnly); pins \(pinsUnmatched)")
        lines.append("Dropped       \(droppedInputs) navigation input(s) dropped by the live feed")
        if encodingFailures > 0 {
            lines.append("Encoding      \(encodingFailures) navigation row(s) failed to encode: the live engine saw them, the file does not hold them")
        }
        if truncatedLastLine { lines.append("Note          the sidecar's last line was cut short and ignored") }
        if seedMismatch { lines.append("Warning       seed differs from the sidecar's (use --as-live or --seed header)") }
        if configHashMismatch {
            lines.append("Warning       config hash differs from the sidecar's; keys: "
                         + (configDifferences.isEmpty ? "(none parsed)" : configDifferences.joined(separator: ", ")))
        }
        let verdict: String
        if exact {
            verdict = "PASS (exact: every estimate and pin identical)"
        } else if passes(tolerance) {
            verdict = String(format: "PASS within tolerance (%.3g m, %.3g°), not exact", tolerance.metres, tolerance.degrees)
        } else {
            verdict = String(format: "FAIL (tolerance %.3g m, %.3g°)", tolerance.metres, tolerance.degrees)
        }
        var explanation = ""
        if !exact {
            var causes: [String] = []
            if droppedInputs > 0 { causes.append("\(droppedInputs) dropped input(s)") }
            if encodingFailures > 0 { causes.append("\(encodingFailures) row(s) that failed to encode") }
            if seedMismatch || configHashMismatch { causes.append("a different seed or config") }
            if truncatedLastLine { causes.append("a truncated last line") }
            explanation = causes.isEmpty
                ? "; no known cause (dropped inputs 0, encoding failures 0, same seed and config)"
                : "; explained by " + causes.joined(separator: ", ")
        }
        lines.append("Compare       " + verdict + explanation)
        return lines.joined(separator: "\n") + "\n"
    }
}
