import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.2 test 14 (docs/N3_PLAN.md, "N3.2" and "Performance"): the cost of
/// the road update on a synthetic 100 m street grid over 10 km² with 2000
/// particles. Synthetic only, near (0, 0).
///
/// - Release (`swift test -c release --filter NavigationRoadPerfTests`):
///   the Mac proxies, a step that carries a road update ≤ 0.5 ms mean and
///   ≤ 1.5 ms max, timed per `ingest` call; plus the candidate count.
/// - Debug: `roadCandidateTests` per particle and road update ≤ 64 only, on
///   a shorter drive; no timing is asserted (a debug build is not the
///   product, and its timings say nothing about it).
@Suite("Navigation road performance (N3.2 test 14)")
struct NavigationRoadPerfTests {
    typealias S = SyntheticDrive
    typealias R = NavigationRoadTests
    typealias N = RoadFixture.Node

    #if DEBUG
    static let isRelease = false
    #else
    static let isRelease = true
    #endif

    /// 32 × 32 blocks of 100 m (3.2 km square, 10.24 km²) centred on the
    /// origin. Every street is one way with a node at each crossing, shared
    /// with the crossing street, so segments are 100 m and the graph has
    /// real junctions, as an OSM street grid has.
    static func gridLines(blocks: Int = 32, spacing: Double = 100) -> [String] {
        let half = Double(blocks) * spacing / 2
        func node(_ i: Int, _ j: Int) -> N {
            N(id: Int64(100_000 + i * 1000 + j), east: -half + Double(i) * spacing, north: -half + Double(j) * spacing)
        }
        var lines: [String] = []
        for k in 0...blocks {
            lines.append(RoadFixture.way(Int64(1 + k), ["highway": "residential"], (0...blocks).map { node(k, $0) }))
            lines.append(RoadFixture.way(Int64(1001 + k), ["highway": "residential"], (0...blocks).map { node($0, k) }))
        }
        return lines
    }

    /// A drive on the grid from the crossing at (0, 0), heading north at
    /// 12 m/s, round the 1 km square [0, 1000]² on its streets: right turns
    /// of 3 s (radius r = v · 3 s / (π/2) ≈ 22.9 m), the straights cut by r
    /// at each corner so every leg runs on a street. Clean fixes for the
    /// first 20 s only, so the cloud spreads after that as it does in a
    /// masked replay.
    static func inputs(seconds: Double) -> [NavigationInput] {
        let v = 12.0, turnS = 3.0
        let r = v * turnS / (Double.pi / 2)
        var segments: [S.Segment] = []
        var left = seconds
        var first = true
        while left > 0 {
            let s = min((first ? 1000 - r : 1000 - 2 * r) / v, left)
            first = false
            segments.append(.straight(seconds: s, speed: v))
            left -= s
            guard left > 0 else { break }
            let turn = min(turnS, left)
            segments.append(.turn(degrees: 90 * turn / turnS, seconds: turn, speed: v))
            left -= turn
        }
        let drive = S(initialHeadingDeg: 0, initialSpeed: v, segments)
        let clean = S.cleanFix()
        return R.shifted(drive, by: (0, 0), fix: { t, state, rng in t <= 20 ? clean(t, state, &rng) : nil })
    }

    @Test("14. Road update on a 100 m grid over 10 km², 2000 particles: candidates ≤ 64 per particle; release: road-update step ≤ 0.5 ms mean, ≤ 1.5 ms max")
    func roadUpdateCost() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build(Self.gridLines())])
        let inputs = Self.inputs(seconds: Self.isRelease ? 600 : 40)
        var engine = NavigationEngine(config: R.config(particles: 2000), roads: net)
        let clock = ContinuousClock()
        var roadSteps: [Double] = []  // ms, the ingest calls that carried a full road update
        for input in inputs {
            let before = engine.counters.roadUpdates
            let started = clock.now
            engine.ingest(input)
            let elapsed = clock.now - started
            if engine.counters.roadUpdates > before {
                let c = elapsed.components
                roadSteps.append(Double(c.seconds) * 1000 + Double(c.attoseconds) * 1e-15)
            }
        }
        let c = engine.counters
        try #require(c.roadUpdates > 0)
        let perParticle = Double(c.roadCandidateTests) / Double(c.roadUpdates) / 2000
        #expect(roadSteps.count == c.roadUpdates)
        #expect(c.roadUpdates >= (Self.isRelease ? 500 : 15), "\(c.roadUpdates) road updates")
        #expect(perParticle <= 64, "candidate tests per particle and road update \(perParticle)")
        let mean = roadSteps.reduce(0, +) / Double(roadSteps.count)
        let max = roadSteps.max() ?? 0
        print(String(format: "test 14 (%@): %d road updates (no road %d), candidate tests %.1f per particle, road-update step mean %.3f ms, max %.3f ms",
                     Self.isRelease ? "release" : "debug", c.roadUpdates, c.roadUpdatesNoRoad, perParticle, mean, max))
        if Self.isRelease {
            #expect(mean <= 0.5, "road-update step mean \(mean) ms")
            #expect(max <= 1.5, "road-update step max \(max) ms")
        }
    }
}
