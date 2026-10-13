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

    @Test("ReplayRoadSet: equal by the packs' content hashes in load order; records hash, version, OSM time and grid per pack")
    func roadSetIdentity() throws {
        let aData = try RoadFixture.buildData([R.street(1, from: (0, -300), to: (0, 300))])
        let a = try RoadPack(data: aData)
        let b = try RoadFixture.build([R.street(2, from: (50, -300), to: (50, 300))])
        let ab = ReplayRoadSet(try RoadNetwork(packs: [a, b]))
        let ab2 = ReplayRoadSet(try RoadNetwork(packs: [try RoadPack(data: aData), b]))
        let ba = ReplayRoadSet(try RoadNetwork(packs: [b, a]))
        #expect(ab == ab2 && ab.hashValue == ab2.hashValue)
        #expect(ab != ba && ab.roadSetHashHex != ba.roadSetHashHex)
        #expect(ab.packs.map(\.contentHash) == [NavigationSeed.hex(a.contentHash), NavigationSeed.hex(b.contentHash)])
        #expect(ab.packs.allSatisfy { $0.formatVersion == 1 && $0.gridID == NavigationSeed.hex(a.gridID) })
        #expect(ab.packs[0].osmTimestamp == a.osmTimestamp)
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

    @Test("R21.1-11 unmapped: a car 40 m beside the only mapped road is unmapped, never scored for wrong road; captured is exactly its definition")
    func unmapped() throws {
        let net = try R.network([R.street(2, from: (40, -3000), to: (40, 3000))])
        let result = Self.run(Self.splitInputs(usedEast: 0, seconds: 120), roads: net)
        let m = try #require(result.roadMetrics)
        #expect(m.withheldCleanFixes > 100 && m.unmapped == m.withheldCleanFixes)
        #expect(m.truth == ["noRoad": m.withheldCleanFixes] && m.scored == 0 && m.wrongShare == nil)
        #expect(m.fixes.allSatisfy { abs(($0.nearestEdgeM ?? 0) - 40) < 0.5 })
        #expect(m.unmappedWithEstimate == m.unmapped)
        for fix in m.fixes {
            let onEdge = (fix.onRoadShare ?? 0) >= 0.5 && fix.matchedEdge != nil
            #expect(fix.captured == (onEdge && (fix.crossTrackSemiAxisM ?? .infinity) < 25 && fix.inside95 == false), "t \(fix.t)")
        }
        #expect(m.unmappedCaptured == m.fixes.filter { $0.captured == true }.count)
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
