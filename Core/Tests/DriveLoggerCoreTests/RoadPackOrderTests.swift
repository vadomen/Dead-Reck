import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.2c item 7: a replay's results depend on the SET of road packs, never on
/// the order they were passed in. Synthetic packs near (0, 0) only.
///
/// Three overlapping packs on one grid, shaped like a national pack and two
/// regional ones:
/// - "full": a level-0 street (way 10) ending at node A = (0, 0), a level-1
///   bridge (way 12, primary) continuing it east from A, a side street
///   (way 13) north from A;
/// - "national": the bridge only (national classes);
/// - "local": the street only, plus an unrelated street far north (way 15).
///
/// The street and the bridge are each in two packs. Which copy a network
/// keeps decides the edge a particle sits on, and the level rule admits the
/// bridge from the street only when both copies come from the same pack
/// (adjacency exists within a pack only). So before item 7 the order of the
/// packs changed the particles, not only the labels.
@Suite("Road pack order (N3.2c item 7)")
struct RoadPackOrderTests {
    typealias S = SyntheticDrive
    typealias R = NavigationRoadTests
    typealias N = RoadFixture.Node

    static let street = RoadFixture.way(10, ["highway": "residential"], [
        N(id: 100, east: -1500, north: 0), N(id: 101, east: -700, north: 0), N(id: 1, east: 0, north: 0),
    ])
    static let bridge = RoadFixture.way(12, ["highway": "primary", "bridge": "yes", "layer": "1"], [
        N(id: 1, east: 0, north: 0), N(id: 120, east: 700, north: 0), N(id: 121, east: 1500, north: 0),
    ])
    static let side = RoadFixture.way(13, ["highway": "residential"], [
        N(id: 1, east: 0, north: 0), N(id: 130, east: 0, north: 400),
    ])
    static let farStreet = RoadFixture.way(15, ["highway": "residential"], [
        N(id: 150, east: -1500, north: 1200), N(id: 151, east: 1500, north: 1200),
    ])

    static func packs() throws -> (full: RoadPack, national: RoadPack, local: RoadPack) {
        let full = try RoadFixture.build([street, bridge, side])
        let national = try RoadFixture.build([bridge], classes: RoadGraphBuilder.nationalClasses)
        let local = try RoadFixture.build([street, farStreet])
        return (full, national, local)
    }

    static func permutations<T>(_ a: [T]) -> [[T]] {
        guard a.count > 1 else { return [a] }
        return a.indices.flatMap { i -> [[T]] in
            var rest = a
            let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }

    /// East along y = 0 at 12 m/s from x = −1200: 100 s on the street, then
    /// 80 s on the bridge. Clean fixes, withheld after 10 s.
    static func inputs() -> [NavigationInput] {
        let v = 12.0
        let drive = S(initialHeadingDeg: 90, initialSpeed: v, [.straight(seconds: 180, speed: v)])
        return R.shifted(drive, by: (-1200, 0), fix: S.cleanFix())
    }

    static func bits(_ e: NavigationEngine) -> [[UInt64]] {
        R.state(e).map { $0.map(\.bitPattern) }
    }

    @Test("Every order of three overlapping packs gives one network: packs in ascending content hash, one roadSetHash, one segment set")
    func networkIsCanonical() throws {
        let (full, national, local) = try Self.packs()
        let orders = Self.permutations([full, national, local])
        #expect(orders.count == 6)
        let networks = try orders.map { try RoadNetwork(packs: $0) }
        let sorted = [full, national, local].map(\.contentHash).sorted()
        for net in networks {
            #expect(net.packs.map(\.contentHash) == sorted)
            #expect(net.roadSetHash == networks[0].roadSetHash)
            #expect(net.roadSetHash == RoadPackFormat.roadSetHash(sorted))
            #expect(net.infos == networks[0].infos)
            #expect(ReplayRoadSet(net) == ReplayRoadSet(networks[0]))
            #expect(ReplayRoadSet(net).labelSuffix == ReplayRoadSet(networks[0]).labelSuffix)
            #expect(ReplayRoadSet(net).packs == ReplayRoadSet(networks[0]).packs)
        }
        // The same segments (pack, start point, key) in every cell the drive crosses.
        for x in stride(from: -1500.0, through: 1500, by: 25) {
            let p = RoadFixture.point(x, 3)
            let reference = networks[0].segments(nearLatitude: p.latitude, longitude: p.longitude)
            for net in networks.dropFirst() {
                #expect(net.segments(nearLatitude: p.latitude, longitude: p.longitude) == reference, "x \(x)")
            }
        }
    }

    @Test("The engine with the packs in every order: bit-identical particles and estimates (the level rule sees one bridge copy)")
    func engineIndependentOfOrder() throws {
        let (full, national, local) = try Self.packs()
        let inputs = Self.inputs()
        let config = R.config(particles: 200)
        let runs = try Self.permutations([full, national, local]).map { order in
            R.run(inputs, config: config, roads: try RoadNetwork(packs: order), every: 1)
        }
        let reference = runs[0]
        #expect(reference.engine.counters.roadUpdates > 10)
        #expect(reference.estimates.count > 170)
        for (k, run) in runs.enumerated().dropFirst() {
            #expect(run.estimates == reference.estimates, "order \(k)")
            #expect(Self.bits(run.engine) == Self.bits(reference.engine), "order \(k)")
            #expect(run.engine.roadEdge == reference.engine.roadEdge, "order \(k)")
            #expect(run.engine.roadLevel == reference.engine.roadLevel, "order \(k)")
            #expect(run.engine.counters == reference.engine.counters, "order \(k)")
        }
    }

    @Test("Two packs A, B and B, A through the replay: identical label, roads, roadSetHash, metrics.json, metrics.md and GeoJSON bytes")
    func replayIndependentOfOrder() throws {
        let (full, national, _) = try Self.packs()
        let inputs = Self.inputs()
        func replay(_ packs: [RoadPack]) throws -> ReplayResult {
            var options = ReplayOptions(gps: .maskAfter(seconds: 10), config: S.config(particles: 200, seed: 1))
            options.roads = ReplayRoadSet(try RoadNetwork(packs: packs))
            return NavigationReplay.run(logName: "synthetic", inputs: inputs, options: options)
        }
        var ab = try replay([full, national])
        var ba = try replay([national, full])
        #expect(ab.counters.roadUpdates > 10)
        #expect(ab.counters == ba.counters)
        #expect(ab.maxErrorM == ba.maxErrorM && ab.endErrorM == ba.endErrorM)
        #expect(ab.matchedEdges.map(\.edge) == ba.matchedEdges.map(\.edge))
        // Wall-clock timing is the one field that differs from run to run.
        ab.msPerStep = 0; ab.maxIngestMs = 0
        ba.msPerStep = 0; ba.maxIngestMs = 0
        #expect(ab.mode == ba.mode)
        #expect(ab.roadSetHash == ba.roadSetHash)
        #expect(ab.roads == ba.roads)
        #expect(ab.roads?.map(\.contentHash) == [full, national].map(\.contentHash).sorted().map(NavigationSeed.hex))
        #expect(try ReplayReport.metricsJSON([ReplayMetrics(ab)]) == ReplayReport.metricsJSON([ReplayMetrics(ba)]))
        #expect(ReplayReport.markdown([ReplayMetrics(ab)]) == ReplayReport.markdown([ReplayMetrics(ba)]))
        #expect(try ReplayReport.geoJSON(ab) == ReplayReport.geoJSON(ba))
        #expect(ReplayReport.summary(ab) == ReplayReport.summary(ba))
    }

    @Test("The same pack twice is refused (adjacent or not, same bytes loaded twice), naming its content hash")
    func duplicatesRefused() throws {
        let (full, national, local) = try Self.packs()
        let again = try RoadPack(data: RoadFixture.buildData([Self.street, Self.bridge, Self.side]))
        #expect(again.contentHash == full.contentHash)
        for packs in [[full, full], [full, again], [full, national, full], [national, full, local, again], [local, full, national, local]] {
            let duplicate = try #require(packs.first { p in packs.filter { $0.contentHash == p.contentHash }.count > 1 })
            #expect(throws: RoadPackError.duplicatePack(duplicate.contentHash)) { try RoadNetwork(packs: packs) }
        }
    }

    @Test("roadSetHash is a function of the set: any order of the content hashes gives one value, the ascending one")
    func roadSetHashOfSet() {
        let hashes: [UInt64] = [0xFFFF_0000_0000_0001, 3, 0x8000_0000_0000_0000]
        let values = Set(Self.permutations(hashes).map(RoadPackFormat.roadSetHash))
        #expect(values.count == 1)
        var bytes: [UInt8] = []
        for h in hashes.sorted() { for s in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: h >> UInt64(s))) } }
        #expect(values.first == NavigationSeed.fnv1a64(bytes))
    }
}
