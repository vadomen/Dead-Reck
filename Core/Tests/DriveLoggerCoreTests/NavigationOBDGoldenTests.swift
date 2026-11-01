import Foundation
import Testing

@testable import DriveLoggerCore

/// Prompt 47 (UX-7) hard constraint: an OBD run is unchanged. Deterministic
/// simulated OBD runs through `LiveNavigationRun` as the app builds them,
/// compared with golden values **captured on nav-noobd 5468cd9, before
/// prompt 47's edits** (FNV-1a 64 hashes over every estimate's bit patterns
/// and every sidecar line's bytes with the timing fields removed, plus a few
/// readable values in metres from the drive's local plane). A difference
/// here means the OBD run's estimates, config or sidecar changed.
///
/// Sources: the demo drive's sensor model (`DemoSensorModel`, the app's
/// simulated sources) with the bundled demo pack as the only road
/// candidate, and a synthetic drive from (0, 0) (`SyntheticDrive`, OBD +
/// clean then network fixes, through the header-based init the app uses).
/// No real place, date or recording.
@Suite("Navigation prompt 47: OBD run golden (5468cd9)")
struct NavigationOBDGoldenTests {
    typealias S = SyntheticDrive

    /// FNV-1a 64.
    struct Hash {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        mutating func add(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                value ^= UInt64(b)
                value = value &* 0x0000_0100_0000_01b3
            }
        }
        mutating func add(_ x: UInt64) { withUnsafeBytes(of: x.littleEndian) { add($0) } }
        mutating func add(_ x: Double) { add(x.bitPattern) }
        mutating func add(_ x: Double?) { if let x { add(1 as UInt64); add(x) } else { add(0 as UInt64) } }
        mutating func add(_ x: Bool) { add(x ? 1 as UInt64 : 0) }
        mutating func add(_ e: NavigationEstimate?) {
            guard let e else { add(0 as UInt64); return }
            add(UInt64(bitPattern: e.t.nanoseconds))
            for x in [e.east, e.north, e.latitude, e.longitude, e.headingDeg, e.headingStdDeg,
                      e.ellipse.semiMajorM, e.ellipse.semiMinorM, e.ellipse.orientationDeg, e.speedMps,
                      e.speedScaleMean, e.speedScaleStd, e.effectiveSampleSize] { add(x) }
            add(e.converged)
            add(e.stationary)
            add(e.onRoadShare)
            add(UInt64(bitPattern: Int64(e.matchedEdge?.edge ?? -1)))
            add(UInt64(bitPattern: e.matchedEdge?.osmWayID ?? -1))
        }
    }

    struct Result {
        var estimates: UInt64
        var lines: UInt64
        var header: UInt64
        var counters: UInt64
        var lineCount: Int
        /// Readable: the estimate at the last checked second, metres in `plane`.
        var east: Double
        var north: Double
        var semiMajorM: Double
        var headingDeg: Double
    }

    /// Every sidecar line, encoded, with the estimate's timing diagnostics
    /// (`msPerStep`, `maxStepMs`) removed (they are wall time).
    static func hashLines(_ lines: [NavSidecar.Line]) throws -> UInt64 {
        let encoder = NavSidecar.makeEncoder()
        var h = Hash()
        for var line in lines {
            switch line {
            case .estimate(var e):
                e.msPerStep = nil
                e.maxStepMs = nil
                line = .estimate(e)
            case .pin(var p):
                p.prior?.msPerStep = nil
                p.prior?.maxStepMs = nil
                line = .pin(p)
            default: break
            }
            h.add(try NavSidecar.encode(line, with: encoder))
        }
        return h.value
    }

    static func result(_ run: LiveNavigationRun, lines: [NavSidecar.Line], seconds: ClosedRange<Int>,
                       plane: LocalTangentPlane) throws -> Result {
        var h = Hash()
        for s in seconds { h.add(run.engine.estimate(at: MonotonicTimestamp(seconds: Double(s)))) }
        let last = try #require(run.engine.estimate(at: MonotonicTimestamp(seconds: Double(seconds.upperBound))))
        let p = plane.enu(latitude: last.latitude, longitude: last.longitude)
        var header = Hash()
        header.add(try NavSidecar.encode(.header(run.header), with: NavSidecar.makeEncoder()))
        let countersEncoder = JSONEncoder()
        countersEncoder.outputFormatting = [.sortedKeys]
        var counters = Hash()
        counters.add(try countersEncoder.encode(run.engine.counters))
        return Result(estimates: h.value, lines: try hashLines(lines), header: header.value, counters: counters.value,
                      lineCount: lines.count, east: p.east, north: p.north, semiMajorM: last.ellipse.semiMajorM,
                      headingDeg: last.headingDeg)
    }

    static func describe(_ r: Result) -> String {
        "estimates 0x\(String(r.estimates, radix: 16)) lines 0x\(String(r.lines, radix: 16)) header 0x\(String(r.header, radix: 16)) counters 0x\(String(r.counters, radix: 16)) lineCount \(r.lineCount) east \(r.east) north \(r.north) semiMajor \(r.semiMajorM) heading \(r.headingDeg)"
    }

    /// The demo drive: 150 s of the canonical demo inputs (OBD, 100 Hz motion,
    /// GNSS then network fixes), the app's demo run (its session ID and seed,
    /// the default config), the demo pack selected and attached live.
    static func demoRun() throws -> Result {
        let fixture = try DemoDriveTests.fixture()
        let model = DemoSensorModel(drive: fixture.drive)
        var selector = RoadPackSelector(candidates: [try RoadPackSelection.Candidate(name: "demo.roadpack",
                                                                                      pack: fixture.pack)])
        var run = LiveNavigationRun(sessionID: DemoSensorModel.sessionID,
                                    config: NavigationConfig(seed: DemoSensorModel.navigationSeed), appBuild: "golden")
        var lines = run.openingLines
        for input in model.canonicalInputs(until: 150) { run.ingest(input, selector: &selector) { lines.append($0) } }
        lines += run.closingLines()
        #expect(run.roads != nil && run.engine.obdEverIngested)
        return try result(run, lines: lines, seconds: 1...149, plane: fixture.drive.plane)
    }

    /// A synthetic OBD drive from (0, 0): drive-off, straight, a right turn,
    /// a stop, drive on; clean GNSS for 40 s, then tower-class network fixes
    /// every 10 s; a pin at 100 s. The header-based init (default config, the
    /// seed derived from the header), as the app builds an OBD run.
    static func syntheticRun() throws -> Result {
        let drive = S(initialHeadingDeg: 30, [
            .stop(seconds: 5), .ramp(seconds: 10, from: 0, to: 15), .straight(seconds: 30, speed: 15),
            .turn(degrees: 90, seconds: 10, speed: 12), .straight(seconds: 30, speed: 15),
            .ramp(seconds: 5, from: 15, to: 0), .stop(seconds: 10), .ramp(seconds: 5, from: 0, to: 10),
            .straight(seconds: 15, speed: 10),
        ])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        let pinAt = 100.0
        let pinTruth = drive.truth(at: pinAt)
        let pinPoint = S.plane.geodetic(east: pinTruth.east + 12, north: pinTruth.north - 7)
        let pin = LogEvent(timestamp: S.ms(pinAt), payload: .manualFix(ManualFixSample(
            latitude: pinPoint.latitude, longitude: pinPoint.longitude, pressedT: S.ms(pinAt), speedSource: "obd")))
        let events = drive.events(gyroNoise: 0.001, fix: { t, state, rng in
            if t < 40 { return clean(t, state, &rng) }
            guard Int(t.rounded()) % 10 == 0 else { return nil }
            return S.Fix(east: state.east + 200 * rng.nextGaussian(), north: state.north + 200 * rng.nextGaussian(),
                         accuracy: 1_414)
        }, extra: [pin])
        var run = LiveNavigationRun(header: WriterFixtures.header, appBuild: "golden", buildConfiguration: "release")
        var lines = run.openingLines
        for input in S.inputs(events) { run.ingest(input) { lines.append($0) } }
        lines += run.closingLines()
        #expect(run.engine.obdEverIngested && run.engine.counters.manualFixes == 1)
        #expect(run.engine.counters.networkFixesUsed > 0)
        return try result(run, lines: lines, seconds: 1...118, plane: S.plane)
    }

    @Test("Demo drive, OBD + roads, default config: estimates, sidecar lines, header and counters equal 5468cd9's")
    func demoGolden() throws {
        let r = try Self.demoRun()
        // Captured on 5468cd9 (debug build, `swift test`).
        #expect(r.estimates == 0xc85c_ac8d_bfd8_e6a8, "\(Self.describe(r))")
        #expect(r.lines == 0xae66_dbbf_3b7b_38ea)
        #expect(r.header == 0x2c46_9ce8_a795_502e)
        #expect(r.counters == 0x7ece_a773_a00d_a1fd)
        #expect(r.lineCount == 153)
        #expect(r.east == -53.43856085127421 && r.north == 1269.2114026931051)
        #expect(r.semiMajorM == 20.756247095730146 && r.headingDeg == 359.45110596745565)
    }

    @Test("Synthetic OBD drive via the header init (default config, derived seed): estimates, sidecar lines, header and counters equal 5468cd9's")
    func syntheticGolden() throws {
        let r = try Self.syntheticRun()
        // Captured on 5468cd9 (debug build, `swift test`).
        #expect(r.estimates == 0xb3e2_08e3_9406_2a3f, "\(Self.describe(r))")
        #expect(r.lines == 0x3285_d5a1_c5fa_3ee9)
        #expect(r.header == 0x6655_d6e8_3615_0a1a)
        #expect(r.counters == 0x1e4b_3594_d401_8305)
        #expect(r.lineCount == 122)
        #expect(r.east == 951.8965305422686 && r.north == 146.83917345015598)
        #expect(r.semiMajorM == 48.47637221178154 && r.headingDeg == 120.09281117078055)
    }
}
