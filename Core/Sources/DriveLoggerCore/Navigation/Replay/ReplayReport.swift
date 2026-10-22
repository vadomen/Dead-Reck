import Foundation

/// The per-run numbers `replay_nav` keeps in `metrics.json`: everything in a
/// `ReplayResult` except the bulky track, ellipses and fix list.
public struct ReplayMetrics: Hashable, Sendable, Codable {
    public var logName: String
    public var mode: String
    public var config: NavigationConfig
    public var motionStartT: Double?
    public var startT: Double
    public var endT: Double
    public var distanceM: Double
    public var checkpoints: [ReplayResult.Checkpoint]
    public var maxErrorM: Double?
    public var maxErrorPercent: Double?
    public var endErrorM: Double?
    public var endErrorPercent: Double?
    public var endIsTruth: Bool
    public var convergedT: Double?
    public var convergedDistanceM: Double?
    public var finalHeadingStdDeg: Double?
    /// Optional so metrics.json files written before it still decode.
    public var consistency: EllipseConsistency?
    /// With the truth's own σ added (Q3, gated since N3.0). Optional so
    /// metrics.json files written before it still decode.
    public var consistencyWithTruthSigma: EllipseConsistency?
    public var steps: Int
    public var msPerStep: Double
    public var maxIngestMs: Double
    public var counters: NavigationCounters
    public var fixesUsed: Int
    public var fixesWithheld: Int
    /// The estimate just before each manual fix (sidecar `pin` form).
    /// Optional so metrics.json files written before it still decode.
    public var pins: [NavSidecar.Pin]?
    /// How the manual fixes were scored (refinement pairs, truth
    /// exclusions); N3.0. Optional so metrics.json files written before it
    /// still decode (nil there: every pin was scored).
    public var pinScoring: ReplayResult.PinScoring?
    /// The road set (N3.2): per pack in canonical order (ascending content
    /// hash), and its hash. nil (absent) for a run without roads and in
    /// files written before N3.2.
    public var roads: [ReplayRoadPack]?
    public var roadSetHash: String?
    /// The road metrics; nil (absent) without roads.
    public var roadMetrics: ReplayRoadMetrics?
    /// The truth file's `scoreUntilT` and how many checkpoints are after it
    /// (listed, not scored). nil (absent) in a run without a cutoff and in
    /// files written before it.
    public var scoreUntilT: Double?
    public var checkpointsAfterScoreUntil: Int?
    /// Roads attached as live (N3.3): inputs given before the attach and
    /// the attached set's hash. nil (absent) when roads were given from
    /// the start, when none was attached, and in files written before N3.3.
    public var roadsAttachedAfterInputs: Int?
    public var attachedRoadSetHash: String?
    /// Prompt 38: inputs given before each extension of the attached
    /// network to a larger set (`attachedRoadSetHash` is the final set's).
    /// nil (absent) when it was never extended, and in files written before.
    public var roadsExtendedAfterInputs: [Int]?
    /// The truth file's `excludeFixes` and how many fixes it kept from
    /// being truth. nil (absent) in a run without it and in files written
    /// before it.
    public var fixesExcludedByTruth: ReplayResult.FixExclusion?
    /// N3-FIXPIN: the engine's decision at each manual fix, in pin order
    /// (relative metres only). nil (absent) while both pin checks are off,
    /// and in files written before it.
    public var fixPinDecisions: [FixPinDecision]?
    /// The worst scored checkpoint per kind (R19.1-2; `KindMaxError`).
    /// nil (absent) in a run without a scored checkpoint with an error and
    /// in files written before it.
    public var maxErrorByKind: [String: KindMaxError]?
    /// UX-9 a: the recording's GPS switch (off intervals, fixes withheld by
    /// it). nil (absent) without a `gpsSwitch` input, and in files written
    /// before it.
    public var gpsSwitch: ReplayResult.GPSSwitchReport?
    /// UX-20 (replay only, `--prior`): the restore's outcome. nil (absent)
    /// without a prior, and in files written before it.
    public var restore: NavigationRestore?

    public init(_ result: ReplayResult) {
        logName = result.logName
        mode = result.mode
        config = result.config
        motionStartT = result.motionStartT
        startT = result.startT
        endT = result.endT
        distanceM = result.distanceM
        checkpoints = result.checkpoints
        maxErrorM = result.maxErrorM
        maxErrorPercent = result.maxErrorPercent
        endErrorM = result.endErrorM
        endErrorPercent = result.endErrorPercent
        endIsTruth = result.endIsTruth
        convergedT = result.convergedT
        convergedDistanceM = result.convergedDistanceM
        finalHeadingStdDeg = result.finalHeadingStdDeg
        consistency = result.consistency
        consistencyWithTruthSigma = result.consistencyWithTruthSigma
        steps = result.steps
        msPerStep = result.msPerStep
        maxIngestMs = result.maxIngestMs
        counters = result.counters
        fixesUsed = result.fixes.filter { $0.withheld == nil }.count
        fixesWithheld = result.fixes.count - fixesUsed
        pins = result.pins.map(\.pin)
        pinScoring = result.pinScoring
        roads = result.roads
        roadSetHash = result.roadSetHash
        roadMetrics = result.roadMetrics
        scoreUntilT = result.scoreUntilT
        checkpointsAfterScoreUntil = result.checkpointsAfterScoreUntil
        roadsAttachedAfterInputs = result.roadsAttachedAfterInputs
        attachedRoadSetHash = result.attachedRoadSetHash
        roadsExtendedAfterInputs = result.roadsExtendedAfterInputs.isEmpty ? nil : result.roadsExtendedAfterInputs
        fixesExcludedByTruth = result.fixesExcludedByTruth
        let decisions = result.pins.compactMap(\.fixPin)
        fixPinDecisions = decisions.isEmpty ? nil : decisions
        maxErrorByKind = result.maxErrorByKind.isEmpty ? nil : result.maxErrorByKind
        gpsSwitch = result.gpsSwitch
        restore = result.restore
    }

    /// `metrics.json` key: one row per log and mode.
    public var key: String { "\(logName) \(mode)" }
}

extension ReplayMetrics {
    /// Every stored property (`ReplayMetricsCodingTests` checks the list).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case logName, mode, config, motionStartT, startT, endT, distanceM, checkpoints
        case maxErrorM, maxErrorPercent, endErrorM, endErrorPercent, endIsTruth
        case convergedT, convergedDistanceM, finalHeadingStdDeg, consistency, consistencyWithTruthSigma
        case steps, msPerStep, maxIngestMs, counters, fixesUsed, fixesWithheld, pins, pinScoring
        case roads, roadSetHash, roadMetrics
        case scoreUntilT, checkpointsAfterScoreUntil
        case roadsAttachedAfterInputs, attachedRoadSetHash
        case roadsExtendedAfterInputs
        case fixesExcludedByTruth
        case fixPinDecisions
        case maxErrorByKind
        case gpsSwitch
        case restore
    }

    /// Keys every `metrics.json` row has had since the first one (N2). A row
    /// without one of these is not a metrics row, and decoding fails.
    static let originalKeys: Set<CodingKeys> = [
        .logName, .mode, .config, .startT, .endT, .distanceM, .checkpoints, .maxErrorM, .maxErrorPercent,
        .endErrorM, .endErrorPercent, .endIsTruth, .convergedT, .convergedDistanceM, .finalHeadingStdDeg,
        .steps, .msPerStep, .maxIngestMs, .counters, .fixesUsed, .fixesWithheld,
    ]

    /// Decodes a row written by any earlier build (R11.2-4, R12.1-1).
    /// - The original keys (`originalKeys`) are required.
    /// - Every key added later is optional and nil when absent:
    ///   `motionStartT`, `consistency`, `consistencyWithTruthSigma`, `pins`,
    ///   `pinScoring`, `roads`, `roadSetHash`, `roadMetrics`, `scoreUntilT`,
    ///   `checkpointsAfterScoreUntil`, `roadsAttachedAfterInputs`,
    ///   `attachedRoadSetHash`, `roadsExtendedAfterInputs`, `fixesExcludedByTruth`, `fixPinDecisions`, `maxErrorByKind`, `gpsSwitch`, `restore` (and any key a
    ///   later build adds, which must be optional or take a default here).
    /// - `config` and `counters` decode tolerantly themselves: a config key
    ///   or counter added later takes its default (0 for a counter).
    /// Encoding is synthesized; `metricsJSON` sorts keys, so the bytes do not
    /// depend on this decoder.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logName = try c.decode(String.self, forKey: .logName)
        mode = try c.decode(String.self, forKey: .mode)
        config = try c.decode(NavigationConfig.self, forKey: .config)
        motionStartT = try c.decodeIfPresent(Double.self, forKey: .motionStartT)
        startT = try c.decode(Double.self, forKey: .startT)
        endT = try c.decode(Double.self, forKey: .endT)
        distanceM = try c.decode(Double.self, forKey: .distanceM)
        checkpoints = try c.decode([ReplayResult.Checkpoint].self, forKey: .checkpoints)
        maxErrorM = try c.decodeIfPresent(Double.self, forKey: .maxErrorM)
        maxErrorPercent = try c.decodeIfPresent(Double.self, forKey: .maxErrorPercent)
        endErrorM = try c.decodeIfPresent(Double.self, forKey: .endErrorM)
        endErrorPercent = try c.decodeIfPresent(Double.self, forKey: .endErrorPercent)
        endIsTruth = try c.decode(Bool.self, forKey: .endIsTruth)
        convergedT = try c.decodeIfPresent(Double.self, forKey: .convergedT)
        convergedDistanceM = try c.decodeIfPresent(Double.self, forKey: .convergedDistanceM)
        finalHeadingStdDeg = try c.decodeIfPresent(Double.self, forKey: .finalHeadingStdDeg)
        consistency = try c.decodeIfPresent(EllipseConsistency.self, forKey: .consistency)
        consistencyWithTruthSigma = try c.decodeIfPresent(EllipseConsistency.self, forKey: .consistencyWithTruthSigma)
        steps = try c.decode(Int.self, forKey: .steps)
        msPerStep = try c.decode(Double.self, forKey: .msPerStep)
        maxIngestMs = try c.decode(Double.self, forKey: .maxIngestMs)
        counters = try c.decode(NavigationCounters.self, forKey: .counters)
        fixesUsed = try c.decode(Int.self, forKey: .fixesUsed)
        fixesWithheld = try c.decode(Int.self, forKey: .fixesWithheld)
        pins = try c.decodeIfPresent([NavSidecar.Pin].self, forKey: .pins)
        pinScoring = try c.decodeIfPresent(ReplayResult.PinScoring.self, forKey: .pinScoring)
        roads = try c.decodeIfPresent([ReplayRoadPack].self, forKey: .roads)
        roadSetHash = try c.decodeIfPresent(String.self, forKey: .roadSetHash)
        roadMetrics = try c.decodeIfPresent(ReplayRoadMetrics.self, forKey: .roadMetrics)
        scoreUntilT = try c.decodeIfPresent(Double.self, forKey: .scoreUntilT)
        checkpointsAfterScoreUntil = try c.decodeIfPresent(Int.self, forKey: .checkpointsAfterScoreUntil)
        roadsAttachedAfterInputs = try c.decodeIfPresent(Int.self, forKey: .roadsAttachedAfterInputs)
        attachedRoadSetHash = try c.decodeIfPresent(String.self, forKey: .attachedRoadSetHash)
        roadsExtendedAfterInputs = try c.decodeIfPresent([Int].self, forKey: .roadsExtendedAfterInputs)
        fixesExcludedByTruth = try c.decodeIfPresent(ReplayResult.FixExclusion.self, forKey: .fixesExcludedByTruth)
        fixPinDecisions = try c.decodeIfPresent([FixPinDecision].self, forKey: .fixPinDecisions)
        maxErrorByKind = try c.decodeIfPresent([String: KindMaxError].self, forKey: .maxErrorByKind)
        gpsSwitch = try c.decodeIfPresent(ReplayResult.GPSSwitchReport.self, forKey: .gpsSwitch)
        restore = try c.decodeIfPresent(NavigationRestore.self, forKey: .restore)
    }
}

public enum ReplayReport {
    // MARK: Text

    static func m(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.0f", value)
    }

    /// "unconfirmed, saved at t -600.0 s; 1 cached fix older than the save ignored",
    /// "rejected by a fix at t 12.3 s, saved at t -600.0 s".
    public static func restoreText(_ restore: NavigationRestore) -> String {
        var text = restore.status.rawValue
        if let reason = restore.reason {
            text += " (\(reason.rawValue)" + (restore.decidedT.map { String(format: " at t %.1f s", $0.seconds) } ?? "") + ")"
        }
        if let saved = restore.savedT { text += String(format: ", saved at t %.1f s", saved.seconds) }
        if restore.regrownAsMoving { text += ", regrown as moving at the first OBD reply" }
        if let v = restore.slowPullOutKmh { text += String(format: ", kept at a slow first OBD reply (%.0f km/h)", v) }
        if restore.fixesOlderThanSave > 0 {
            text += "; \(restore.fixesOlderThanSave) cached fix\(restore.fixesOlderThanSave == 1 ? "" : "es") older than the save ignored"
        }
        if let older = restore.inputsOlderThanSave, older > 0 {
            text += "; \(older) input\(older == 1 ? "" : "s") older than the save ignored before the prior was applied"
        }
        return text
    }

    static func pct(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f %%", value)
    }

    static func ellipse(_ cp: ReplayResult.Checkpoint) -> String {
        guard let a = cp.ellipseSemiMajorM, let b = cp.ellipseSemiMinorM, let o = cp.ellipseOrientationDeg else { return "n/a" }
        return String(format: "%.0f × %.0f m @ %.0f°", a, b, o)
    }

    /// "x/y (z %) inside 95 % [cleanFix a/b, manualFix c/d, …]".
    public static func consistencyText(_ consistency: EllipseConsistency?) -> String {
        guard let consistency, let percent = consistency.all.percent else { return "n/a" }
        let kinds = ReplayResult.Checkpoint.Kind.allCases.compactMap { kind -> String? in
            guard let count = consistency.byKind[kind.rawValue] else { return nil }
            return "\(kind.rawValue) \(count.inside)/\(count.scored)"
        }
        return String(format: "%d/%d (%.0f %%) inside 95 %%", consistency.all.inside, consistency.all.scored, percent)
            + (kinds.isEmpty ? "" : " [" + kinds.joined(separator: ", ") + "]")
    }

    /// "t 412.3 s: DR 55.123456, 37.123456, 95 % ellipse 120 × 40 m @ 35°,
    /// heading 87.0° ± 4.1°" — the estimate just before a manual fix.
    public static func pinText(_ pin: NavSidecar.Pin) -> String {
        let head = String(format: "t %.1f s: ", pin.t.seconds)
        guard let p = pin.prior else { return head + "initialised the engine" }
        return head + String(format: "DR %.6f, %.6f, 95 %% ellipse %.0f × %.0f m @ %.0f°, heading %.1f° ± %.1f°",
                             p.latitude, p.longitude, p.semiMajorM, p.semiMinorM, p.orientationDeg,
                             p.headingDeg, p.headingStdDeg)
    }

    /// " [refinement of t … s, not scored]" for a pin whose manual-fix
    /// checkpoint is not scored, else "".
    static func notScoredSuffix(_ pin: NavSidecar.Pin, _ checkpoints: [ReplayResult.Checkpoint]) -> String {
        let t = pin.t.seconds
        guard let text = checkpoints.first(where: { $0.kind == .manualFix && $0.t == t })?.notScoredText else { return "" }
        return " [\(text)]"
    }

    /// "Scored until t 1500.0 s (truth scoreUntilT): 3 checkpoints after it
    /// listed, not scored (cleanFix 2, truthEnd 1)"; nil without a cutoff.
    static func scoreUntilText(_ scoreUntilT: Double?, _ checkpoints: [ReplayResult.Checkpoint]) -> String? {
        guard let scoreUntilT else { return nil }
        let after = checkpoints.filter { $0.afterScoreUntilT == true }
        let kinds = ReplayResult.Checkpoint.Kind.allCases.compactMap { kind -> String? in
            let n = after.filter { $0.kind == kind }.count
            return n > 0 ? "\(kind.rawValue) \(n)" : nil
        }
        return String(format: "t %.1f s (truth scoreUntilT): ", scoreUntilT)
            + "\(after.count) checkpoint\(after.count == 1 ? "" : "s") after it listed, not scored"
            + (kinds.isEmpty ? "" : " (" + kinds.joined(separator: ", ") + ")")
    }

    /// The end-error note when it is not a truth `end`.
    static func endNote(_ checkpoints: [ReplayResult.Checkpoint]) -> String {
        checkpoints.contains { $0.kind == .truthEnd && $0.afterScoreUntilT == true }
            ? "last scored checkpoint; truth end after scoreUntilT" : "last scored checkpoint; no truth end"
    }

    /// The clean-fix part of a run: the scored ones, and how many are after
    /// `scoreUntilT` (0 without a cutoff).
    static func cleanFixes(_ checkpoints: [ReplayResult.Checkpoint]) -> (scored: [ReplayResult.Checkpoint], after: Int) {
        let clean = checkpoints.filter { $0.kind == .cleanFix }
        let scored = clean.filter(\.isScored)
        return (scored, clean.count - scored.count)
    }

    /// The clean-fix "inside 95 %" figure, with the consistency's
    /// denominator (R13.1-8): "277/277", or "200/210 (6 before
    /// initialisation)" when some of the `count` clean fixes had no
    /// estimate.
    static func cleanFixInside(_ count: Int, _ consistency: EllipseConsistency) -> String {
        let c = consistency.byKind[ReplayResult.Checkpoint.Kind.cleanFix.rawValue] ?? .init(inside: 0, scored: 0)
        return "\(c.inside)/\(c.scored)" + (c.scored == count ? "" : " (\(count - c.scored) before initialisation)")
    }

    static func km(_ value: Double?) -> String {
        guard let value else { return "never" }
        return String(format: "%.2f km", value / 1000)
    }

    /// Human-readable summary of one run for the terminal.
    public static func summary(_ result: ReplayResult) -> String {
        var lines: [String] = []
        lines.append("Log           \(result.logName)  [\(result.mode)]")
        lines.append(String(format: "Span          %.1f … %.1f s, distance %.0f m, %d steps", result.startT, result.endT, result.distanceM, result.steps)
            + (result.motionStartT.map { String(format: ", motion starts %.1f s", $0) } ?? ", no motion start"))
        lines.append(String(format: "Engine        %.3f ms/step (max ingest %.2f ms), %d particles, seed %llu",
                            result.msPerStep, result.maxIngestMs, result.config.particleCount, result.config.seed))
        let c = result.counters
        lines.append("Fixes         used \(c.fixesUsed) (network \(c.networkFixesUsed)), ignored stale \(c.fixesIgnoredStale), held \(c.fixesHeld) (used \(c.heldFixesUsed), dropped moving \(c.heldFixesDroppedMoving) / timeout \(c.heldFixesDroppedTimeout) / replaced \(c.heldFixesReplaced)), invalid \(c.fixesIgnoredInvalid), withheld \(result.fixes.filter { $0.withheld != nil }.count)")
        lines.append("Updates       course \(c.courseUpdates), speed \(c.speedUpdates), reseeds \(c.reseeds), manual \(c.manualFixes) (late \(c.lateManualFixes), resets \(c.manualResets)), resamples \(c.resamples), ZUPT steps \(c.zuptSteps) (vetoed by fixes \(c.zuptVetoedSteps)), stale-speed steps \(c.staleSpeedSteps), parked-stale steps \(c.staleParkedSteps), caught up in bulk \(c.coalescedSteps) (macro steps \(c.macroSteps))")
        let held = result.heldOutFixes
        if !held.isEmpty {
            lines.append("Held out      \(held.count) fix(es) (t s, acc m):")
            for fix in held {
                lines.append(String(format: "                %.3f  %.1f", fix.t, fix.accuracyM))
            }
        }
        let byKind = Dictionary(grouping: result.checkpoints, by: \.kind)
        for kind in [ReplayResult.Checkpoint.Kind.manualFix, .truthPoint, .truthEnd] {
            for cp in byKind[kind] ?? [] {
                let name = kind.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
                let sigma = cp.headingStdDeg.map { String(format: "%.1f", $0) } ?? "n/a"
                let inside = cp.inside95.map { $0 ? "yes" : "no" } ?? "n/a"
                let insideTruth = cp.inside95WithTruthSigma.map { $0 ? "yes" : "no" } ?? "n/a"
                lines.append(name + String(format: " t %.1f s, at %.0f m: ", cp.t, cp.distanceM)
                    + "error \(m(cp.errorM)) m (\(pct(cp.errorPercent))), σhead \(sigma)°, inside 95 %: \(inside) (+ truth σ: \(insideTruth))"
                    + ", truth σ \(m(cp.truthSigmaM)) m, 95 % ellipse \(ellipse(cp))"
                    + (cp.notScoredText.map { " [\($0)]" } ?? ""))
            }
        }
        let (clean, cleanAfter) = cleanFixes(result.checkpoints)
        if !clean.isEmpty || cleanAfter > 0 {
            let errors = clean.compactMap(\.errorM).sorted()
            let median = errors.isEmpty ? nil : errors[errors.count / 2]
            lines.append("cleanFix      \(clean.count) withheld clean fixes: median \(m(median)) m, max \(m(errors.last)) m, inside 95 % "
                + cleanFixInside(clean.count, result.consistency)
                + (cleanAfter > 0 ? "; \(cleanAfter) more after scoreUntilT, not scored" : ""))
        }
        for pin in result.pins {
            lines.append("Pin estimate  " + pinText(pin.pin) + notScoredSuffix(pin.pin, result.checkpoints))
            if let decision = pin.fixPin { lines.append("              " + decision.text) }
        }
        if let text = fixPinText(result.config, result.counters) { lines.append("Fix-pin       " + text) }
        if result.pinScoring.manualFixes > 0 || !result.pinScoring.unmatchedExclusionsT.isEmpty {
            lines.append("Pins scored   " + result.pinScoring.text)
        }
        if let text = scoreUntilText(result.scoreUntilT, result.checkpoints) {
            lines.append("Scored until  " + text)
        }
        if let exclusion = result.fixesExcludedByTruth {
            lines.append("Fixes excl.   by truth excludeFixes " + exclusion.text)
        }
        if let report = result.gpsSwitch {
            lines.append("GPS switch    " + report.text)
        }
        if let restore = result.restore {
            lines.append("Restore       " + restoreText(restore))
        }
        lines.append("Consistency   " + consistencyText(result.consistency) + " (engine ellipse)")
        lines.append("  + truth σ   " + consistencyText(result.consistencyWithTruthSigma) + " (engine covariance + truth σ²; gated)")
        lines.append("Max error     \(m(result.maxErrorM)) m (\(pct(result.maxErrorPercent)))")
        if let text = maxByKindText(result.maxErrorByKind) { lines.append("Max by kind   " + text) }
        lines.append("End error     \(m(result.endErrorM)) m (\(pct(result.endErrorPercent)))\(result.endIsTruth ? "" : " [\(endNote(result.checkpoints))]")")
        if let last = result.track.last {
            lines.append(String(format: "Final         speed scale %.4f, σhead %.1f°", last.speedScale, last.headingStdDeg))
        }
        lines.append("Converged     \(km(result.convergedDistanceM))\(result.convergedT.map { String(format: " (t %.1f s)", $0) } ?? ""), final σhead \(result.finalHeadingStdDeg.map { String(format: "%.1f°", $0) } ?? "n/a")")
        if let packs = result.roads, let hash = result.roadSetHash {
            lines.append(roadsText(packs, roadSetHash: hash))
            lines.append(contentsOf: roadLines(result.roadMetrics, counters: result.counters))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "cleanFix 266: 218 m (t 2144.0 s), 1.10 % (t 2144.0 s); manualFix
    /// 7: …" in `Checkpoint.Kind` order: per kind, the largest error and
    /// the largest error as % of distance from the start (R19.1-2); nil
    /// without a scored checkpoint.
    public static func maxByKindText(_ byKind: [String: KindMaxError]) -> String? {
        let parts = ReplayResult.Checkpoint.Kind.allCases.compactMap { kind -> String? in
            guard let k = byKind[kind.rawValue] else { return nil }
            return "\(kind.rawValue) \(k.scored): \(m(k.maxErrorM)) m" + String(format: " (t %.1f s), ", k.maxErrorT)
                + pct(k.maxPercent) + (k.maxPercentT.map { String(format: " (t %.1f s)", $0) } ?? "")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func share(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f %%", 100 * value)
    }

    /// The N3-FIXPIN counters as one line; nil while both pin checks are
    /// off and every counter is 0, so a key-off summary and `metrics.md`
    /// are byte-identical to the build before them.
    public static func fixPinText(_ config: NavigationConfig, _ c: NavigationCounters) -> String? {
        guard config.roadFixPinCheck != 0 || config.fixPinTwoPinCheck != 0 || c.anyFixPin else { return nil }
        func pair(_ a: Int, _ p: Int) -> String { "\(a)/\(p)" }
        return "checks roads \(config.roadFixPinCheck), two-pin \(config.fixPinTwoPinCheck); counts accessory/phone: "
            + "significant pins \(c.fixPinSignificantPins); "
            + "road verdict pin \(pair(c.fixPinRoadVerdictPinAccessory, c.fixPinRoadVerdictPinPhone)), "
            + "fixes \(pair(c.fixPinRoadVerdictFixesAccessory, c.fixPinRoadVerdictFixesPhone)), "
            + "none \(pair(c.fixPinRoadVerdictNoneAccessory, c.fixPinRoadVerdictNonePhone)); "
            + "two-pin verdict pin \(pair(c.fixPinTwoPinVerdictPinAccessory, c.fixPinTwoPinVerdictPinPhone)), "
            + "none \(pair(c.fixPinTwoPinVerdictNoneAccessory, c.fixPinTwoPinVerdictNonePhone)); "
            + "down-weighted \(pair(c.fixPinDownweightsAccessory, c.fixPinDownweightsPhone)) times, "
            + "fixes \(pair(c.fixPinDownweightedFixesAccessory, c.fixPinDownweightedFixesPhone)) "
            + "(course \(pair(c.fixPinCourseUpdatesDownweightedAccessory, c.fixPinCourseUpdatesDownweightedPhone)), "
            + "speed \(pair(c.fixPinSpeedUpdatesDownweightedAccessory, c.fixPinSpeedUpdatesDownweightedPhone)), "
            + "rejected off-road \(pair(c.fixPinRejectedOffRoadDownweightedAccessory, c.fixPinRejectedOffRoadDownweightedPhone))), "
            + "reseeds blocked \(c.fixPinReseedsBlocked); "
            + "restored by roads \(pair(c.fixPinRestoresByRoadsAccessory, c.fixPinRestoresByRoadsPhone)), "
            + "agreement \(pair(c.fixPinRestoresByAgreementAccessory, c.fixPinRestoresByAgreementPhone)), "
            + "pin \(pair(c.fixPinRestoresByPinAccessory, c.fixPinRestoresByPinPhone)); "
            + "road rechecks \(c.fixPinRoadRechecks), road distance queries \(c.fixPinRoadDistanceQueries)"
    }

    /// The road lines of the summary (N3.2b).
    public static func roadLines(_ metrics: ReplayRoadMetrics?, counters c: NavigationCounters) -> [String] {
        var lines: [String] = []
        lines.append("Road updates  \(c.roadUpdates) (no road near \(c.roadUpdatesNoRoad), pin anchors \(c.roadPinAnchors)), "
            + "splits \(c.roadSplits), candidate tests \(c.roadCandidateTests)"
            + (metrics?.candidateTestsPerUpdate.map { String(format: " (%.0f per update", $0) } ?? "")
            + (metrics?.candidateTestsPerParticle.map { String(format: ", %.1f per particle)", $0) } ?? "")
            + ", level blocked \(c.roadLevelBlocked), fixes rejected off-road \(c.fixesRejectedOffRoad)")
        guard let m = metrics else { return lines }
        lines.append("On road       1 Hz samples \(m.trackSamples): engaged \(m.trackEngaged), onRoadShare ≥ 0.5 \(m.trackOnRoad)"
            + (m.trackSamples > 0 ? String(format: " (%.1f %%)", 100 * Double(m.trackOnRoad) / Double(m.trackSamples)) : "")
            + ", mean share \(m.meanOnRoadShare.map { String(format: "%.3f", $0) } ?? "n/a")")
        let truth = { (s: RoadTruthStatus) in m.truth[s.rawValue] ?? 0 }
        lines.append("Road truth    (offline) \(m.withheldCleanFixes) withheld clean fixes: matched \(truth(.matched)), "
            + "ambiguous \(truth(.ambiguous)) (\(share(m.ambiguousShare)) of matched + ambiguous), "
            + "no heading-compatible road within \(GPSMode.format(NavigationReplay.RoadTruth.onRoadMaxM)) m \(truth(.noRoad)), "
            + "no usable course \(truth(.noCourse))"
            + ((m.ambiguousShare ?? 0) > NavigationReplay.RoadTruth.viterbiAmbiguousShare
                ? "; WARNING: over 20 % ambiguous, the plan calls for a Viterbi match (not implemented)" : ""))
        let v = { (verdict: WrongRoadVerdict) in m.count(verdict) }
        lines.append("Wrong road    (capture onto a wrong mapped road only; tolerance \(GPSMode.format(m.wrongRoadToleranceM)) m) "
            + "scored \(m.scored): wrong \(v(.wrong).fixes) (\(share(m.wrongShare)); by distance \(share(m.wrongShareByDistance))), "
            + "right \(v(.right).fixes), off \(v(.off).fixes) (\(share(m.offShare)); by distance \(share(m.offShareByDistance))), "
            + "not engaged \(v(.notEngaged).fixes)")
        let r15 = GPSMode.format(NavigationReplay.RoadTruth.unmappedDistanceM)
        lines.append("Unmapped      \(m.unmapped) withheld clean fixes with no heading-compatible road within \(r15) m"
            + Self.unmappedSplit(m.unmappedNoRoadWithin15, m.unmappedNoCompatibleRoadWithin15,
                                 " (> \(r15) m from every edge %d + only incompatible edges within \(r15) m %d; no usable course: distance only)")
            + " (\(m.unmappedWithEstimate) with an estimate): captured \(m.unmappedCaptured)"
            + Self.unmappedSplit(m.unmappedCapturedNoRoadWithin15, m.unmappedCapturedNoCompatibleRoadWithin15, " (%d + %d)")
            + " (on a mapped edge, < \(GPSMode.format(NavigationReplay.RoadTruth.capturedCrossTrackM)) m across, truth outside the 95 % ellipse)")
        if let all = m.residualsAll {
            let classes = m.residuals.keys.sorted().map { key -> String in
                let r = m.residuals[key]!
                return String(format: "%@ %.1f/%.1f (%d)", key, r.p50M, r.p95M, r.count)
            }
            lines.append(String(format: "Residuals     (offline) clean fixes to their truth edge, p50/p95 m (n): all %.1f/%.1f (%d); ",
                                all.p50M, all.p95M, all.count) + classes.joined(separator: ", "))
        }
        if !m.rejectedFixes.isEmpty {
            lines.append("Rejected      off-road fixes (t s, acc m): "
                + m.rejectedFixes.map { String(format: "%.1f/%.0f", $0[0], $0[1]) }.joined(separator: ", "))
        }
        return lines
    }

    // MARK: Reading the recording (R11.1-8)

    /// What `LogFileReader` reported, as one line for the summary: "490 gzip
    /// members; truncated tail: no; damaged members: none; skipped lines:
    /// none" (the `inspect_log` "Integrity" wording).
    public static func readText(_ report: LogReadReport) -> String {
        let members = report.members == 0 ? "plain .jsonl" : "\(report.members) gzip members"
        return "\(members); truncated tail: \(report.truncatedTail ? "yes" : "no"); damaged members: "
            + (report.damagedMemberIndices.isEmpty ? "none" : "\(report.damagedMemberIndices)")
            + "; skipped lines: \(report.skippedLineIndices.isEmpty ? "none" : "\(report.skippedLineIndices.count)")"
            + (report.failure.map { "; stopped early: \($0)" } ?? "")
            + (report.readError.map { "; read error: \($0)" } ?? "")
    }

    /// Why the replay may not have seen the whole recording, one entry per
    /// problem; empty for a clean read. Any of these shortens the drive or
    /// leaves a hole in it, so the truth `end` (scored at the last input
    /// read) and the distance can be wrong: `replay_nav` warns, and
    /// `--strict` refuses the log.
    public static func readProblems(_ report: LogReadReport) -> [String] {
        var problems: [String] = []
        if report.truncatedTail {
            problems.append("truncated or damaged tail: the end of the recording is missing")
        }
        if !report.damagedMemberIndices.isEmpty {
            problems.append("\(report.damagedMemberIndices.count) damaged gzip member(s) skipped: \(report.damagedMemberIndices)")
        }
        if !report.skippedLineIndices.isEmpty {
            problems.append("\(report.skippedLineIndices.count) malformed line(s) skipped")
        }
        if let failure = report.failure {
            problems.append("reading stopped early: \(failure)")
        }
        if let readError = report.readError {
            problems.append("reading stopped at a read error, the rest was not read: \(readError)")
        }
        return problems
    }

    // MARK: Markdown

    /// `metrics.md`: one row per run, then each run's checkpoints and config.
    public static func markdown(_ runs: [ReplayMetrics]) -> String {
        let runs = runs.sorted { $0.key < $1.key }
        func clean(_ r: ReplayMetrics) -> KindMaxError? { r.maxErrorByKind?[ReplayResult.Checkpoint.Kind.cleanFix.rawValue] }
        var out = "# replay_nav metrics\n\n"
        out += "Error is the engine's causal estimate against information it did not receive.\n\n"
        out += "| log | mode | distance m | checkpoints | end err m | end % | max err m | max % | inside 95 % | inside 95 % + truth σ (gated) | converged at | ms/step | max ingest ms | clean-fix max err m | clean-fix max % |\n"
        out += "|---|---|---:|---:|---:|---:|---:|---:|---|---|---:|---:|---:|---:|---:|\n"
        for r in runs {
            out += "| \(r.logName) | \(r.mode) | \(m(r.distanceM)) | \(r.checkpoints.count)\(r.checkpointsAfterScoreUntil.map { " (\($0) after scoreUntilT)" } ?? "") | \(m(r.endErrorM))\(r.endIsTruth ? "" : "*") | \(pct(r.endErrorPercent)) | \(m(r.maxErrorM)) | \(pct(r.maxErrorPercent)) | \(consistencyText(r.consistency)) | \(consistencyText(r.consistencyWithTruthSigma)) | \(km(r.convergedDistanceM)) | \(String(format: "%.3f", r.msPerStep)) | \(String(format: "%.2f", r.maxIngestMs)) | \(m(clean(r)?.maxErrorM)) | \(pct(clean(r)?.maxPercent)) |\n"
        }
        out += "\n\\* no truth `end`: error at the last scored checkpoint.\n"
        out += "\nmax err covers every scored checkpoint (pins and truth points too); clean-fix max err and clean-fix max % "
            + "cover the scored withheld clean fixes only, and max % is the largest error as % of the distance from the start "
            + "at its time (not necessarily the fix with the largest error): the figure drive-7 and drive-8 are gated on. "
            + "n/a: no scored clean fix (or a row from an older build).\n"
        if runs.contains(where: { $0.scoreUntilT != nil }) {
            out += "\nWith a truth `scoreUntilT`, checkpoints after it are listed but not scored (no error, consistency or "
                + "convergence figure counts them); a truth `end` after it is replaced by the last scored checkpoint (\\*).\n"
        }
        let roadRuns = runs.filter { $0.roadMetrics != nil }
        if !roadRuns.isEmpty {
            out += "\n## Roads\n\n"
            out += "Road data © OpenStreetMap contributors (ODbL 1.0). Wrong road checks capture onto a wrong *mapped* road only; "
                + "capture while the car is on an unmapped road is the unmapped/captured column: no heading-compatible road "
                + "within 15 m, split as (> 15 m from every edge + only incompatible edges within 15 m); a fix with no usable "
                + "course counts by distance only. Road truth is offline.\n\n"
            out += "| log | mode | roadSetHash | road updates | on road (1 Hz) | truth matched / ambiguous | scored | wrong (fixes) | wrong (distance) | off (fixes) | not engaged | unmapped (far + incompatible) / captured | rejected fixes |\n"
            out += "|---|---|---|---:|---:|---|---:|---:|---:|---:|---:|---|---:|\n"
            for r in roadRuns {
                let m = r.roadMetrics!
                out += "| \(r.logName) | \(r.mode) | \(r.roadSetHash ?? "n/a") | \(r.counters.roadUpdates) | "
                    + (m.trackSamples > 0 ? String(format: "%.1f %%", 100 * Double(m.trackOnRoad) / Double(m.trackSamples)) : "n/a")
                    + " | \(m.truth[RoadTruthStatus.matched.rawValue] ?? 0) / \(m.truth[RoadTruthStatus.ambiguous.rawValue] ?? 0)"
                    + " | \(m.scored) | \(m.count(.wrong).fixes) (\(share(m.wrongShare))) | \(share(m.wrongShareByDistance))"
                    + " | \(m.count(.off).fixes) (\(share(m.offShare))) | \(m.count(.notEngaged).fixes)"
                    + " | \(m.unmapped)\(Self.unmappedSplit(m.unmappedNoRoadWithin15, m.unmappedNoCompatibleRoadWithin15, " (%d + %d)"))"
                    + " / \(m.unmappedCaptured)\(Self.unmappedSplit(m.unmappedCapturedNoRoadWithin15, m.unmappedCapturedNoCompatibleRoadWithin15, " (%d + %d)"))"
                    + " | \(m.rejectedFixes.count) |\n"
            }
        }
        for r in runs {
            out += "\n## \(r.logName) — \(r.mode)\n\n"
            if let scoring = r.pinScoring, scoring.manualFixes > 0 || !scoring.unmatchedExclusionsT.isEmpty {
                out += "Pins: \(scoring.text).\n\n"
            }
            if let text = scoreUntilText(r.scoreUntilT, r.checkpoints) {
                out += "Scored until \(text).\n\n"
            }
            if let exclusion = r.fixesExcludedByTruth {
                out += "Fixes excluded by truth (excludeFixes): \(exclusion.text).\n\n"
            }
            if let report = r.gpsSwitch {
                out += "GPS switch (the recording's, UX-9 a): \(report.text).\n\n"
            }
            if let restore = r.restore {
                out += "Restored prior (UX-20, replay only): \(restoreText(restore)).\n\n"
            }
            out += "| kind | t s | distance m | error m | % of distance | σ heading ° | inside 95 % | + truth σ | truth σ m | 95 % ellipse |\n|---|---:|---:|---:|---:|---:|---|---|---:|---|\n"
            for cp in r.checkpoints where cp.kind != .cleanFix {
                out += "| \(cp.kind.rawValue)\(cp.notScoredText.map { " (\($0))" } ?? "") | \(String(format: "%.1f", cp.t)) | \(m(cp.distanceM)) | \(m(cp.errorM)) | \(pct(cp.errorPercent)) | \(cp.headingStdDeg.map { String(format: "%.1f", $0) } ?? "n/a") | \(cp.inside95.map { $0 ? "yes" : "no" } ?? "n/a") | \(cp.inside95WithTruthSigma.map { $0 ? "yes" : "no" } ?? "n/a") | \(m(cp.truthSigmaM)) | \(ellipse(cp)) |\n"
            }
            let (clean, cleanAfter) = cleanFixes(r.checkpoints)
            if !clean.isEmpty {
                let errors = clean.compactMap(\.errorM).sorted()
                out += "| cleanFix ×\(clean.count) | | | median \(m(errors.isEmpty ? nil : errors[errors.count / 2])), max \(m(errors.last)) | | | \(cleanFixInside(clean.count, r.consistency ?? EllipseConsistency(r.checkpoints))) | \(r.consistencyWithTruthSigma.map { cleanFixInside(clean.count, $0) } ?? "n/a") | | |\n"
            }
            if cleanAfter > 0 {
                out += "| cleanFix ×\(cleanAfter) (\(NavigationReplay.afterScoreUntilText)) | | | | | | | | | |\n"
            }
            if let pins = r.pins, !pins.isEmpty {
                out += "\nDR estimate at each manual fix (prior):\n\n"
                for pin in pins { out += "- " + pinText(pin) + notScoredSuffix(pin, r.checkpoints) + "\n" }
            }
            if let decisions = r.fixPinDecisions, !decisions.isEmpty {
                out += "\nPin against GNSS sources (N3-FIXPIN):\n\n"
                for d in decisions { out += String(format: "- t %.1f s: ", d.t) + d.text + "\n" }
            }
            if let text = fixPinText(r.config, r.counters) { out += "\nFix-pin: \(text).\n" }
            if let packs = r.roads, let hash = r.roadSetHash {
                out += "\n```\n" + roadsText(packs, roadSetHash: hash) + "\n"
                    + roadLines(r.roadMetrics, counters: r.counters).joined(separator: "\n") + "\n```\n"
            }
            out += "\nSeed \(r.config.seed), \(r.config.particleCount) particles. Config:\n\n```json\n\(configJSON(r.config))\n```\n"
        }
        return out
    }

    /// Every config key whose value differs between `old` and `new`, as
    /// "key old → new", sorted by key: what `validated()` clamped (R21.3-6).
    public static func configChanges(from old: NavigationConfig, to new: NavigationConfig) -> [String] {
        func object(_ config: NavigationConfig) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: config.canonicalJSON())) as? [String: Any] ?? [:]
        }
        let a = object(old), b = object(new)
        return Set(a.keys).union(b.keys).sorted().compactMap { key in
            let x = a[key].map { "\($0)" } ?? "absent", y = b[key].map { "\($0)" } ?? "absent"
            return x == y ? nil : "\(key) \(x) → \(y)"
        }
    }

    /// The road set of a run, one line per pack, with the attribution:
    /// The unmapped split (N3.2c item 2) in `format` (two `%d`: > 15 m from
    /// every edge, then only incompatible edges within 15 m); empty for a
    /// row written before item 2.
    static func unmappedSplit(_ far: Int?, _ incompatible: Int?, _ format: String) -> String {
        guard let far, let incompatible else { return "" }
        return String(format: format, far, incompatible)
    }

    /// "Roads         2 packs, roadSetHash …, © OpenStreetMap contributors (ODbL 1.0)".
    public static func roadsText(_ packs: [ReplayRoadPack], roadSetHash: String) -> String {
        var lines = ["Roads         \(packs.count) pack\(packs.count == 1 ? "" : "s"), roadSetHash \(roadSetHash), "
            + "\(RoadNetwork.attribution) (\(RoadPackFormat.license))"]
        for (i, pack) in packs.enumerated() {
            lines.append("  pack \(i)      " + pack.text)
        }
        return lines.joined(separator: "\n")
    }

    public static func configJSON(_ config: NavigationConfig) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: metrics.json

    /// Merges `runs` into an existing `metrics.json` document (replacing
    /// runs with the same key), so separate invocations build one table.
    ///
    /// An existing document that does not decode contributes no rows; call
    /// `existingMetricsDecodeError` first, and keep a copy with
    /// `keepUndecodableMetrics` before replacing it, so its rows are not lost
    /// silently (R11.2-4, R18.1-2). Rows from earlier builds decode
    /// (`ReplayMetrics.init(from:)`), so this is for a damaged file or one
    /// that is not a metrics document.
    public static func mergedMetrics(existing: Data?, adding runs: [ReplayMetrics]) throws -> [ReplayMetrics] {
        var byKey: [String: ReplayMetrics] = [:]
        if let existing, let old = try? JSONDecoder().decode([ReplayMetrics].self, from: existing) {
            for run in old { byKey[run.key] = run }
        }
        for run in runs { byKey[run.key] = run }
        return byKey.values.sorted { $0.key < $1.key }
    }

    /// Why an existing `metrics.json` does not decode, or nil when it does
    /// (or there is none).
    public static func existingMetricsDecodeError(_ existing: Data?) -> String? {
        guard let existing else { return nil }
        do {
            _ = try JSONDecoder().decode([ReplayMetrics].self, from: existing)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Writes `data` (an existing `metrics.json` that does not decode) to a
    /// new file `metrics.undecodable-<stamp>.json` in `directory`, or
    /// `…-<stamp>-1.json`, `-2`, … if that name is taken, and returns its URL.
    /// An existing file is never overwritten. Throws if the copy cannot be
    /// written: the caller must then leave `metrics.json` as it is (R18.1-2).
    public static func keepUndecodableMetrics(_ data: Data, in directory: URL, stamp: String) throws -> URL {
        for attempt in 0..<1_000 {
            let name = "metrics.undecodable-\(stamp)\(attempt == 0 ? "" : "-\(attempt)").json"
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    public static func metricsJSON(_ runs: [ReplayMetrics]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(runs.sorted { $0.key < $1.key })
    }

    // MARK: GeoJSON

    /// The track feature's properties; with roads also the road set (N3.2),
    /// so a GeoJSON file names the exact packs it was matched against.
    static func trackProperties(_ result: ReplayResult) -> [String: Any] {
        var properties: [String: Any] = [
            "kind": "track", "log": result.logName, "mode": result.mode,
            "t": result.track.map(\.t), "headingDeg": result.track.map(\.headingDeg),
            "headingStdDeg": result.track.map(\.headingStdDeg),
        ]
        if let packs = result.roads, let hash = result.roadSetHash {
            properties["roadSetHash"] = hash
            properties["roads"] = packs.map {
                ["contentHash": $0.contentHash, "formatVersion": $0.formatVersion, "osmTimestamp": $0.osmTimestamp,
                 "gridID": $0.gridID] as [String: Any]
            }
            properties["attribution"] = "\(RoadNetwork.attribution) (\(RoadPackFormat.license))"
        }
        return properties
    }

    /// The run as a GeoJSON FeatureCollection: DR track (LineString),
    /// 95 % ellipses (Polygons), fixes used and withheld, checkpoints with
    /// their truth (Points). Coordinates are [longitude, latitude]. With
    /// roads (N3.2b) also: the road set on the track feature, off-road
    /// rejected fixes (`fixRejectedOffRoad`) and the matched edge every
    /// `ellipseIntervalS` (`matchedEdge`). Without roads the bytes are
    /// those of N3.0.
    public static func geoJSON(_ result: ReplayResult) throws -> Data {
        var features: [[String: Any]] = []
        features.append([
            "type": "Feature",
            "geometry": ["type": "LineString", "coordinates": result.track.map { [$0.longitude, $0.latitude] }],
            "properties": trackProperties(result),
        ])
        for e in result.ellipses {
            features.append([
                "type": "Feature",
                "geometry": ["type": "Polygon", "coordinates": [e.ring.map { [$0[1], $0[0]] }]],
                "properties": ["kind": "ellipse95", "t": e.t, "semiMajorM": e.semiMajorM,
                               "semiMinorM": e.semiMinorM, "orientationDeg": e.orientationDeg],
            ])
        }
        for fix in result.fixes {
            var properties: [String: Any] = [
                "kind": fix.withheld == nil ? "fixUsed" : "fixWithheld",
                "withheld": fix.withheld?.rawValue ?? "", "t": fix.t,
                "arrivalT": fix.arrivalT, "accuracyM": fix.accuracyM,
            ]
            // Roads only (N3.2b): a fix the engine ignored as off-road.
            if fix.rejectedOffRoad == true {
                properties["kind"] = "fixRejectedOffRoad"
                properties["rejectedOffRoad"] = true
            }
            // UX-9 a: withheld by the recording's GPS switch, not by the replay.
            if fix.withheldByGPSSwitch == true {
                properties["kind"] = "fixWithheldByGPSSwitch"
                properties["withheldByGPSSwitch"] = true
            }
            features.append([
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [fix.longitude, fix.latitude]],
                "properties": properties,
            ])
        }
        for cp in result.checkpoints {
            var properties: [String: Any] = ["kind": "truth", "truthKind": cp.kind.rawValue, "t": cp.t, "distanceM": cp.distanceM]
            if let error = cp.errorM { properties["errorM"] = error }
            if let sigma = cp.truthSigmaM { properties["sigmaM"] = sigma }
            features.append([
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [cp.longitude, cp.latitude]],
                "properties": properties,
            ])
            if let lat = cp.estimateLatitude, let lon = cp.estimateLongitude {
                features.append([
                    "type": "Feature",
                    "geometry": ["type": "LineString", "coordinates": [[lon, lat], [cp.longitude, cp.latitude]]],
                    "properties": ["kind": "checkpointError", "truthKind": cp.kind.rawValue, "t": cp.t,
                                   "errorM": cp.errorM ?? 0],
                ])
            }
        }
        // Added in N4 B, after every earlier feature: the estimate and its
        // 95 % ellipse just before each manual fix.
        for pin in result.pins {
            guard let prior = pin.pin.prior else { continue }
            let properties: [String: Any] = [
                "kind": "pinEstimate", "t": pin.pin.t.seconds, "headingDeg": prior.headingDeg,
                "headingStdDeg": prior.headingStdDeg, "semiMajorM": prior.semiMajorM,
                "semiMinorM": prior.semiMinorM, "orientationDeg": prior.orientationDeg, "converged": prior.converged,
            ]
            features.append([
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [prior.longitude, prior.latitude]],
                "properties": properties,
            ])
            if let ring = pin.ring {
                var ellipse = properties
                ellipse["kind"] = "pinEllipse95"
                features.append([
                    "type": "Feature",
                    "geometry": ["type": "Polygon", "coordinates": [ring.map { [$0[1], $0[0]] }]],
                    "properties": ellipse,
                ])
            }
        }
        // Roads only (N3.2b), after every earlier feature: the engine's
        // matched OSM edge every `ellipseIntervalS`. © OpenStreetMap
        // contributors (the track feature carries the attribution).
        for sample in result.matchedEdges {
            var properties: [String: Any] = [
                "kind": "matchedEdge", "t": sample.t, "pack": sample.edge.pack, "edge": sample.edge.edge,
                "osmWayID": sample.edge.osmWayID, "highway": sample.roadClass,
            ]
            if let share = sample.onRoadShare { properties["onRoadShare"] = share }
            features.append([
                "type": "Feature",
                "geometry": ["type": "LineString", "coordinates": sample.points.map { [$0[1], $0[0]] }],
                "properties": properties,
            ])
        }
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys])
    }
}
