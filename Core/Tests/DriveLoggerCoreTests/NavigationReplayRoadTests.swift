import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.2b: roads in `replay_nav` (docs/N3_PLAN.md, "N3.2" and "Metrics added
/// to replay_nav"). Synthetic packs and drives near (0, 0) only.
@Suite("Navigation replay with roads (N3.2b)")
struct NavigationReplayRoadTests {
    typealias S = SyntheticDrive
    typealias R = NavigationRoadTests

    /// A drive north along x = 0 at 12 m/s from (0, −500), clean fixes
    /// (5 m, course) every second; the street runs along x = 0.
    static func northInputs(seconds: Double = 60) -> (drive: SyntheticDrive, inputs: [NavigationInput]) {
        let drive = R.northDrive(seconds: seconds)
        return (drive, R.shifted(drive, by: (0, -500), fix: S.cleanFix()))
    }

    static func northStreet() throws -> RoadNetwork {
        try R.network([R.street(1, from: (0, -3000), to: (0, 3000))])
    }

    static func options(_ gps: GPSMode = .maskAfter(seconds: 10), roads: RoadNetwork?, particles: Int = 300)
        -> ReplayOptions {
        var options = ReplayOptions(gps: gps, config: S.config(particles: particles, seed: 1))
        options.roads = roads.map(ReplayRoadSet.init)
        return options
    }

    // MARK: Item 1: --roads, the label, validation

    @Test("Mode label: -roads-<first 8 hex of roadSetHash> after every other part; none without roads")
    func label() throws {
        let net = try Self.northStreet()
        var options = Self.options(roads: net)
        let hex = net.roadSetHashHex
        #expect(hex.count == 16)
        #expect(options.label == "mask-after-10-roads-" + hex.prefix(8))
        options.asLive = true
        options.gps = .use
        options.holdOutAccuracyM = 100
        #expect(options.label == "use-holdout-100-as-live-roads-" + hex.prefix(8))
        options.roads = nil
        #expect(options.label == "use-holdout-100-as-live")
    }

    @Test("ReplayRoadSet: equal by the set of the packs' content hashes, in any order; records hash, version, OSM time and grid per pack")
    func roadSetIdentity() throws {
        let aData = try RoadFixture.buildData([R.street(1, from: (0, -300), to: (0, 300))])
        let a = try RoadPack(data: aData)
        let b = try RoadFixture.build([R.street(2, from: (50, -300), to: (50, 300))])
        let ab = ReplayRoadSet(try RoadNetwork(packs: [a, b]))
        let ab2 = ReplayRoadSet(try RoadNetwork(packs: [try RoadPack(data: aData), b]))
        let ba = ReplayRoadSet(try RoadNetwork(packs: [b, a]))
        #expect(ab == ab2 && ab.hashValue == ab2.hashValue)
        // N3.2c item 7: the order given is not part of the identity.
        #expect(ab == ba && ab.hashValue == ba.hashValue && ab.roadSetHashHex == ba.roadSetHashHex)
        #expect(ab.labelSuffix == ba.labelSuffix && ab.packs == ba.packs)
        #expect(ab.packs.map(\.contentHash) == [a.contentHash, b.contentHash].sorted().map(NavigationSeed.hex))
        #expect(ab != ReplayRoadSet(try RoadNetwork(packs: [a])))
        #expect(ab.packs.allSatisfy { $0.formatVersion == 1 && $0.gridID == NavigationSeed.hex(a.gridID) })
        #expect(ab.packs.allSatisfy { $0.osmTimestamp == a.osmTimestamp })
        #expect(ab.roadSetHashHex == NavigationSeed.hex(RoadPackFormat.roadSetHash([a.contentHash, b.contentHash])))
    }

    @Test("R21.3-6: configChanges lists each clamped key (old → new); none for the default config")
    func clampedKeysListed() throws {
        #expect(ReplayReport.configChanges(from: NavigationConfig(), to: NavigationConfig().validated()).isEmpty)
        var c = NavigationConfig()
        c.roadSigmaM = 0
        c.roadUpdateIntervalS = 1e10
        c.lateManualFixWindowS = 1000
        let changes = ReplayReport.configChanges(from: c, to: c.validated())
        #expect(changes == ["lateManualFixWindowS 1000 → 60", "roadSigmaM 0 → 7", "roadUpdateIntervalS 10000000000 → 3600"])
        // The pack's radius clamps roadSearchRadiusM only with that pack.
        c = NavigationConfig()
        c.roadSearchRadiusM = 80
        let net = try Self.northStreet()
        #expect(ReplayReport.configChanges(from: c, to: c.validated()).isEmpty)
        #expect(ReplayReport.configChanges(from: c, to: c.validated(roads: net)) == ["roadSearchRadiusM 80 → 50"])
        // A coupling outside 0…1 is refused, not clamped.
        c.roadAlongTrackCoupling = 2
        #expect(c.validated().invalidReason != nil)
    }

    @Test("A replay with roads runs the road update; without roads none, and the run is as before")
    func replayUsesRoads() throws {
        let (_, inputs) = Self.northInputs()
        let net = try Self.northStreet()
        let with = NavigationReplay.run(logName: "synthetic", inputs: inputs, options: Self.options(roads: net))
        let without = NavigationReplay.run(logName: "synthetic", inputs: inputs, options: Self.options(roads: nil))
        #expect(with.counters.roadUpdates > 30)
        #expect(without.counters.roadUpdates == 0 && without.counters.roadUpdatesNoRoad == 0)
        #expect(with.mode.hasSuffix("-roads-" + net.roadSetHashHex.prefix(8)))
        #expect(without.mode == "mask-after-10")
    }

    // MARK: Items 2-4: road metrics, the road set in every output, GeoJSON

    /// A north drive whose fixes before `maskS` sit `usedEast` m east of the
    /// car (the engine follows them) and whose withheld fixes are on the
    /// car (x = 0, the truth). Position noise 0, so the truth is exact.
    static func splitInputs(usedEast: Double, seconds: Double = 60, maskS: Double = 10) -> [NavigationInput] {
        let drive = R.northDrive(seconds: seconds)
        let clean = S.cleanFix(positionNoise: 0)
        return R.shifted(drive, by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t < maskS { f.east += usedEast }
            return f
        })
    }

    static func run(_ inputs: [NavigationInput], roads: RoadNetwork?, gps: GPSMode = .maskAfter(seconds: 10),
                    tolerance: Double? = nil) -> ReplayResult {
        var options = Self.options(gps, roads: roads)
        if let tolerance { options.wrongRoadToleranceM = tolerance }
        return NavigationReplay.run(logName: "synthetic", inputs: inputs, options: options)
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test("On the right road: every withheld clean fix matched and right, wrong share 0, the road set and attribution in every output")
    func rightRoad() throws {
        let net = try Self.northStreet()
        let result = Self.run(Self.splitInputs(usedEast: 0), roads: net)
        let m = try #require(result.roadMetrics)
        let withheld = result.fixes.filter { $0.withheld != nil && $0.accuracyM <= 15 }.count
        #expect(withheld > 40 && m.withheldCleanFixes == withheld)
        #expect(m.truth == ["matched": withheld])
        #expect(m.fixes.allSatisfy { $0.truthEdge?.osmWayID == 1 && $0.truthClass == "residential" })
        #expect(m.scored == withheld && m.count(.right).fixes == withheld)
        #expect(m.wrongShare == 0 && m.wrongShareByDistance == 0 && m.offShare == 0)
        #expect(m.ambiguousShare == 0 && m.unmapped == 0 && m.unmappedCaptured == 0)
        // Distance weights: OBD distance between consecutive scored fixes
        // (12 m/s at 1 Hz), the first 0.
        #expect(m.fixes[0].weightM == 0)
        #expect(m.fixes.dropFirst().allSatisfy { abs($0.weightM - 12) < 1 }, "\(m.fixes.map(\.weightM))")
        #expect(m.trackSamples > 50 && m.trackOnRoad >= m.trackEngaged - 1 && m.trackEngaged > 50,
                "\(m.trackSamples) \(m.trackEngaged) \(m.trackOnRoad)")
        #expect(try #require(m.residualsAll).p95M < 1)
        #expect(m.residuals.keys.sorted() == ["residential"])
        #expect(m.candidateTestsPerUpdate != nil && result.counters.roadUpdates > 30)
        // R22.4-2: candidate tests per road update, and per particle (300) and update.
        let c = result.counters
        let perUpdate = try #require(m.candidateTestsPerUpdate)
        let perParticle = try #require(m.candidateTestsPerParticle)
        #expect(perUpdate == Double(c.roadCandidateTests) / Double(c.roadUpdates))
        #expect(perParticle == Double(c.roadCandidateTests) / Double(c.roadUpdates) / 300)
        #expect(perParticle == perUpdate / 300)
        // One segment within the search radius, so each particle tests it
        // once per update: 300 per update, 1 per particle.
        #expect(perUpdate == 300 && perParticle == 1, "\(perUpdate) \(perParticle)")
        #expect(ReplayReport.summary(result).contains("(300 per update, 1.0 per particle)"))
        // The road set: result, metrics.json, summary, markdown, GeoJSON.
        #expect(result.roads == ReplayRoadSet(net).packs && result.roadSetHash == net.roadSetHashHex)
        let row = try #require(try JSONSerialization.jsonObject(
            with: ReplayReport.metricsJSON([ReplayMetrics(result)])) as? [[String: Any]])[0]
        #expect(row["roadSetHash"] as? String == net.roadSetHashHex)
        #expect((row["roads"] as? [Any])?.count == 1 && row["roadMetrics"] != nil)
        let summary = ReplayReport.summary(result)
        #expect(summary.contains("roadSetHash \(net.roadSetHashHex)") && summary.contains("© OpenStreetMap contributors"))
        #expect(summary.contains("Wrong road    (capture onto a wrong mapped road only"))
        #expect(summary.contains("Unmapped      0 withheld clean fixes"))
        let markdown = ReplayReport.markdown([ReplayMetrics(result)])
        #expect(markdown.contains("## Roads") && markdown.contains(net.roadSetHashHex) && markdown.contains("© OpenStreetMap contributors"))
        let geo = try #require(try JSONSerialization.jsonObject(with: ReplayReport.geoJSON(result)) as? [String: Any])
        let features = try #require(geo["features"] as? [[String: Any]])
        let track = try #require(features.first?["properties"] as? [String: Any])
        #expect(track["roadSetHash"] as? String == net.roadSetHashHex)
        #expect((track["attribution"] as? String)?.contains("© OpenStreetMap contributors") == true)
        // The matched edge every 10 s (with the ellipses), on way 1.
        let edges = features.compactMap { $0["properties"] as? [String: Any] }.filter { $0["kind"] as? String == "matchedEdge" }
        #expect(edges.count == result.matchedEdges.count && edges.count >= 5)
        #expect(edges.allSatisfy { ($0["osmWayID"] as? NSNumber)?.int64Value == 1 && $0["highway"] as? String == "residential" })
        #expect(result.matchedEdges.allSatisfy { $0.points.count == 2 })
    }

    @Test("Wrong road: the engine on a parallel road 40 m away scores wrong (by fixes and distance); a 50 m tolerance scores it right")
    func wrongRoad() throws {
        let net = try R.network([R.street(1, from: (0, -3000), to: (0, 3000)), R.street(2, from: (40, -3000), to: (40, 3000))])
        let inputs = Self.splitInputs(usedEast: 40)
        let result = Self.run(inputs, roads: net)
        let m = try #require(result.roadMetrics)
        #expect(m.truth["matched"] == m.withheldCleanFixes && m.withheldCleanFixes > 40)
        #expect(m.fixes.allSatisfy { $0.truthEdge?.osmWayID == 1 })
        #expect(m.fixes.allSatisfy { $0.matchedEdge?.osmWayID == 2 }, "the engine left road 2")
        #expect(m.count(.wrong).fixes == m.scored && m.wrongShare == 1 && m.wrongShareByDistance == 1)
        #expect(m.fixes.allSatisfy { abs(($0.matchedEdgeDistanceM ?? 0) - 40) < 0.5 })
        #expect(ReplayReport.summary(result).contains("wrong \(m.scored) (100.0 %; by distance 100.0 %)"))
        let tolerant = try #require(Self.run(inputs, roads: net, tolerance: 50).roadMetrics)
        #expect(tolerant.wrongRoadToleranceM == 50 && tolerant.count(.right).fixes == tolerant.scored && tolerant.wrongShare == 0)
    }

    @Test("Ambiguous truth: two ways 5 m either side of the car tie, so no fix is scored (ambiguous share 1)")
    func ambiguousTruth() throws {
        let net = try R.network([R.street(1, from: (-5, -3000), to: (-5, 3000)), R.street(2, from: (5, -3000), to: (5, 3000))])
        let m = try #require(Self.run(Self.splitInputs(usedEast: 0), roads: net).roadMetrics)
        #expect(m.truth == ["ambiguous": m.withheldCleanFixes] && m.withheldCleanFixes > 40)
        #expect(m.ambiguousShare == 1 && m.scored == 0 && m.wrongShare == nil && m.wrongShareByDistance == nil)
        #expect(m.fixes.allSatisfy { abs($0.logLikelihoodRatio ?? 1) < 1e-6 })
    }

    /// R22.4-1: the street along x = 0 and, 200 m east (beyond the engine's
    /// 50 m search radius), two parallel ways at x = 200 and 205. Withheld
    /// clean fixes at t 15, 20, …, one truth status each: `m` on the car
    /// (matched, way 1), `a` 202.5 m east (between ways 2 and 3: a tie,
    /// ambiguous), `r` 30 m east (way 1 beyond 15 m: no road), `c` with no
    /// course.
    static func mixedTruth(_ kinds: String) throws -> ReplayResult {
        let net = try R.network([R.street(1, from: (0, -3000), to: (0, 3000)),
                                 R.street(2, from: (200, -3000), to: (200, 3000)),
                                 R.street(3, from: (205, -3000), to: (205, 3000))])
        let kinds = Array(kinds)
        let clean = S.cleanFix(positionNoise: 0)
        let inputs = R.shifted(R.northDrive(seconds: 60), by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t <= 10 { return f }
            guard let k = kinds.indices.first(where: { S.at(t, 15 + 5 * Double($0)) }) else { return nil }
            switch kinds[k] {
            case "a": f.east += 202.5
            case "r": f.east += 30
            case "c": f.course = -1; f.courseAccuracy = -1
            default: break
            }
            return f
        })
        return Self.run(inputs, roads: net)
    }

    @Test("R22.4-1 ambiguous share: ambiguous / (matched + ambiguous), not over every withheld fix; the Viterbi warning only above 20 %")
    func ambiguousShareMixed() throws {
        let warning = "; WARNING: over 20 % ambiguous, the plan calls for a Viterbi match (not implemented)"
        // 6 matched, 1 ambiguous, 1 no road, 1 no course: 1 / 7 (1 / 9 over all fixes).
        let low = try Self.mixedTruth("mmamrmcmm")
        let lm = try #require(low.roadMetrics)
        #expect(lm.withheldCleanFixes == 9 && lm.truth == ["matched": 6, "ambiguous": 1, "noRoad": 1, "noCourse": 1])
        #expect(lm.ambiguousShare == 1.0 / 7.0, "\(String(describing: lm.ambiguousShare))")
        let lowSummary = ReplayReport.summary(low)
        #expect(lowSummary.contains("Road truth    (offline) 9 withheld clean fixes: matched 6, ambiguous 1 "
            + "(14.3 % of matched + ambiguous), no heading-compatible road within 15 m 1, no usable course 1\n"), "\(lowSummary)")
        #expect(!lowSummary.contains("WARNING"))
        // 3 matched, 1 ambiguous, 2 no road, 2 no course: 1 / 4 = 25 %, over
        // the 20 % of the warning (1 / 8 = 12.5 % over all fixes is not).
        let high = try Self.mixedTruth("marmcrmc")
        let hm = try #require(high.roadMetrics)
        #expect(hm.withheldCleanFixes == 8 && hm.truth == ["matched": 3, "ambiguous": 1, "noRoad": 2, "noCourse": 2])
        #expect(hm.ambiguousShare == 0.25, "\(String(describing: hm.ambiguousShare))")
        let highSummary = ReplayReport.summary(high)
        #expect(highSummary.contains("Road truth    (offline) 8 withheld clean fixes: matched 3, ambiguous 1 "
            + "(25.0 % of matched + ambiguous), no heading-compatible road within 15 m 2, no usable course 2"
            + warning + "\n"), "\(highSummary)")
    }

    /// The car stays on x = 0 (unmapped: the only road is 40 m east); the
    /// cloud drifts onto way 2 within ~20 s of the mask. Before that it is
    /// on no road (share 0) or still straddling (truth inside its 95 %
    /// ellipse): not captured. From t 30 on it sits on way 2 with share
    /// ≈ 1, a narrow ellipse across it (≈ 12 m) and the truth outside:
    /// captured.
    @Test("R21.1-11 unmapped: a car 40 m beside the only mapped road is unmapped, never scored for wrong road; captured once the cloud sits on that road")
    func unmapped() throws {
        let net = try R.network([R.street(2, from: (40, -3000), to: (40, 3000))])
        let result = Self.run(Self.splitInputs(usedEast: 0, seconds: 120), roads: net)
        let m = try #require(result.roadMetrics)
        #expect(m.withheldCleanFixes == 110 && m.unmapped == 110)
        #expect(m.truth == ["noRoad": 110] && m.scored == 0 && m.wrongShare == nil)
        #expect(m.fixes.allSatisfy { abs(($0.nearestEdgeM ?? 0) - 40) < 0.5 })
        #expect(m.unmappedWithEstimate == 110 && m.unmappedCaptured == 91)
        // R23.1-1: far fixes with a usable course (truth noRoad) take the
        // distance reason, and so does their captured split.
        #expect(m.unmappedNoRoadWithin15 == 110 && m.unmappedNoCompatibleRoadWithin15 == 0)
        #expect(m.unmappedCapturedNoRoadWithin15 == 91 && m.unmappedCapturedNoCompatibleRoadWithin15 == 0)
        #expect(m.fixes.allSatisfy { $0.unmapped && $0.unmappedReason == .noRoadWithin15 })
        for fix in m.fixes {
            if fix.t < 26.5 {
                #expect(fix.onRoadShare == 0 && fix.matchedEdge == nil && fix.captured == false, "t \(fix.t)")
            } else if fix.t < 29.5 {
                #expect(fix.matchedEdge?.osmWayID == 2 && fix.inside95 == true && fix.captured == false, "t \(fix.t)")
            } else {
                #expect((fix.onRoadShare ?? 0) > 0.9 && fix.matchedEdge?.osmWayID == 2, "t \(fix.t)")
                #expect((fix.crossTrackSemiAxisM ?? .infinity) < 25 && fix.inside95 == false, "t \(fix.t)")
                #expect(fix.captured == true, "t \(fix.t)")
            }
        }
    }

    /// R22.1-2: a parallel road 60 m east (way 2) ends at north −100; the
    /// truth stays on way 1 along x = 0. The used fixes put the engine on
    /// way 2, so it scores wrong there; past way 2's end no road lies within
    /// the 50 m search radius (way 1 is 60 m away), the road update finds
    /// no road (share 0) and every fix scores off.
    @Test("R22.1-2 off: engaged but on no road (share < 0.5) while the truth is matched scores off, by fixes and by distance")
    func offVerdict() throws {
        let net = try R.network([R.street(1, from: (0, -3000), to: (0, 3000)), R.street(2, from: (60, -3000), to: (60, -100))])
        let result = Self.run(Self.splitInputs(usedEast: 60), roads: net)
        let m = try #require(result.roadMetrics)
        #expect(m.truth == ["matched": m.withheldCleanFixes] && m.withheldCleanFixes == 50)
        #expect(m.fixes.allSatisfy { $0.truthEdge?.osmWayID == 1 })
        // Truth north of the fix at t: −500 + 12 t. On way 2 up to 50 m
        // before its end: wrong; 50 m or more past its end: off, share 0.
        for fix in m.fixes {
            let north = -500 + 12 * fix.t
            if north < -150 {
                #expect(fix.verdict == .wrong && fix.matchedEdge?.osmWayID == 2, "t \(fix.t)")
            } else if north > -50 {
                #expect(fix.verdict == .off && fix.onRoadShare == 0 && fix.matchedEdge == nil, "t \(fix.t)")
            }
        }
        let off = m.count(.off), wrong = m.count(.wrong)
        #expect(off.fixes >= 20 && wrong.fixes >= 25, "off \(off.fixes) wrong \(wrong.fixes)")
        #expect(off.fixes + wrong.fixes == m.scored && m.scored == 50 && m.count(.right).fixes == 0)
        #expect(m.offShare == Double(off.fixes) / 50 && m.wrongShare == Double(wrong.fixes) / 50)
        let offWeight = m.fixes.filter { $0.verdict == .off }.reduce(0) { $0 + $1.weightM }
        let allWeight = m.fixes.reduce(0) { $0 + $1.weightM }
        #expect(off.distanceM == offWeight && offWeight > 200)
        #expect(abs(try #require(m.offShareByDistance) - offWeight / allWeight) < 1e-12)
        #expect(abs(try #require(m.offShareByDistance) + (m.wrongShareByDistance ?? 0) - 1) < 1e-12)
        #expect(m.count(.notEngaged).fixes == 0)
    }

    @Test("R22.1-2 notEngaged: a cloud always wider than roadEngageMaxEllipseM leaves onRoadShare nil, every matched fix not engaged")
    func notEngagedVerdict() throws {
        var options = Self.options(roads: try Self.northStreet())
        options.config.roadEngageMaxEllipseM = 1e-3
        let result = NavigationReplay.run(logName: "synthetic", inputs: Self.splitInputs(usedEast: 0), options: options)
        let m = try #require(result.roadMetrics)
        #expect(result.counters.roadUpdates == 0 && result.counters.roadUpdatesNoRoad == 0)
        #expect(m.truth == ["matched": 50] && m.scored == 50 && m.count(.notEngaged).fixes == 50)
        #expect(m.fixes.allSatisfy { $0.verdict == .notEngaged && $0.onRoadShare == nil && $0.matchedEdge == nil })
        #expect(m.wrongShare == 0 && m.offShare == 0 && m.wrongShareByDistance == 0 && m.offShareByDistance == 0)
        #expect(m.trackEngaged == 0)
    }

    /// R22.2-1: the engine on the right road (way 1, the only one), with an
    /// off-road probability ε near 1. Each particle's responsibility
    /// r = (1 − ε) L / ((1 − ε) L + ε / (4π R)) is then a fraction, so the
    /// on-road share is strictly between 0 and 1 while the matched edge is
    /// still the truth's: only the share decides between off and right.
    @Test("R22.2-1 off threshold: on-road share 0.37–0.43 on the truth's own edge scores off; 0.56–0.61 scores right")
    func offThreshold() throws {
        let net = try Self.northStreet()
        func metrics(offRoadProbability: Double) throws -> ReplayRoadMetrics {
            var options = Self.options(roads: net)
            options.config.roadOffRoadProbability = offRoadProbability
            let result = NavigationReplay.run(logName: "synthetic", inputs: Self.splitInputs(usedEast: 0), options: options)
            return try #require(result.roadMetrics)
        }
        // ε 0.99: share 0.37…0.43 at every withheld fix, below 0.5 but not 0.
        let below = try metrics(offRoadProbability: 0.99)
        #expect(below.truth == ["matched": 50] && below.scored == 50)
        for fix in below.fixes {
            let share = try #require(fix.onRoadShare)
            #expect(share > 0.36 && share < 0.44, "t \(fix.t) share \(share)")
            #expect(fix.matchedEdge?.osmWayID == 1 && fix.truthEdge?.osmWayID == 1, "t \(fix.t)")
            #expect(fix.verdict == .off, "t \(fix.t) share \(share)")
        }
        #expect(below.count(.off).fixes == 50 && below.offShare == 1 && below.offShareByDistance == 1)
        // ε 0.98: share 0.55…0.61, just above 0.5: right.
        let above = try metrics(offRoadProbability: 0.98)
        #expect(above.truth == ["matched": 50] && above.scored == 50)
        for fix in above.fixes {
            let share = try #require(fix.onRoadShare)
            #expect(share > 0.55 && share < 0.61, "t \(fix.t) share \(share)")
            #expect(fix.matchedEdge?.osmWayID == 1, "t \(fix.t)")
            #expect(fix.verdict == .right, "t \(fix.t) share \(share)")
        }
        #expect(above.count(.right).fixes == 50 && above.offShare == 0 && above.wrongShare == 0)
    }

    /// R22.1-3: way 1 along x = 0 with a 40 m gap (north 100…140, way 2
    /// beyond it); the used fixes put the engine on it, heading north, and a large
    /// along-track noise makes the 95 % ellipse long along the road and
    /// narrow across it. Two withheld clean fixes, both unmapped: at t 30 one
    /// 200 m east of the car (outside the ellipse: captured); at t 40 one in
    /// the middle of the gap, 20 m from each road end and 140 m ahead of
    /// the car (inside the ellipse: not captured).
    @Test("R22.1-3 captured: an on-edge, narrow-ellipse estimate counts as captured only with the unmapped truth outside its 95 % ellipse")
    func capturedNeedsTruthOutsideEllipse() throws {
        let net = try R.network([R.street(1, from: (0, -3000), to: (0, 100)), R.street(2, from: (0, 140), to: (0, 3000))])
        let drive = R.northDrive(seconds: 60)
        let clean = S.cleanFix(positionNoise: 0)
        let inputs = R.shifted(drive, by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t <= 10 { return f }
            if S.at(t, 30) { f.east += 200; return f }
            if S.at(t, 40) { f.north = 120 + 500; return f }
            return nil
        })
        var options = Self.options(roads: net)
        options.config.alongTrackNoisePerSqrtM = 6
        let result = NavigationReplay.run(logName: "synthetic", inputs: inputs, options: options)
        let m = try #require(result.roadMetrics)
        #expect(m.withheldCleanFixes == 2 && m.truth == ["noRoad": 2] && m.scored == 0)
        #expect(m.unmapped == 2 && m.unmappedWithEstimate == 2 && m.unmappedCaptured == 1)
        try #require(m.fixes.count == 2)
        let (beside, inGap) = (m.fixes[0], m.fixes[1])
        #expect(abs(beside.t - 30) < 0.1 && abs(inGap.t - 40) < 0.1)
        // 200 m east: no edge within the 50 m search radius at all.
        #expect(beside.nearestEdgeM == nil && abs((inGap.nearestEdgeM ?? 0) - 20) < 0.5)
        for fix in m.fixes {
            // On an edge with a narrow ellipse across it: only the truth's
            // place relative to the ellipse tells the two apart.
            #expect((fix.onRoadShare ?? 0) >= 0.5 && fix.matchedEdge?.osmWayID == 1, "t \(fix.t) share \(String(describing: fix.onRoadShare))")
            #expect((fix.crossTrackSemiAxisM ?? .infinity) < 25, "t \(fix.t) across \(String(describing: fix.crossTrackSemiAxisM))")
            #expect(fix.verdict == nil && fix.unmapped)
        }
        #expect(beside.inside95 == false && beside.captured == true)
        #expect(inGap.inside95 == true && inGap.captured == false)
        #expect(ReplayReport.summary(result).contains("Unmapped      2 withheld clean fixes"))
    }

    /// R22.2-2: one mapped road along x = 0, the engine on it (long
    /// ellipse along it, as above), two withheld clean fixes 200 m east of
    /// the car (t 30, 40): unmapped, on no road within the search radius,
    /// and far outside the ellipse. The default cross-track noise keeps the
    /// ellipse ≈ 12 m across the road: captured. Five times that noise
    /// widens it to ≈ 31 m, with share, edge and the truth's place
    /// unchanged: not captured.
    @Test("R22.2-2 captured needs a narrow ellipse: on the edge, truth outside, but ≥ 25 m across the road is not captured")
    func capturedNeedsNarrowCrossTrack() throws {
        let net = try Self.northStreet()
        let drive = R.northDrive(seconds: 60)
        let clean = S.cleanFix(positionNoise: 0)
        let inputs = R.shifted(drive, by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t <= 10 { return f }
            if S.at(t, 30) || S.at(t, 40) { f.east += 200; return f }
            return nil
        })
        func metrics(crossTrackNoise: Double) throws -> ReplayRoadMetrics {
            var options = Self.options(roads: net)
            options.config.alongTrackNoisePerSqrtM = 6
            options.config.crossTrackNoisePerSqrtM = crossTrackNoise
            let result = NavigationReplay.run(logName: "synthetic", inputs: inputs, options: options)
            let m = try #require(result.roadMetrics)
            #expect(m.withheldCleanFixes == 2 && m.truth == ["noRoad": 2] && m.unmapped == 2 && m.unmappedWithEstimate == 2)
            for fix in m.fixes {
                #expect(fix.nearestEdgeM == nil && fix.unmapped && fix.verdict == nil, "t \(fix.t)")
                #expect((fix.onRoadShare ?? 0) > 0.9 && fix.matchedEdge?.osmWayID == 1, "t \(fix.t)")
                #expect(fix.inside95 == false, "t \(fix.t)")
            }
            return m
        }
        let narrow = try metrics(crossTrackNoise: 0.6)
        #expect(narrow.fixes.allSatisfy { ($0.crossTrackSemiAxisM ?? .infinity) > 10 && ($0.crossTrackSemiAxisM ?? .infinity) < 15 },
                "\(narrow.fixes.map(\.crossTrackSemiAxisM))")
        #expect(narrow.fixes.allSatisfy { $0.captured == true } && narrow.unmappedCaptured == 2)
        let wide = try metrics(crossTrackNoise: 3)
        #expect(wide.fixes.allSatisfy { ($0.crossTrackSemiAxisM ?? 0) > 28 && ($0.crossTrackSemiAxisM ?? 0) < 35 },
                "\(wide.fixes.map(\.crossTrackSemiAxisM))")
        #expect(wide.fixes.allSatisfy { $0.captured == false } && wide.unmappedCaptured == 0)
    }

    // MARK: N3.2c item 2: unmapped also when no heading-compatible road lies within 15 m

    /// A southbound oneway 10 m east of the car (x = 10), the only road; the
    /// car drives north on x = 0. Every withheld clean fix has an edge
    /// 10 m away, but against the oneway's direction: no heading-compatible
    /// road within 15 m (truth noRoad), so unmapped.
    static func southboundOneway(at x: Double = 10) throws -> RoadNetwork {
        try RoadNetwork(packs: [RoadFixture.build([
            RoadFixture.way(2, ["highway": "residential", "oneway": "yes"], [
                RoadFixture.Node(id: 20, east: x, north: 3000), RoadFixture.Node(id: 21, east: x, north: -3000),
            ]),
        ])])
    }

    @Test("Item 2: a fix 10 m from an edge whose heading is incompatible (a oneway the other way) is unmapped")
    func unmappedIncompatibleHeading() throws {
        let result = Self.run(Self.splitInputs(usedEast: 0), roads: try Self.southboundOneway())
        let m = try #require(result.roadMetrics)
        #expect(m.withheldCleanFixes == 50 && m.truth == ["noRoad": 50])
        #expect(m.fixes.allSatisfy { abs(($0.nearestEdgeM ?? 0) - 10) < 0.5 })
        #expect(m.fixes.allSatisfy { $0.unmapped && $0.verdict == nil })
        #expect(m.unmapped == 50 && m.unmappedWithEstimate == 50)
        #expect(m.fixes.allSatisfy { $0.unmappedReason == .noCompatibleRoadWithin15 })
        #expect(m.unmappedNoRoadWithin15 == 0 && m.unmappedNoCompatibleRoadWithin15 == 50)
        // Captured follows the widened set; the split adds up.
        #expect(m.unmappedCaptured == m.fixes.filter { $0.captured == true }.count)
        #expect((m.unmappedCapturedNoRoadWithin15 ?? -1) + (m.unmappedCapturedNoCompatibleRoadWithin15 ?? -1) == m.unmappedCaptured)
        #expect(m.unmappedCapturedNoRoadWithin15 == 0)
        // Both sub-counts in the summary, metrics.md and metrics.json.
        #expect(ReplayReport.summary(result).contains("Unmapped      50 withheld clean fixes with no heading-compatible road within 15 m"
            + " (> 15 m from every edge 0 + only incompatible edges within 15 m 50; no usable course: distance only)"),
                "\(ReplayReport.summary(result))")
        #expect(ReplayReport.markdown([ReplayMetrics(result)]).contains(" | 50 (0 + 50) / \(m.unmappedCaptured) (0 + \(m.unmappedCaptured)) | "))
        let row = try #require(try JSONSerialization.jsonObject(
            with: ReplayReport.metricsJSON([ReplayMetrics(result)])) as? [[String: Any]])[0]
        let road = try #require(row["roadMetrics"] as? [String: Any])
        #expect(road["unmapped"] as? Int == 50 && road["unmappedNoRoadWithin15"] as? Int == 0
            && road["unmappedNoCompatibleRoadWithin15"] as? Int == 50)
        #expect(road["unmappedCapturedNoRoadWithin15"] as? Int == 0
            && road["unmappedCapturedNoCompatibleRoadWithin15"] as? Int == m.unmappedCaptured)
        #expect((road["fixes"] as? [[String: Any]])?.first?["unmappedReason"] as? String == "noCompatibleRoadWithin15")
        // A row written before item 2 (no split, no reason) still decodes.
        var old = road
        for key in ["unmappedNoRoadWithin15", "unmappedNoCompatibleRoadWithin15", "unmappedCapturedNoRoadWithin15",
                    "unmappedCapturedNoCompatibleRoadWithin15"] { old[key] = nil }
        old["fixes"] = (road["fixes"] as? [[String: Any]])?.map { var f = $0; f["unmappedReason"] = nil; return f }
        let decoded = try JSONDecoder().decode(ReplayRoadMetrics.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.unmapped == 50 && decoded.unmappedNoRoadWithin15 == nil && decoded.fixes.allSatisfy { $0.unmappedReason == nil })
        #expect(ReplayReport.unmappedSplit(decoded.unmappedNoRoadWithin15, decoded.unmappedNoCompatibleRoadWithin15, " (%d + %d)") == "")
    }

    /// One drive past both cases: the road at x = 10 is two-way south of
    /// north 0 (heading-compatible: the truth is matched, not unmapped) and
    /// a southbound oneway north of it (incompatible: unmapped).
    @Test("Item 2: along one drive, a compatible edge within 15 m is not unmapped and an incompatible one is")
    func unmappedCompatibleVersusIncompatible() throws {
        typealias N = RoadFixture.Node
        let net = try RoadNetwork(packs: [RoadFixture.build([
            RoadFixture.way(3, ["highway": "residential"], [N(id: 30, east: 10, north: -3000), N(id: 31, east: 10, north: 0)]),
            RoadFixture.way(2, ["highway": "residential", "oneway": "yes"], [N(id: 20, east: 10, north: 3000), N(id: 31, east: 10, north: 0)]),
        ])])
        let m = try #require(Self.run(Self.splitInputs(usedEast: 0), roads: net).roadMetrics)
        let north = { (fix: ReplayRoadFix) in -500 + 12 * fix.t }
        let south = m.fixes.filter { north($0) < -20 }, ahead = m.fixes.filter { north($0) > 20 }
        #expect(south.count >= 25 && ahead.count >= 15, "\(south.count) \(ahead.count)")
        for fix in south {
            #expect(fix.truth == .matched && fix.truthEdge?.osmWayID == 3, "t \(fix.t)")
            #expect(!fix.unmapped && fix.unmappedReason == nil && fix.captured == nil, "t \(fix.t)")
        }
        for fix in ahead {
            #expect(fix.truth == .noRoad && abs((fix.nearestEdgeM ?? 0) - 10) < 0.5, "t \(fix.t)")
            #expect(fix.unmapped && fix.unmappedReason == .noCompatibleRoadWithin15 && fix.captured != nil, "t \(fix.t)")
        }
        let unmapped = m.fixes.filter(\.unmapped)
        #expect(m.unmapped == unmapped.count && m.unmapped >= ahead.count && m.unmapped < m.withheldCleanFixes - south.count + 1)
        #expect(m.unmappedNoRoadWithin15 == 0 && m.unmappedNoCompatibleRoadWithin15 == m.unmapped)
    }

    /// R23.1-1: a non-zero captured split. The engine is on the street
    /// along x = 0 (long ellipse along it, narrow across, as R22.1-3).
    /// Three withheld clean fixes, all with the car's course (north) and
    /// all far outside the ellipse, so all three are captured: at t 30 and
    /// t 35, 200 m east, 5 m from a southbound oneway at x = 205 (no
    /// heading-compatible road within 15 m); at t 40, 400 m east, no edge
    /// within the search radius (> 15 m from every edge). Split 1 + 2, so a
    /// swap of the two counters shows.
    @Test("Item 2 (R23.1-1): captured follows the widened set, split by reason: 1 far + 2 incompatible")
    func capturedSplitByReason() throws {
        typealias N = RoadFixture.Node
        let net = try RoadNetwork(packs: [RoadFixture.build([
            R.street(1, from: (0, -3000), to: (0, 3000)),
            RoadFixture.way(2, ["highway": "residential", "oneway": "yes"],
                            [N(id: 20, east: 205, north: 3000), N(id: 21, east: 205, north: -3000)]),
        ])])
        let drive = R.northDrive(seconds: 60)
        let clean = S.cleanFix(positionNoise: 0)
        let inputs = R.shifted(drive, by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t <= 10 { return f }
            if S.at(t, 30) || S.at(t, 35) { f.east += 200; return f }
            if S.at(t, 40) { f.east += 400; return f }
            return nil
        })
        var options = Self.options(roads: net)
        options.config.alongTrackNoisePerSqrtM = 6
        let result = NavigationReplay.run(logName: "synthetic", inputs: inputs, options: options)
        let m = try #require(result.roadMetrics)
        try #require(m.fixes.count == 3)
        #expect(m.fixes.map(\.truth) == [.noRoad, .noRoad, .noRoad])
        #expect(m.fixes.map(\.unmappedReason) == [.noCompatibleRoadWithin15, .noCompatibleRoadWithin15, .noRoadWithin15])
        #expect(abs((m.fixes[0].nearestEdgeM ?? 0) - 5) < 0.5 && abs((m.fixes[1].nearestEdgeM ?? 0) - 5) < 0.5)
        #expect(m.fixes[2].nearestEdgeM == nil)
        for fix in m.fixes {
            #expect((fix.onRoadShare ?? 0) >= 0.5 && fix.matchedEdge?.osmWayID == 1, "t \(fix.t)")
            #expect((fix.crossTrackSemiAxisM ?? .infinity) < 25 && fix.inside95 == false, "t \(fix.t)")
            #expect(fix.captured == true, "t \(fix.t)")
        }
        #expect(m.unmapped == 3 && m.unmappedNoRoadWithin15 == 1 && m.unmappedNoCompatibleRoadWithin15 == 2)
        #expect(m.unmappedCaptured > 0 && m.unmappedCaptured == 3)
        #expect(m.unmappedCapturedNoRoadWithin15 == 1 && m.unmappedCapturedNoCompatibleRoadWithin15 == 2)
        #expect(ReplayReport.summary(result).contains("captured 3 (1 + 2)"))
    }

    /// The southbound oneway 10 m east again. Withheld fixes with a usable
    /// course are unmapped (incompatible); those without one (course −1,
    /// or creeping at 2 m/s) keep the distance-only rule: 10 m from an
    /// edge, so not unmapped. A no-course fix 200 m east of the car is
    /// > 15 m from every edge: unmapped by distance.
    @Test("Item 2: a fix with no usable course keeps the distance-only rule (never dropped, never added by heading)")
    func unmappedNoCourseDistanceOnly() throws {
        let drive = R.northDrive(seconds: 50)
        let clean = S.cleanFix(positionNoise: 0)
        let inputs = R.shifted(drive, by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t <= 10 || S.at(t, 20) || S.at(t, 30) { return f }
            if S.at(t, 25) { f.course = -1; f.courseAccuracy = -1; return f }
            if S.at(t, 27) { f.speed = 2; return f }
            if S.at(t, 40) { f.east += 200; f.course = -1; f.courseAccuracy = -1; return f }
            return nil
        })
        let m = try #require(Self.run(inputs, roads: try Self.southboundOneway()).roadMetrics)
        try #require(m.fixes.count == 5)
        #expect(m.fixes.map(\.truth) == [.noRoad, .noCourse, .noCourse, .noRoad, .noCourse])
        #expect(m.fixes.map(\.unmapped) == [true, false, false, true, true])
        #expect(m.fixes.map(\.unmappedReason) == [.noCompatibleRoadWithin15, nil, nil, .noCompatibleRoadWithin15, .noRoadWithin15])
        #expect(m.fixes[4].nearestEdgeM == nil)
        #expect(m.unmapped == 3 && m.unmappedNoRoadWithin15 == 1 && m.unmappedNoCompatibleRoadWithin15 == 2)
    }

    /// R22.2-3: withheld clean fixes on the street at t 20 and t 30 (with a
    /// course), and between them two without a usable course: t 25 with no
    /// course (−1), t 27 creeping (speed 2 m/s < 3). OBD reads 43 km/h
    /// (12 m/s truncated), so 43.5 km/h after the +0.5: 120.83 m in 10 s.
    @Test("R22.2-3 distance weights skip fixes without a usable course: the next scored fix weighs the OBD distance since the last scored one")
    func weightsSkipNoCourseFixes() throws {
        let net = try Self.northStreet()
        let drive = R.northDrive(seconds: 40)
        let clean = S.cleanFix(positionNoise: 0)
        let inputs = R.shifted(drive, by: (0, -500), fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            if t <= 10 || S.at(t, 20) || S.at(t, 30) { return f }
            if S.at(t, 25) { f.course = -1; f.courseAccuracy = -1; return f }
            if S.at(t, 27) { f.speed = 2; return f }
            return nil
        })
        let m = try #require(Self.run(inputs, roads: net).roadMetrics)
        try #require(m.fixes.count == 4)
        #expect(m.fixes.map(\.truth) == [.matched, .noCourse, .noCourse, .matched])
        #expect(m.fixes.map(\.verdict) == [.right, nil, nil, .right])
        #expect(m.fixes[0].weightM == 0)
        // Untouched: no weight for a fix without a usable course.
        #expect(m.fixes[1].weightM == 0 && m.fixes[2].weightM == 0)
        // t 20 → t 30 at 43.5 km/h, not t 27 → t 30 (36.25 m).
        #expect(abs(m.fixes[3].weightM - 120.833) < 0.01, "\(m.fixes.map(\.weightM))")
        #expect(m.count(.right).fixes == 2 && abs(m.count(.right).distanceM - 120.833) < 0.01)
    }

    /// R22.1-4: dual carriageway, oneways 15 m apart: way 1 northbound along
    /// x = 0, way 2 southbound along x = 15 (as engine test 6).
    @Test("R22.1-4 truth oneway rule: a oneway counts in its driving direction only, nearer or not")
    func truthOnewayRule() throws {
        typealias N = RoadFixture.Node
        let northbound = RoadFixture.way(1, ["highway": "primary", "oneway": "yes"],
                                         [N(id: 10, east: 0, north: -3000), N(id: 11, east: 0, north: 3000)])
        let southbound = RoadFixture.way(2, ["highway": "primary", "oneway": "yes"],
                                         [N(id: 20, east: 15, north: 3000), N(id: 21, east: 15, north: -3000)])
        let matcher = RoadTruthMatcher(network: try R.network([northbound, southbound]))
        func match(east: Double, course: Double, courseAccuracy: Double = 2,
                   _ m: RoadTruthMatcher = matcher) -> RoadTruthMatcher.Match {
            let p = S.plane.geodetic(east: east, north: 100)
            return m.match(latitude: p.latitude, longitude: p.longitude, accuracyM: 5, courseDeg: course,
                           courseAccuracyDeg: courseAccuracy)
        }
        // 12 m east: 3 m from the southbound carriageway, 12 m from the
        // northbound one. Heading north: the northbound way, matched, with
        // no competitor at all (the southbound oneway is not one).
        let north = match(east: 12, course: 0)
        #expect(north.status == .matched && north.edge?.osmWayID == 1)
        #expect(north.logLikelihoodRatio == nil && abs((north.crossTrackM ?? 0) - 12) < 0.1)
        #expect(abs((north.nearestM ?? 0) - 3) < 0.1, "the nearest edge, any heading, is still the southbound one")
        // A course known only to ±180°: the southbound oneway still does not count.
        let vague = match(east: 12, course: 0, courseAccuracy: 180)
        #expect(vague.status == .matched && vague.edge?.osmWayID == 1 && vague.logLikelihoodRatio == nil)
        // Heading south at the same point: the southbound way.
        let south = match(east: 12, course: 180)
        #expect(south.status == .matched && south.edge?.osmWayID == 2 && south.logLikelihoodRatio == nil)
        // 16 m east heading north: the northbound way is beyond 15 m and the
        // southbound one (1 m) runs against the course: no road.
        let beyond = match(east: 16, course: 0)
        #expect(beyond.status == .noRoad && beyond.edge == nil && abs((beyond.nearestM ?? 0) - 1) < 0.1)
        // The same geometry with way 2 two-way: heading north it is a
        // competitor at 3 m and wins.
        let twoWay = R.street(2, from: (15, 3000), to: (15, -3000), tags: ["highway": "primary"])
        let both = match(east: 12, course: 0, RoadTruthMatcher(network: try R.network([northbound, twoWay])))
        #expect(both.status == .matched && both.edge?.osmWayID == 2 && (both.logLikelihoodRatio ?? 0) > 1)
    }

    /// The truth match of a fix at (`east`, 100) with accuracy 5 m (σ_fix
    /// 5 / 1.51, so σ_fix² + σr² = 59.964 m²).
    static func truthMatch(_ matcher: RoadTruthMatcher, east: Double = 0, course: Double = 0,
                           courseAccuracy: Double = 2) -> RoadTruthMatcher.Match {
        let p = S.plane.geodetic(east: east, north: 100)
        return matcher.match(latitude: p.latitude, longitude: p.longitude, accuracyM: 5, courseDeg: course,
                             courseAccuracyDeg: courseAccuracy)
    }

    /// R22.3-1: two parallel two-way ways, the fix on way 1 (x = 0) heading
    /// along them, way 2 at x = `b`: ln ratio = b² / (2 · 59.964), equal to
    /// ln 2 at b = 9.117 m.
    @Test("R22.3-1 truth margin: matched from a likelihood ratio of 2 on, ambiguous just below it")
    func truthMarginThreshold() throws {
        func match(wayTwoEast b: Double) throws -> RoadTruthMatcher.Match {
            let net = try R.network([R.street(1, from: (0, -3000), to: (0, 3000)),
                                     R.street(2, from: (b, -3000), to: (b, 3000))])
            return Self.truthMatch(RoadTruthMatcher(network: net))
        }
        // b = 9 m: ln ratio 0.6754 < ln 2 = 0.6931: ambiguous (a margin
        // of 1.01 would call it matched).
        let below = try match(wayTwoEast: 9)
        #expect(below.status == .ambiguous && below.edge?.osmWayID == 1, "\(below)")
        #expect(abs((below.logLikelihoodRatio ?? 0) - 0.6754) < 0.003, "\(String(describing: below.logLikelihoodRatio))")
        // b = 9.25 m: ln ratio 0.7134 > ln 2: matched (a margin of 4,
        // ln 1.386, would call it ambiguous).
        let above = try match(wayTwoEast: 9.25)
        #expect(above.status == .matched && above.edge?.osmWayID == 1, "\(above)")
        #expect(abs((above.logLikelihoodRatio ?? 0) - 0.7134) < 0.003, "\(String(describing: above.logLikelihoodRatio))")
    }

    /// R22.3-2: heading north, way 1 along the course 6 m west of the fix,
    /// way 2 at 30° (inside the 45° gate) 5 m from it. Distance terms
    /// −36 / 119.93 and −25 / 119.93; heading term of way 2
    /// −(30°)² / (2 (σ_course² + (10°)²)), σ_course = max(courseAccuracy, 2°).
    @Test("R22.3-2 truth heading term: an aligned way beats a nearer one at 30°, unless the course is vague")
    func truthHeadingTerm() throws {
        let c = cos(Double.pi / 6), s = sin(Double.pi / 6)
        // The point of way 2 nearest the fix is 5 m along the normal (cos 30°, −sin 30°).
        let foot = (5 * c, 100 - 5 * s)
        let angled = R.street(2, from: (foot.0 - 10 * s, foot.1 - 10 * c), to: (foot.0 + 100 * s, foot.1 + 100 * c))
        let net = try R.network([R.street(1, from: (-6, -3000), to: (-6, 3000)), angled])
        let matcher = RoadTruthMatcher(network: net)
        // Course ±2°: heading term 4.3269, ln ratio 4.2352: the aligned way, matched.
        let sharp = Self.truthMatch(matcher)
        #expect(sharp.status == .matched && sharp.edge?.osmWayID == 1, "\(sharp)")
        #expect(abs((sharp.crossTrackM ?? 0) - 6) < 0.05 && abs((sharp.nearestM ?? 0) - 5) < 0.05)
        #expect(abs((sharp.logLikelihoodRatio ?? 0) - 4.2352) < 0.003, "\(String(describing: sharp.logLikelihoodRatio))")
        // Course ±60°: heading term 0.1216, ln ratio 0.0299: still the
        // aligned way, but ambiguous.
        let vague = Self.truthMatch(matcher, courseAccuracy: 60)
        #expect(vague.status == .ambiguous && vague.edge?.osmWayID == 1, "\(vague)")
        #expect(abs((vague.logLikelihoodRatio ?? 0) - 0.0299) < 0.003, "\(String(describing: vague.logLikelihoodRatio))")
        // Course ±90°: heading term 0.0549 no longer outweighs the metre:
        // the nearer way at 30°, ln ratio 0.0368, ambiguous.
        let lost = Self.truthMatch(matcher, courseAccuracy: 90)
        #expect(lost.status == .ambiguous && lost.edge?.osmWayID == 2, "\(lost)")
        #expect(abs((lost.crossTrackM ?? 0) - 5) < 0.05)
        #expect(abs((lost.logLikelihoodRatio ?? 0) - 0.0368) < 0.003, "\(String(describing: lost.logLikelihoodRatio))")
    }

    /// A two-way way at `angle`° east of north whose nearest point to the
    /// fix (0, 100) is 5 m away along the normal (cos, −sin).
    static func angledStreet(_ id: Int64, angle: Double) -> String {
        let a = angle * .pi / 180
        let c = cos(a), s = sin(a)
        let foot = (5 * c, 100 - 5 * s)
        return R.street(id, from: (foot.0 - 50 * s, foot.1 - 50 * c), to: (foot.0 + 50 * s, foot.1 + 50 * c))
    }

    /// R22.4-3: the truth's 45° heading gate applies to two-way ways too.
    /// The fix heads north at (0, 100).
    @Test("R22.4-3 truth heading gate: a two-way way at 60° is no road and no competitor; one at 40° is inside the gate")
    func truthHeadingGate() throws {
        // Alone, 5 m away at 60°: outside the gate, no road (the nearest
        // edge, any heading, is still that way).
        let alone = Self.truthMatch(RoadTruthMatcher(network: try R.network([Self.angledStreet(2, angle: 60)])))
        #expect(alone.status == .noRoad && alone.edge == nil, "\(alone)")
        #expect(abs((alone.nearestM ?? 0) - 5) < 0.05, "\(String(describing: alone.nearestM))")
        // Beside an aligned way 6 m west: matched on the aligned way with no
        // competitor (ratio nil), though the 60° way is nearer.
        let beside = Self.truthMatch(RoadTruthMatcher(network: try R.network([
            R.street(1, from: (-6, -3000), to: (-6, 3000)), Self.angledStreet(2, angle: 60)])))
        #expect(beside.status == .matched && beside.edge?.osmWayID == 1 && beside.logLikelihoodRatio == nil, "\(beside)")
        #expect(abs((beside.crossTrackM ?? 0) - 6) < 0.05 && abs((beside.nearestM ?? 0) - 5) < 0.05)
        // Alone at 40°: inside the gate, matched on it.
        let inside = Self.truthMatch(RoadTruthMatcher(network: try R.network([Self.angledStreet(2, angle: 40)])))
        #expect(inside.status == .matched && inside.edge?.osmWayID == 2 && inside.logLikelihoodRatio == nil, "\(inside)")
        #expect(abs((inside.crossTrackM ?? 0) - 5) < 0.05)
    }

    @Test("A fix the gate rejects as off-road is marked in the result, the road metrics and the GeoJSON")
    func rejectedFix() throws {
        let net = try R.network([R.street(1, from: (0, -3000), to: (0, 3000)), R.street(2, from: (300, -3000), to: (300, 3000))])
        let drive = R.northDrive(seconds: 60, speed: 15)
        let clean = S.cleanFix()
        let inputs = R.shifted(drive, by: (0, -500), fix: { t, s, r in
            if t < 10 { return clean(t, s, &r) }
            if S.at(t, 40) { var f = clean(t, s, &r)!; f.east += 200; return f }
            return nil
        })
        var options = Self.options(.use, roads: net, particles: 400)
        options.config = R.config(particles: 400)
        let result = NavigationReplay.run(logName: "synthetic", inputs: inputs, options: options)
        #expect(result.counters.fixesRejectedOffRoad == 1)
        let rejected = result.fixes.filter { $0.rejectedOffRoad == true }
        #expect(rejected.count == 1 && abs((rejected.first?.t ?? 0) - 40) < 0.1)
        #expect(result.roadMetrics?.rejectedFixes.count == 1)
        let geo = Self.text(try ReplayReport.geoJSON(result))
        #expect(geo.components(separatedBy: "\"fixRejectedOffRoad\"").count == 2)
        #expect(ReplayReport.summary(result).contains("Rejected      off-road fixes (t s, acc m): 40.0/5"))
    }

    @Test("Without roads no road key reaches metrics.json, the summary or the GeoJSON")
    func noRoadKeysWithoutRoads() throws {
        let result = Self.run(Self.splitInputs(usedEast: 0), roads: nil)
        #expect(result.roads == nil && result.roadSetHash == nil && result.roadMetrics == nil && result.matchedEdges.isEmpty)
        let json = Self.text(try ReplayReport.metricsJSON([ReplayMetrics(result)]))
        let geo = Self.text(try ReplayReport.geoJSON(result))
        for key in ["roads", "roadSetHash", "roadMetrics", "matchedEdge", "rejectedOffRoad", "attribution"] {
            #expect(!json.contains("\"\(key)\""), "\(key)")
            #expect(!geo.contains("\"\(key)\""), "\(key)")
        }
        #expect(!ReplayReport.summary(result).contains("Road"))
        #expect(!ReplayReport.markdown([ReplayMetrics(result)]).contains("## Roads"))
    }

    @Test("DistanceStats: nearest-rank p50 and p95; nil for no values")
    func distanceStats() throws {
        let s = try #require(DistanceStats((1...20).map(Double.init).reversed()))
        #expect(s.count == 20 && s.p50M == 10 && s.p95M == 19 && s.maxM == 20)
        #expect(DistanceStats([]) == nil)
        let one = try #require(DistanceStats([3]))
        #expect(one.p50M == 3 && one.p95M == 3)
    }

    @Test("Road truth course: valid course and speed at 3 m/s or more; a stopped or creeping fix has none")
    func roadTruthCourse() {
        func sample(speed: Double, course: Double) -> LocationSample {
            LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                           speed: speed, speedAccuracy: 0.3, course: course, courseAccuracy: 2,
                           receivedT: S.ms(0), ageS: 0)
        }
        #expect(NavigationReplay.RoadTruth.course(of: sample(speed: 3, course: 90)) == 90)
        #expect(NavigationReplay.RoadTruth.course(of: sample(speed: 2.9, course: 90)) == nil)
        #expect(NavigationReplay.RoadTruth.course(of: sample(speed: 10, course: -1)) == nil)
        #expect(NavigationReplay.RoadTruth.course(of: sample(speed: -1, course: 90)) == nil)
    }
}
