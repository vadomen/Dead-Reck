import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// Prompt 51 item C, performance: matching a 50 km route on a synthetic
/// 10 km × 10 km street grid (250 m blocks, a node at every crossing).
/// Synthetic only, near (0, 0).
///
/// - Release (`swift test -c release --filter RouteEdgeMatcherPerfTests`):
///   the whole 51 km serpentine (5104 samples), timed; bound 5 s
///   (generous: measured 0.010 s on the development Mac; the R1 spike's
///   real routes on all 28 national and regional packs took 10–170 ms each,
///   140 km in 160 ms).
/// - Debug: a 5 km route, coverage only; no timing (a debug build says
///   nothing about the product).
@Suite("Route edge matcher performance (prompt 51 C)")
struct RouteEdgeMatcherPerfTests {
    typealias N = RoadFixture.Node

    #if DEBUG
    static let isRelease = false
    #else
    static let isRelease = true
    #endif

    static let blocks = 40
    static let spacing = 250.0
    static var half: Double { Double(blocks) * spacing / 2 }

    static func gridLines() -> [String] {
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

    /// A serpentine along the grid's streets: `rows` rows of 10 km joined by
    /// 250 m legs, vertices every 50 m with a deterministic ±2 m wobble.
    static func serpentine(rows: Int, rowLength: Double = 10_000) -> RoutePolyline {
        var offsets: [(Double, Double)] = []
        var k = 0
        func add(_ east: Double, _ north: Double) {
            let wobble = 2 * sin(Double(k) * 1.3)
            k += 1
            offsets.append((east, north + wobble))
        }
        for row in 0..<rows {
            let y = -half + Double(row) * spacing
            let eastward = row % 2 == 0
            let steps = Int(rowLength / 50)
            for s in 0...steps {
                let x = -half + (eastward ? Double(s) : Double(steps - s)) * 50
                add(x, y)
            }
            if row + 1 < rows {
                let x = eastward ? -half + rowLength : -half
                for s in 1..<5 { offsets.append((x + 2 * sin(Double(s)), y + Double(s) * 50)) }
            }
        }
        let points = offsets.map { o -> RoutePoint in
            let p = RoadFixture.point(o.0, o.1)
            return RoutePoint(latE7: p.latE7, lonE7: p.lonE7)
        }
        return try! RoutePolyline(points)
    }

    @Test("A 50 km route on a 10 km street grid: coverage ≥ 0.99; release: matched in ≤ 5 s")
    func fiftyKilometres() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build(Self.gridLines())])
        let rows = Self.isRelease ? 5 : 1
        let polyline = Self.serpentine(rows: rows, rowLength: Self.isRelease ? 10_000 : 5_000)
        let matcher = RouteEdgeMatcher(network: net)
        let clock = ContinuousClock()
        var match: RouteEdgeMatch?
        let elapsed = clock.measure { match = matcher.match(polyline) }
        let m = try #require(match)
        #expect(m.coverage >= 0.99 && !m.isWeak, "coverage \(m.coverage), gaps \(m.gaps.count)")
        if Self.isRelease {
            #expect(polyline.lengthM > 50_000)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("RouteEdgeMatcherPerfTests: \(Int(polyline.lengthM)) m, \(m.sampleCount) samples, \(m.edges.count) edges, \(String(format: "%.3f", seconds)) s")
            #expect(seconds <= 5, "matched in \(seconds) s")
        }
    }
}
