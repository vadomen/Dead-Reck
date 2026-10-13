import Foundation
import Testing

@testable import DriveLoggerCore

/// N3.2 test 3 (docs/N3_PLAN.md): a road missing from the pack next to a
/// mapped parallel road. The plan's model captures the cloud onto the
/// mapped road (docs/N3_ROAD_OFFROAD.md), so the capture checks run inside
/// `withKnownIssue`: the suite stays green, and turns red the day the
/// capture stops — then drop the wrapper.
@Suite("Navigation roads: missing road (N3.2 test 3)")
struct NavigationRoadOffRoadTests {
    typealias S = SyntheticDrive

    // MARK: 3. A road missing from OSM next to a mapped parallel road

    /// Pass: at every check after 15 s, the estimate is not captured
    /// (< 25 m across) or the truth is inside its 95 % ellipse — both
    /// hypotheses alive is fine (decided for N3.2a).
    @Test("3. Driving 1 km on an unmapped road 40 m from a mapped parallel one: no capture, or the truth inside the 95 % ellipse")
    func missingRoadNoCapture() throws {
        // The car drives north along x = 0 (not in the pack); the mapped
        // road is x = 40. Heading known from clean fixes before t = 10 s,
        // then dead reckoning on the roads only.
        let net = try NavigationRoadTests.network([NavigationRoadTests.street(1, from: (40, -3000), to: (40, 3000))])
        let v = 12.0
        let drive = NavigationRoadTests.northDrive(seconds: 95, speed: v)
        let clean = S.cleanFix()
        let inputs = NavigationRoadTests.shifted(drive, by: (0, -500), fix: { t, s, r in t < 10 ? clean(t, s, &r) : nil },
                                                 gyroNoise: 0.001)
        for seed: UInt64 in 1...3 {
            let r = NavigationRoadTests.run(inputs, config: NavigationRoadTests.config(particles: 1000, seed: seed),
                                            roads: net, every: 5)
            // Outside the known issue: the road update must run here.
            #expect(r.engine.counters.roadUpdates > 50)
            withKnownIssue("captured onto the mapped road (docs/N3_ROAD_OFFROAD.md)") {
                for e in r.estimates where e.t.seconds > 15 {
                    let truth = drive.truth(at: e.t.seconds)
                    let p = S.plane.enu(latitude: e.latitude, longitude: e.longitude)
                    let dE = truth.east - p.east, dN = (truth.north - 500) - p.north
                    #expect(abs(dE) < 25 || e.ellipse.contains(dEast: dE, dNorth: dN),
                            "seed \(seed) t \(e.t.seconds): captured \(dE) m across, truth outside \(e.ellipse)")
                }
            }
        }
    }
}
