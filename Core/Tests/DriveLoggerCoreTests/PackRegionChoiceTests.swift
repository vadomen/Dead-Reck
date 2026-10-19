import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-8 first launch (prompt 26): fix usability, bbox containment, the
/// nearest-centre tie-break, neighbours, list order. Synthetic names and
/// boxes near (0, 0) only: 0.1° ≈ 11.1 km there.
@Suite("Pack region choice (UX-8 first launch)")
struct PackRegionChoiceTests {
    typealias C = PackRegionChoice

    static func pack(_ name: String, _ kind: PackManifest.Pack.Kind = .region,
                     west: Double, south: Double, east: Double, north: Double) -> PackManifest.Pack {
        PackManifest.Pack(name: name, kind: kind, titleUK: "", titleEN: name.uppercased(),
                          bbox: .init(west: west, south: south, east: east, north: north),
                          url: URL(string: "https://packs.example.test/packs/v1/\(name).roadpack")!,
                          size: 1_000, sha256: String(repeating: "0", count: 64), contentHash: "0123456789abcdef",
                          formatVersion: 1, osmDate: nil, osmTimestamp: 0)
    }

    /// zz-01 and zz-02 share the edge lon 1; zz-03 overlaps both; zz-05 lies
    /// just south of zz-01's south-east; zz-04 is far away.
    static let packs: [PackManifest.Pack] = [
        pack("zz-national", .national, west: 0, south: -1, east: 4, north: 3),
        pack("zz-04", west: 3, south: 2, east: 4, north: 3),
        pack("zz-03", west: 0.5, south: 0.5, east: 1.5, north: 1.5),
        pack("zz-02", west: 1, south: 0, east: 2, north: 1),
        pack("zz-01", west: 0, south: 0, east: 1, north: 1),
        pack("zz-05", west: 0, south: -1, east: 1, north: 0.05),
    ]

    static let request = Date(timeIntervalSinceReferenceDate: 1_000_000)

    static func fix(lat: Double = 0.2, lon: Double = 0.9, accuracy: Double = 1_414,
                    takenAfter: Double = 1, arrivedAfter: Double = 2) -> C.Fix {
        C.Fix(latitude: lat, longitude: lon, horizontalAccuracyM: accuracy,
              timestamp: request.addingTimeInterval(takenAfter), arrivedAt: request.addingTimeInterval(arrivedAfter))
    }

    // MARK: Fix usability

    @Test("Accuracy: finite, >= 0 and <= 5 km is usable; above 5 km, negative or non-finite is not")
    func accuracy() {
        for a in [0.0, 15, 1_414, 4_999.9, 5_000] {
            #expect(C.fixVerdict(Self.fix(accuracy: a), requestedAt: Self.request) == .usable, "\(a)")
        }
        for a in [5_000.1, 6_000, -1, .nan, .infinity] {
            #expect(C.fixVerdict(Self.fix(accuracy: a), requestedAt: Self.request) == .inaccurate, "\(a)")
        }
        let s = C.suggest(packs: Self.packs, fix: Self.fix(accuracy: 5_001), requestedAt: Self.request)
        #expect(s.preselected == ["zz-national"] && s.region == nil && s.neighbours.isEmpty)
    }

    @Test("A fix arriving more than 10 s after the request (or before it) is ignored")
    func lateFix() {
        #expect(C.fixVerdict(Self.fix(takenAfter: 9, arrivedAfter: 10), requestedAt: Self.request) == .usable)
        #expect(C.fixVerdict(Self.fix(takenAfter: 9, arrivedAfter: 10.01), requestedAt: Self.request) == .late)
        #expect(C.fixVerdict(Self.fix(takenAfter: 9, arrivedAfter: 30), requestedAt: Self.request) == .late)
        #expect(C.fixVerdict(Self.fix(takenAfter: -2, arrivedAfter: -1), requestedAt: Self.request) == .late)
        let s = C.suggest(packs: Self.packs, fix: Self.fix(takenAfter: 11, arrivedAfter: 12), requestedAt: Self.request)
        #expect(s.preselected == ["zz-national"] && s.region == nil && s.fixVerdict == .late)
    }

    @Test("A stale fix is ignored: taken before the request, or more than 60 s old on arrival")
    func staleFix() {
        #expect(C.fixVerdict(Self.fix(takenAfter: 0, arrivedAfter: 1), requestedAt: Self.request) == .usable)
        #expect(C.fixVerdict(Self.fix(takenAfter: -0.5, arrivedAfter: 1), requestedAt: Self.request) == .stale)
        // The debrief case: iOS hands over a cached fix ~24 min old first.
        #expect(C.fixVerdict(Self.fix(takenAfter: -24 * 60, arrivedAfter: 0.3), requestedAt: Self.request) == .stale)
        // Age alone (reachable only with a longer wait allowed).
        let patient = C.Config(maxWaitS: 120)
        #expect(C.fixVerdict(Self.fix(takenAfter: 1, arrivedAfter: 61), requestedAt: Self.request, config: patient) == .usable)
        #expect(C.fixVerdict(Self.fix(takenAfter: 1, arrivedAfter: 61.1), requestedAt: Self.request, config: patient) == .stale)
        let s = C.suggest(packs: Self.packs, fix: Self.fix(takenAfter: -120, arrivedAfter: 1), requestedAt: Self.request)
        #expect(s.preselected == ["zz-national"] && s.region == nil && s.neighbours.isEmpty && s.fixVerdict == .stale)
    }

    @Test("No fix, or an invalid position: national only, no region, no neighbours")
    func noFix() {
        let s = C.suggest(packs: Self.packs, fix: nil, requestedAt: Self.request)
        #expect(s == C.Suggestion(preselected: ["zz-national"], region: nil, neighbours: [], fixVerdict: .noFix))
        for (lat, lon) in [(Double.nan, 0.5), (0.5, .infinity), (91, 0.5), (0.5, 181)] {
            #expect(C.fixVerdict(Self.fix(lat: lat, lon: lon), requestedAt: Self.request) == .invalidPosition)
        }
        // Every national pack is preselected, in manifest order.
        let two = Self.packs + [Self.pack("zz-national-b", .national, west: 0, south: 0, east: 1, north: 1)]
        #expect(C.suggest(packs: two, fix: nil, requestedAt: Self.request).preselected == ["zz-national", "zz-national-b"])
    }

    // MARK: Region and neighbours

    @Test("The region is the region-kind pack whose bbox contains the fix (edges included)")
    func containment() {
        let s = C.suggest(packs: Self.packs, fix: Self.fix(lat: 0.4, lon: 0.1), requestedAt: Self.request)
        #expect(s.region == "zz-01" && s.preselected == ["zz-national", "zz-01"] && s.fixVerdict == .usable)
        #expect(C.containingRegion(latitude: 0.3, longitude: 1.7, in: Self.packs)?.name == "zz-02")
        #expect(C.containingRegion(latitude: 0.3, longitude: 2.0, in: Self.packs)?.name == "zz-02")  // east edge
        #expect(C.containingRegion(latitude: 0.3, longitude: 2.01, in: Self.packs) == nil)
        #expect(C.containingRegion(latitude: 2.5, longitude: 3.5, in: Self.packs)?.name == "zz-04")
        // Inside only the national bbox: no region; national is never "the region".
        #expect(C.containingRegion(latitude: 2.5, longitude: 2.5, in: Self.packs) == nil)
        let s2 = C.suggest(packs: Self.packs, fix: Self.fix(lat: 2.5, lon: 2.5), requestedAt: Self.request)
        #expect(s2.preselected == ["zz-national"] && s2.region == nil)
        // An excluded name is skipped.
        #expect(C.containingRegion(latitude: 0.3, longitude: 1.7, in: Self.packs, excluding: ["zz-02"]) == nil)
    }

    @Test("Several bboxes contain the fix: the nearest centre wins; equal centres go to the smaller name")
    func nearestCentre() {
        // In zz-01 (centre 0.5, 0.5: 0.5° away) and zz-03 (centre 1, 1: ~0.22° away).
        #expect(C.containingRegion(latitude: 0.8, longitude: 0.9, in: Self.packs)?.name == "zz-03")
        // In zz-01 and zz-03, nearer zz-01's centre.
        #expect(C.containingRegion(latitude: 0.55, longitude: 0.55, in: Self.packs)?.name == "zz-01")
        // On the shared edge of zz-01 and zz-02, equidistant from both centres, below zz-03.
        #expect(C.containingRegion(latitude: 0.3, longitude: 1.0, in: Self.packs)?.name == "zz-01")
        let twins = [Self.pack("zz-07", west: 0, south: 0, east: 1, north: 1),
                     Self.pack("zz-06", west: 0, south: 0, east: 1, north: 1)]
        #expect(C.containingRegion(latitude: 0.2, longitude: 0.2, in: twins)?.name == "zz-06")
        #expect(C.containingRegion(latitude: 0.2, longitude: 0.2, in: Array(twins.reversed()))?.name == "zz-06")
        // The chosen one is preselected; the other container is a neighbour at 0 m, not preselected.
        let s = C.suggest(packs: Self.packs, fix: Self.fix(lat: 0.8, lon: 0.9), requestedAt: Self.request)
        #expect(s.preselected == ["zz-national", "zz-03"])
        #expect(s.neighbours.first == C.Neighbour(name: "zz-01", distanceM: 0))
    }

    @Test("Regions within 20 km of the fix are listed by distance, never preselected; farther ones are not")
    func neighbours() {
        // In zz-01 at (0.2, 0.9): zz-02 ~11.1 km east, zz-05 ~16.6 km south, zz-03 ~33 km north.
        let s = C.suggest(packs: Self.packs, fix: Self.fix(lat: 0.2, lon: 0.9), requestedAt: Self.request)
        #expect(s.region == "zz-01")
        #expect(s.preselected == ["zz-national", "zz-01"])
        #expect(s.neighbours.map(\.name) == ["zz-02", "zz-05"])
        #expect(abs(s.neighbours[0].distanceM - 11_132) < 30, "\(s.neighbours[0].distanceM)")
        #expect(abs(s.neighbours[1].distanceM - 16_586) < 30, "\(s.neighbours[1].distanceM)")
        // A wider radius brings zz-03 in; the national pack is never a neighbour.
        let wide = C.suggest(packs: Self.packs, fix: Self.fix(lat: 0.2, lon: 0.9), requestedAt: Self.request,
                             config: C.Config(neighbourDistanceM: 40_000))
        #expect(wide.neighbours.map(\.name) == ["zz-02", "zz-05", "zz-03"])
        // A fix in no region bbox still lists the regions near it, none preselected.
        let outside = C.suggest(packs: Self.packs, fix: Self.fix(lat: 0.5, lon: 2.1), requestedAt: Self.request)
        #expect(outside.region == nil && outside.preselected == ["zz-national"])
        #expect(outside.neighbours.map(\.name) == ["zz-02"])
    }

    @Test("List order: national, the region, neighbours by distance, then the rest by the caller's order")
    func listOrder() {
        let s = C.suggest(packs: Self.packs, fix: Self.fix(lat: 0.2, lon: 0.9), requestedAt: Self.request)
        let order = C.listOrder(Self.packs, suggestion: s) { $0.titleEN < $1.titleEN }
        #expect(order.map(\.name) == ["zz-national", "zz-01", "zz-02", "zz-05", "zz-03", "zz-04"])
        let none = C.suggest(packs: Self.packs, fix: nil, requestedAt: Self.request)
        let descending = C.listOrder(Self.packs, suggestion: none) { $0.titleEN > $1.titleEN }
        #expect(descending.map(\.name) == ["zz-national", "zz-05", "zz-04", "zz-03", "zz-02", "zz-01"])
    }
}
