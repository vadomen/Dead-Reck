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
    }

    /// `metrics.json` key: one row per log and mode.
    public var key: String { "\(logName) \(mode)" }
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
        lines.append("Fixes         used \(c.fixesUsed) (network \(c.networkFixesUsed)), ignored stale \(c.fixesIgnoredStale), invalid \(c.fixesIgnoredInvalid), withheld \(result.fixes.filter { $0.withheld != nil }.count)")
        lines.append("Updates       course \(c.courseUpdates), speed \(c.speedUpdates), reseeds \(c.reseeds), manual \(c.manualFixes) (resets \(c.manualResets)), resamples \(c.resamples), ZUPT steps \(c.zuptSteps), stale-speed steps \(c.staleSpeedSteps), parked-stale steps \(c.staleParkedSteps), caught up in bulk \(c.coalescedSteps) (macro steps \(c.macroSteps))")
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
                    + ", truth σ \(m(cp.truthSigmaM)) m, 95 % ellipse \(ellipse(cp))")
            }
        }
        if let clean = byKind[.cleanFix], !clean.isEmpty {
            let errors = clean.compactMap(\.errorM).sorted()
            let median = errors.isEmpty ? nil : errors[errors.count / 2]
            let inside = clean.compactMap(\.inside95).filter { $0 }.count
            lines.append("cleanFix      \(clean.count) withheld clean fixes: median \(m(median)) m, max \(m(errors.last)) m, inside 95 % \(inside)/\(clean.count)")
        }
        lines.append("Consistency   " + consistencyText(result.consistency))
        lines.append("Max error     \(m(result.maxErrorM)) m (\(pct(result.maxErrorPercent)))")
        lines.append("End error     \(m(result.endErrorM)) m (\(pct(result.endErrorPercent)))\(result.endIsTruth ? "" : " [last checkpoint; no truth end]")")
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
        out += "\n\\* no truth `end`: error at the last checkpoint.\n"
        for r in runs {
            out += "\n## \(r.logName) — \(r.mode)\n\n"
            out += "| kind | t s | distance m | error m | % of distance | σ heading ° | inside 95 % | truth σ m | 95 % ellipse |\n|---|---:|---:|---:|---:|---:|---|---:|---|\n"
            for cp in r.checkpoints where cp.kind != .cleanFix {
                out += "| \(cp.kind.rawValue) | \(String(format: "%.1f", cp.t)) | \(m(cp.distanceM)) | \(m(cp.errorM)) | \(pct(cp.errorPercent)) | \(cp.headingStdDeg.map { String(format: "%.1f", $0) } ?? "n/a") | \(cp.inside95.map { $0 ? "yes" : "no" } ?? "n/a") | \(m(cp.truthSigmaM)) | \(ellipse(cp)) |\n"
            }
            let clean = r.checkpoints.filter { $0.kind == .cleanFix }
            if !clean.isEmpty {
                let errors = clean.compactMap(\.errorM).sorted()
                out += "| cleanFix ×\(clean.count) | | | median \(m(errors.isEmpty ? nil : errors[errors.count / 2])), max \(m(errors.last)) | | | \(clean.compactMap(\.inside95).filter { $0 }.count)/\(clean.count) | | |\n"
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
    public static func mergedMetrics(existing: Data?, adding runs: [ReplayMetrics]) throws -> [ReplayMetrics] {
        var byKey: [String: ReplayMetrics] = [:]
        if let existing, let old = try? JSONDecoder().decode([ReplayMetrics].self, from: existing) {
            for run in old { byKey[run.key] = run }
        }
        for run in runs { byKey[run.key] = run }
        return byKey.values.sorted { $0.key < $1.key }
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
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys])
    }
}
