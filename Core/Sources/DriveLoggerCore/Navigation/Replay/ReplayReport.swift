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
        steps = result.steps
        msPerStep = result.msPerStep
        maxIngestMs = result.maxIngestMs
        counters = result.counters
        fixesUsed = result.fixes.filter { $0.withheld == nil }.count
        fixesWithheld = result.fixes.count - fixesUsed
        pins = result.pins.map(\.pin)
        pinScoring = result.pinScoring
    }

    /// `metrics.json` key: one row per log and mode.
    public var key: String { "\(logName) \(mode)" }
}

extension ReplayMetrics {
    /// Every stored property (`ReplayMetricsCodingTests` checks the list).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case logName, mode, config, motionStartT, startT, endT, distanceM, checkpoints
        case maxErrorM, maxErrorPercent, endErrorM, endErrorPercent, endIsTruth
        case convergedT, convergedDistanceM, finalHeadingStdDeg, consistency
        case steps, msPerStep, maxIngestMs, counters, fixesUsed, fixesWithheld, pins, pinScoring
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
    ///   `motionStartT`, `consistency`, `pins`, `pinScoring` (and any key a
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
        steps = try c.decode(Int.self, forKey: .steps)
        msPerStep = try c.decode(Double.self, forKey: .msPerStep)
        maxIngestMs = try c.decode(Double.self, forKey: .maxIngestMs)
        counters = try c.decode(NavigationCounters.self, forKey: .counters)
        fixesUsed = try c.decode(Int.self, forKey: .fixesUsed)
        fixesWithheld = try c.decode(Int.self, forKey: .fixesWithheld)
        pins = try c.decodeIfPresent([NavSidecar.Pin].self, forKey: .pins)
        pinScoring = try c.decodeIfPresent(ReplayResult.PinScoring.self, forKey: .pinScoring)
    }
}

public enum ReplayReport {
    // MARK: Text

    static func m(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.0f", value)
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
        guard let notScored = checkpoints.first(where: { $0.kind == .manualFix && $0.t == t })?.notScored else { return "" }
        return " [\(notScored.text)]"
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
        lines.append("Updates       course \(c.courseUpdates), speed \(c.speedUpdates), reseeds \(c.reseeds), manual \(c.manualFixes) (late \(c.lateManualFixes), resets \(c.manualResets)), resamples \(c.resamples), ZUPT steps \(c.zuptSteps), stale-speed steps \(c.staleSpeedSteps), parked-stale steps \(c.staleParkedSteps), caught up in bulk \(c.coalescedSteps) (macro steps \(c.macroSteps))")
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
                lines.append(name + String(format: " t %.1f s, at %.0f m: ", cp.t, cp.distanceM)
                    + "error \(m(cp.errorM)) m (\(pct(cp.errorPercent))), σhead \(sigma)°, inside 95 %: \(inside)"
                    + ", truth σ \(m(cp.truthSigmaM)) m, 95 % ellipse \(ellipse(cp))"
                    + (cp.notScored.map { " [\($0.text)]" } ?? ""))
            }
        }
        if let clean = byKind[.cleanFix], !clean.isEmpty {
            let errors = clean.compactMap(\.errorM).sorted()
            let median = errors.isEmpty ? nil : errors[errors.count / 2]
            let inside = clean.compactMap(\.inside95).filter { $0 }.count
            lines.append("cleanFix      \(clean.count) withheld clean fixes: median \(m(median)) m, max \(m(errors.last)) m, inside 95 % \(inside)/\(clean.count)")
        }
        for pin in result.pins {
            lines.append("Pin estimate  " + pinText(pin.pin) + notScoredSuffix(pin.pin, result.checkpoints))
        }
        if result.pinScoring.manualFixes > 0 || !result.pinScoring.unmatchedExclusionsT.isEmpty {
            lines.append("Pins scored   " + result.pinScoring.text)
        }
        lines.append("Consistency   " + consistencyText(result.consistency))
        lines.append("Max error     \(m(result.maxErrorM)) m (\(pct(result.maxErrorPercent)))")
        lines.append("End error     \(m(result.endErrorM)) m (\(pct(result.endErrorPercent)))\(result.endIsTruth ? "" : " [last scored checkpoint; no truth end]")")
        if let last = result.track.last {
            lines.append(String(format: "Final         speed scale %.4f, σhead %.1f°", last.speedScale, last.headingStdDeg))
        }
        lines.append("Converged     \(km(result.convergedDistanceM))\(result.convergedT.map { String(format: " (t %.1f s)", $0) } ?? ""), final σhead \(result.finalHeadingStdDeg.map { String(format: "%.1f°", $0) } ?? "n/a")")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Markdown

    /// `metrics.md`: one row per run, then each run's checkpoints and config.
    public static func markdown(_ runs: [ReplayMetrics]) -> String {
        let runs = runs.sorted { $0.key < $1.key }
        var out = "# replay_nav metrics\n\n"
        out += "Error is the engine's causal estimate against information it did not receive.\n\n"
        out += "| log | mode | distance m | checkpoints | end err m | end % | max err m | max % | inside 95 % | converged at | ms/step | max ingest ms |\n"
        out += "|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|\n"
        for r in runs {
            out += "| \(r.logName) | \(r.mode) | \(m(r.distanceM)) | \(r.checkpoints.count) | \(m(r.endErrorM))\(r.endIsTruth ? "" : "*") | \(pct(r.endErrorPercent)) | \(m(r.maxErrorM)) | \(pct(r.maxErrorPercent)) | \(consistencyText(r.consistency)) | \(km(r.convergedDistanceM)) | \(String(format: "%.3f", r.msPerStep)) | \(String(format: "%.2f", r.maxIngestMs)) |\n"
        }
        out += "\n\\* no truth `end`: error at the last scored checkpoint.\n"
        for r in runs {
            out += "\n## \(r.logName) — \(r.mode)\n\n"
            if let scoring = r.pinScoring, scoring.manualFixes > 0 || !scoring.unmatchedExclusionsT.isEmpty {
                out += "Pins: \(scoring.text).\n\n"
            }
            out += "| kind | t s | distance m | error m | % of distance | σ heading ° | inside 95 % | truth σ m | 95 % ellipse |\n|---|---:|---:|---:|---:|---:|---|---:|---|\n"
            for cp in r.checkpoints where cp.kind != .cleanFix {
                out += "| \(cp.kind.rawValue)\(cp.notScored.map { " (\($0.text))" } ?? "") | \(String(format: "%.1f", cp.t)) | \(m(cp.distanceM)) | \(m(cp.errorM)) | \(pct(cp.errorPercent)) | \(cp.headingStdDeg.map { String(format: "%.1f", $0) } ?? "n/a") | \(cp.inside95.map { $0 ? "yes" : "no" } ?? "n/a") | \(m(cp.truthSigmaM)) | \(ellipse(cp)) |\n"
            }
            let clean = r.checkpoints.filter { $0.kind == .cleanFix }
            if !clean.isEmpty {
                let errors = clean.compactMap(\.errorM).sorted()
                out += "| cleanFix ×\(clean.count) | | | median \(m(errors.isEmpty ? nil : errors[errors.count / 2])), max \(m(errors.last)) | | | \(clean.compactMap(\.inside95).filter { $0 }.count)/\(clean.count) | | |\n"
            }
            if let pins = r.pins, !pins.isEmpty {
                out += "\nDR estimate at each manual fix (prior):\n\n"
                for pin in pins { out += "- " + pinText(pin) + notScoredSuffix(pin, r.checkpoints) + "\n" }
            }
            out += "\nSeed \(r.config.seed), \(r.config.particleCount) particles. Config:\n\n```json\n\(configJSON(r.config))\n```\n"
        }
        return out
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

    /// The run as a GeoJSON FeatureCollection: DR track (LineString),
    /// 95 % ellipses (Polygons), fixes used and withheld, checkpoints with
    /// their truth (Points). Coordinates are [longitude, latitude].
    public static func geoJSON(_ result: ReplayResult) throws -> Data {
        var features: [[String: Any]] = []
        features.append([
            "type": "Feature",
            "geometry": ["type": "LineString", "coordinates": result.track.map { [$0.longitude, $0.latitude] }],
            "properties": ["kind": "track", "log": result.logName, "mode": result.mode,
                           "t": result.track.map(\.t), "headingDeg": result.track.map(\.headingDeg),
                           "headingStdDeg": result.track.map(\.headingStdDeg)],
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
            features.append([
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [fix.longitude, fix.latitude]],
                "properties": ["kind": fix.withheld == nil ? "fixUsed" : "fixWithheld",
                               "withheld": fix.withheld?.rawValue ?? "", "t": fix.t,
                               "arrivalT": fix.arrivalT, "accuracyM": fix.accuracyM],
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
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys])
    }
}
