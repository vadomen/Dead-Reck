import Foundation
import Testing

@testable import DriveLoggerCore

/// R13.1-8: the replay's metric helpers that no test pinned down. The
/// convergence hold, the distance integrator's stale cap, and one
/// denominator for every "inside 95 %" figure.
@Suite("Navigation replay metrics")
struct NavigationReplayMetricTests {
    typealias S = SyntheticDrive

    static func track(_ converged: [Bool], everyS: Double = 1) -> [ReplayResult.TrackPoint] {
        converged.enumerated().map { index, c in
            ReplayResult.TrackPoint(t: Double(index) * everyS, latitude: 0, longitude: 0, headingDeg: 0, headingStdDeg: 1,
                                    converged: c, distanceM: Double(index) * 10, speedScale: 1)
        }
    }

    // MARK: Convergence hold

    @Test("Convergence needs `converged` held for the whole hold: a shorter run does not count, the boundary is inclusive")
    func convergenceHold() throws {
        // Converged 0–29 s (29 s held), broken at 30, then from 31 s on.
        let flags = (0..<30).map { _ in true } + [false] + (0..<40).map { _ in true }
        let result = try #require(NavigationReplay.convergence(Self.track(flags), holdS: 30))
        #expect(result.t == 31 && result.distanceM == 310)
        // Exactly 30 s held (31 points at 1 s) counts; 29 s does not.
        #expect(NavigationReplay.convergence(Self.track((0..<31).map { _ in true }), holdS: 30)?.t == 0)
        #expect(NavigationReplay.convergence(Self.track((0..<30).map { _ in true }), holdS: 30) == nil)
        // Without the hold the first converged point would win.
        #expect(NavigationReplay.convergence(Self.track(flags), holdS: 0)?.t == 0)
        // Never converged long enough before the end.
        #expect(NavigationReplay.convergence(Self.track([false, true, true, false, true]), holdS: 30) == nil)
    }

    @Test("In a replay the hold is `convergenceHoldS`: longer than the drive means never converged")
    func convergenceHoldInReplay() {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [.straight(seconds: 60, speed: 10)])
        let events = drive.events(fix: { t, state, rng in S.cleanFix()(t, state, &rng) })
        var options = ReplayOptions(gps: .use, config: S.config(particles: 100))
        let held = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events), options: options)
        #expect(held.convergedT != nil)
        options.convergenceHoldS = 120
        let never = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events), options: options)
        #expect(never.convergedT == nil && never.convergedDistanceM == nil)
    }

    // MARK: Distance integrator cap

    static func speed(_ kmh: Double, ecu: String? = "7E8") -> OBDSample {
        OBDSample(pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: ecu)
    }

    @Test("Distance holds the last OBD speed for at most obdMaxAgeS, then stops (no reply = unknown, not moving)")
    func distanceStaleCap() {
        var d = DistanceIntegrator()
        let s = 1_000_000_000 as Int64
        d.observe(Self.speed(35.5), at: 0, maxAgeS: 2, offsetKmh: 0.5)  // (35.5 + 0.5) / 3.6 = 10 m/s
        #expect(abs(d.distance(at: s) - 10) < 1e-9)
        #expect(abs(d.distance(at: 2 * s) - 20) < 1e-9)
        // A 60 s silence adds only the capped 2 s.
        #expect(abs(d.distance(at: 60 * s) - 20) < 1e-9)
        // The next reply integrates the capped hold, then restarts.
        d.observe(Self.speed(35.5), at: 60 * s, maxAgeS: 2, offsetKmh: 0.5)
        #expect(abs(d.distance(at: 61 * s) - 30) < 1e-9)
        // 0 km/h is a stop (no offset); another ECU and a negative or
        // non-finite value are ignored.
        d.observe(Self.speed(0), at: 61 * s, maxAgeS: 2, offsetKmh: 0.5)
        d.observe(Self.speed(100, ecu: "7E9"), at: 61 * s, maxAgeS: 2, offsetKmh: 0.5)
        d.observe(Self.speed(-5), at: 61 * s, maxAgeS: 2, offsetKmh: 0.5)
        d.observe(Self.speed(.nan), at: 61 * s, maxAgeS: 2, offsetKmh: 0.5)
        #expect(abs(d.distance(at: 70 * s) - 30) < 1e-9)
    }

    @Test("In a replay an OBD dropout adds at most obdMaxAgeS of held speed to the distance")
    func distanceCapInReplay() {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 10, [.straight(seconds: 60, speed: 10)])
        // OBD silent from 20 s to 50 s while the car keeps going.
        let gap = drive.events(obdSpeed: { t, state in t > 20 && t < 50 ? nil : (state.speed * 3.6).rounded(.down) },
                               fix: { t, state, rng in S.cleanFix()(t, state, &rng) })
        let full = drive.events(fix: { t, state, rng in S.cleanFix()(t, state, &rng) })
        let options = ReplayOptions(gps: .use, config: S.config(particles: 100))
        let a = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: gap), options: options)
        let b = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: full), options: options)
        // ~30 s at ~10 m/s are missing, less the 2 s cap.
        let missing = b.distanceM - a.distanceM
        #expect(missing > 270 && missing < 290, "missing \(missing) m")
    }

    // MARK: One denominator

    @Test("Clean fixes before initialisation are in neither count; the summary and metrics.md use the consistency's counts")
    func oneDenominator() throws {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [.straight(seconds: 60, speed: 10), .stop(seconds: 5)])
        let pin = drive.truth(at: 30)
        let p = S.plane.geodetic(east: pin.east, north: pin.north)
        let events = drive.events(fix: { t, state, rng in S.cleanFix()(t, state, &rng) }, extra: [
            LogEvent(timestamp: S.ms(30), payload: .manualFix(ManualFixSample(
                latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(30), mapSpanM: 200, speedSource: "obd"))),
        ])
        // Every fix withheld: the pin at 30 s initialises.
        let result = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events),
                                          options: ReplayOptions(gps: .none, config: S.config(particles: 200)))
        let clean = result.checkpoints.filter { $0.kind == .cleanFix }
        let withEstimate = clean.filter { $0.inside95 != nil }
        let before = clean.count - withEstimate.count
        #expect(before >= 25 && !withEstimate.isEmpty)
        let counts = try #require(result.consistency.byKind["cleanFix"])
        #expect(counts.scored == withEstimate.count)
        #expect(counts.inside == withEstimate.filter { $0.inside95 == true }.count)
        let figure = "\(counts.inside)/\(counts.scored) (\(before) before initialisation)"
        #expect(ReplayReport.summary(result).contains("inside 95 % \(figure)"))
        #expect(ReplayReport.markdown([ReplayMetrics(result)]).contains("| \(figure) |"))
        // With an estimate at every clean fix the figure is plain x/y, as before.
        #expect(ReplayReport.cleanFixInside(5, EllipseConsistency(Array(withEstimate.prefix(5)))).hasSuffix("/5"))
    }

    // MARK: Max error per kind (R19.1-2)

    static func checkpoint(_ kind: ReplayResult.Checkpoint.Kind, t: Double, distanceM: Double, errorM: Double?)
        -> ReplayResult.Checkpoint {
        var cp = ReplayResult.Checkpoint(kind: kind, t: t, latitude: 0, longitude: 0, distanceM: distanceM)
        cp.errorM = errorM
        cp.errorPercent = errorM.flatMap { distanceM > 0 ? 100 * $0 / distanceM : nil }
        return cp
    }

    /// The run's max error covers every kind, so with pins it can be a
    /// pin's; the drives gated on their clean fixes need the clean fixes
    /// alone, and the largest % of distance, which is not the largest
    /// error in metres here. Unscored checkpoints count in neither.
    @Test("maxErrorByKind: per kind over scored checkpoints, the largest error and the largest % of distance")
    func maxErrorByKind() throws {
        var refinement = Self.checkpoint(.manualFix, t: 16, distanceM: 1500, errorM: 900)
        refinement.notScored = .init(reason: .refinement, firstPinT: 15)
        var late = Self.checkpoint(.cleanFix, t: 40, distanceM: 9000, errorM: 999)
        late.afterScoreUntilT = true
        let checkpoints = [
            Self.checkpoint(.cleanFix, t: 5, distanceM: 0, errorM: 3),        // no distance yet: no %
            Self.checkpoint(.cleanFix, t: 10, distanceM: 1000, errorM: 50),   // 5 %
            Self.checkpoint(.manualFix, t: 15, distanceM: 1500, errorM: 210), // the run's max error
            refinement,
            Self.checkpoint(.cleanFix, t: 20, distanceM: 4000, errorM: 80),   // 2 %, the largest clean error
            Self.checkpoint(.cleanFix, t: 25, distanceM: 5000, errorM: nil),  // before initialisation
            late,
        ]
        let byKind = KindMaxError.byKind(checkpoints)
        #expect(Set(byKind.keys) == ["cleanFix", "manualFix"])
        #expect(byKind["cleanFix"] == KindMaxError(scored: 3, maxErrorM: 80, maxErrorT: 20, maxPercent: 5, maxPercentT: 10))
        #expect(byKind["manualFix"] == KindMaxError(scored: 1, maxErrorM: 210, maxErrorT: 15, maxPercent: 14, maxPercentT: 15))
        #expect(KindMaxError.byKind([Self.checkpoint(.cleanFix, t: 5, distanceM: 0, errorM: 3)])["cleanFix"]
            == KindMaxError(scored: 1, maxErrorM: 3, maxErrorT: 5))
        #expect(KindMaxError.byKind([late, refinement]).isEmpty)
        #expect(ReplayReport.maxByKindText(byKind)
            == "cleanFix 3: 80 m (t 20.0 s), 5.00 % (t 10.0 s); manualFix 1: 210 m (t 15.0 s), 14.00 % (t 15.0 s)")
        #expect(ReplayReport.maxByKindText([:]) == nil)
    }

    /// In a replay: the result, metrics.json, the summary and metrics.md
    /// carry it; the run's max error (here a pin's) is unchanged.
    @Test("maxErrorByKind in a replay: result, metrics row, summary line and metrics.md columns")
    func maxErrorByKindInAReplay() throws {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [.straight(seconds: 60, speed: 10), .stop(seconds: 5)])
        let pin = drive.truth(at: 50)
        let p = S.plane.geodetic(east: pin.east + 150, north: pin.north)
        let events = drive.events(fix: { t, state, rng in S.cleanFix()(t, state, &rng) }, extra: [
            LogEvent(timestamp: S.ms(50), payload: .manualFix(ManualFixSample(
                latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(50), mapSpanM: 200, speedSource: "obd"))),
        ])
        let result = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events),
                                          options: ReplayOptions(gps: .maskAfter(seconds: 20), config: S.config(particles: 200)))
        let clean = result.checkpoints.filter { $0.kind == .cleanFix && $0.isScored && $0.errorM != nil }
        let byClean = try #require(result.maxErrorByKind["cleanFix"])
        #expect(byClean.scored == clean.count && clean.count > 10)
        #expect(byClean.maxErrorM == clean.compactMap(\.errorM).max())
        #expect(byClean.maxPercent == clean.compactMap(\.errorPercent).max())
        // The pin, 150 m off, is the run's max error, not a clean fix.
        let manual = try #require(result.maxErrorByKind["manualFix"])
        #expect(result.maxErrorM == manual.maxErrorM && manual.maxErrorM > byClean.maxErrorM)
        let metrics = ReplayMetrics(result)
        #expect(metrics.maxErrorByKind == result.maxErrorByKind)
        #expect(ReplayReport.summary(result).contains("Max by kind   cleanFix \(clean.count): "))
        let markdown = ReplayReport.markdown([metrics])
        #expect(markdown.contains("| clean-fix max err m | clean-fix max % |"))
        #expect(markdown.contains(" | \(ReplayReport.m(byClean.maxErrorM)) | \(ReplayReport.pct(byClean.maxPercent)) |\n"))
        var old = metrics
        old.maxErrorByKind = nil
        #expect(ReplayReport.markdown([old]).contains(" | n/a | n/a |\n"))
    }
}
