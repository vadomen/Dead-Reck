import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// `build_roads` argument checks (`BuildRoadsArguments`): bad numeric input
/// is a usage error (exit 2), never a trap (exit 133). Synthetic packs only.
@Suite struct BuildRoadsArgumentsTests {
    func refused<T>(_ result: Result<T, BuildRoadsArguments.Refusal>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    /// R16.1-2: these converted unchecked into `Int32(...)` and trapped.
    @Test func gridBoxRefusesNonFiniteAndOutOfRangeValues() {
        for text in ["nan,0,1,1", "0,inf,1,1", "0,0,1000,1", "0,0,1,91", "-180.5,0,1,1", "0,-90.01,1,1",
                     "1e300,0,1,1", "0,0,1", "0,0,1,1,1", "0,0,x,1", "0,,1,1", ""] {
            #expect(refused(BuildRoadsArguments.gridBox(text)), "\(text) accepted")
        }
    }

    /// The accepted box is the old conversion: corners in either order,
    /// south-west rounded down and north-east up, in E7; the extremes fit.
    @Test func gridBoxAcceptsTheWholeGlobeAndOrdersCorners() throws {
        let box = try BuildRoadsArguments.gridBox(" 0.00000015, 0.5 ,-0.25,-0.00000005").get()
        #expect(box.southWest == RoadPoint(latE7: -1, lonE7: -2_500_000))
        #expect(box.northEast == RoadPoint(latE7: 5_000_000, lonE7: 2))
        let world = try BuildRoadsArguments.gridBox("-180,-90,180,90").get()
        #expect(world.southWest == RoadPoint(latE7: -900_000_000, lonE7: -1_800_000_000))
        #expect(world.northEast == RoadPoint(latE7: 900_000_000, lonE7: 1_800_000_000))
    }

    /// R16.1-2: a negative count trapped in `RoadPackBench`; 0 (nothing
    /// to measure) is refused as well.
    @Test func benchNeedsAPositiveCount() throws {
        for text in ["-5", "0", "1.5", "x", ""] {
            #expect(refused(BuildRoadsArguments.benchQueries(text)), "\(text) accepted")
        }
        #expect(try BuildRoadsArguments.benchQueries("10").get() == 10)
    }

    /// R16.2-1: `--info --bench` on a pack that fails `verify()` (an edge
    /// of `pointCount` 0) skips the bench, so `build_roads` exits 4; the
    /// bench would trap on that edge. A pack that verifies gets its bench.
    @Test func inspectSkipsTheBenchWhenVerifyFails() throws {
        var bytes = try RoadPackRejectionTests.fixture()
        let good = try RoadPack(data: Data(bytes), verify: false)
        let ok = BuildRoadsArguments.inspect(good, benchQueries: 10)
        #expect(ok.verifyError == nil)
        #expect(ok.bench?.queries == 10)
        #expect(BuildRoadsArguments.inspect(good, benchQueries: nil).bench == nil)

        let edge = Int(RoadPackRejectionTests.get64(bytes, try RoadPackRejectionTests.entry(bytes, "EDGE") + 8))
        for i in 0..<4 { bytes[edge + 12 + i] = 0 }
        RoadPackRejectionTests.rehash(&bytes)
        let corrupt = try RoadPack(data: Data(bytes), verify: false)
        #expect(corrupt.edge(0).pointCount == 0)
        let failed = BuildRoadsArguments.inspect(corrupt, benchQueries: 10)
        #expect(failed.verifyError != nil)
        #expect(failed.bench == nil)
    }
}
