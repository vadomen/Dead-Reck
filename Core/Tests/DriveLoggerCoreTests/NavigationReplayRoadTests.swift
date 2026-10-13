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
}
