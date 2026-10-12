import Foundation
import Testing

@testable import DriveLoggerCore

/// Q3 (N3.0): ellipse consistency with the truth's own σ added to the
/// engine's covariance, P + σ_truth² I, reported next to the engine-only
/// one and gated by the adoption rule.
@Suite("Navigation consistency with the truth's σ")
struct NavigationTruthSigmaConsistencyTests {
    typealias S = SyntheticDrive

    @Test("adding(isotropicSigmaM:) is the 95 % ellipse of P + σ² I, built from the covariance")
    func ellipseOfSum() {
        let cases: [(ee: Double, en: Double, nn: Double, sigma: Double)] = [
            (400, 0, 100, 30), (900, 300, 200, 3.3), (50, -40, 60, 104), (1e-6, 0, 1e-6, 10), (2500, 0, 2500, 0),
        ]
        for c in cases {
            let p = ErrorEllipse(covarianceEE: c.ee, en: c.en, nn: c.nn)
            let viaShortcut = p.adding(isotropicSigmaM: c.sigma)
            let s2 = c.sigma * c.sigma
            let direct = ErrorEllipse(covarianceEE: c.ee + s2, en: c.en, nn: c.nn + s2)
            #expect(abs(viaShortcut.semiMajorM - direct.semiMajorM) < 1e-9 * max(1, direct.semiMajorM), "\(c)")
            #expect(abs(viaShortcut.semiMinorM - direct.semiMinorM) < 1e-9 * max(1, direct.semiMinorM), "\(c)")
            if abs(p.semiMajorM - p.semiMinorM) > 1e-6 {
                #expect(abs(viaShortcut.orientationDeg - direct.orientationDeg) < 1e-9, "\(c)")
            }
        }
        // σ = 0 is the engine's own ellipse.
        let e = ErrorEllipse(semiMajorM: 120, semiMinorM: 40, orientationDeg: 35)
        #expect(e.adding(isotropicSigmaM: 0) == e)
    }

    @Test("Truth σ per axis: clean fix accuracy / 1.51, pin and truth-file σ as given, 0 when absent")
    func truthSigma() {
        #expect(abs(NavigationReplay.truthSigmaPerAxisM(kind: .cleanFix, truthSigmaM: 5) - 5 / 1.51) < 1e-12)
        #expect(NavigationReplay.truthSigmaPerAxisM(kind: .manualFix, truthSigmaM: 42) == 42)
        #expect(NavigationReplay.truthSigmaPerAxisM(kind: .truthPoint, truthSigmaM: 30) == 30)
        #expect(NavigationReplay.truthSigmaPerAxisM(kind: .truthEnd, truthSigmaM: nil) == 0)
        #expect(NavigationReplay.truthSigmaPerAxisM(kind: .truthEnd, truthSigmaM: -1) == 0)
        #expect(NavigationReplay.truthSigmaPerAxisM(kind: .truthPoint, truthSigmaM: .nan) == 0)
        // Not from the config: `fixSigmaPerAccuracy` must not move the truth.
        #expect(NavigationReplay.accuracyPerSigma == 1.51)
    }

    @Test("A pin 60 m off a tight ellipse: outside the engine ellipse, inside with its σ; same denominator")
    func pinInsideWithTruthSigma() throws {
        let drive = S(initialHeadingDeg: 45, initialSpeed: 10, [.straight(seconds: 60, speed: 10), .stop(seconds: 5)])
        let state = drive.truth(at: 40)
        let p = S.plane.geodetic(east: state.east + 60, north: state.north)
        let events = drive.events(fix: { t, state, rng in t <= 35 ? S.cleanFix()(t, state, &rng) : nil }, extra: [
            LogEvent(timestamp: S.ms(40), payload: .manualFix(ManualFixSample(
                latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(40), mapSpanM: 200, speedSource: "obd"))),
        ])
        let result = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events),
                                          options: ReplayOptions(gps: .use, config: S.config(particles: 200)))
        let pin = try #require(result.checkpoints.first { $0.kind == .manualFix })
        let a = try #require(pin.ellipseSemiMajorM)
        #expect(a < 50, "the engine's ellipse should be tight after 35 s of clean fixes: \(a) m")
        #expect(pin.inside95 == false)
        #expect(pin.inside95WithTruthSigma == true)
        #expect(pin.truthSigmaM == 30)
        // Consistency: same scored set, one more inside.
        #expect(result.consistency.all.scored == result.consistencyWithTruthSigma.all.scored)
        #expect(result.consistency.byKind["manualFix"] == .init(inside: 0, scored: 1))
        #expect(result.consistencyWithTruthSigma.byKind["manualFix"] == .init(inside: 1, scored: 1))
        // Reported: the summary and metrics.md show both, metrics.json keeps both.
        let summary = ReplayReport.summary(result)
        #expect(summary.contains("inside 95 %: no (+ truth σ: yes)"))
        #expect(summary.contains("+ truth σ") && summary.contains("gated"))
        let metrics = ReplayMetrics(result)
        #expect(metrics.consistencyWithTruthSigma == result.consistencyWithTruthSigma)
        #expect(ReplayReport.markdown([metrics]).contains("inside 95 % + truth σ (gated)"))
    }

    @Test("R19.1-1: a pin's truth σ is frozen, so raising the config's pin σ cannot widen the truth")
    func pinTruthSigmaIgnoresConfig() throws {
        let drive = S(initialHeadingDeg: 45, initialSpeed: 10, [.straight(seconds: 60, speed: 10), .stop(seconds: 5)])
        let state = drive.truth(at: 40)
        let p = S.plane.geodetic(east: state.east + 200, north: state.north)
        let events = drive.events(fix: { t, state, rng in t <= 35 ? S.cleanFix()(t, state, &rng) : nil }, extra: [
            LogEvent(timestamp: S.ms(40), payload: .manualFix(ManualFixSample(
                latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(40), mapSpanM: 200, speedSource: "obd"))),
        ])
        func pin(_ config: NavigationConfig) throws -> (ReplayResult.Checkpoint, ReplayResult) {
            let result = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events),
                                              options: ReplayOptions(gps: .use, config: config))
            return (try #require(result.checkpoints.first { $0.kind == .manualFix }), result)
        }
        let base = S.config(particles: 200)
        var wide = base
        wide.manualFixSigmaMinM = 120
        #expect(wide.manualFixSigma(mapSpanM: 200) == 120, "the engine's pin σ does move")
        let (a, ra) = try pin(base)
        let (b, rb) = try pin(wide)
        // The engine's prior at the pin does not depend on the pin's σ: bit-identical.
        #expect(a.estimateLatitude != nil && a.estimateLatitude == b.estimateLatitude)
        #expect(a.estimateLongitude == b.estimateLongitude && a.errorM == b.errorM)
        #expect(a.ellipseSemiMajorM == b.ellipseSemiMajorM && a.ellipseSemiMinorM == b.ellipseSemiMinorM)
        #expect(a.ellipseOrientationDeg == b.ellipseOrientationDeg && a.inside95 == b.inside95)
        let semiMajor = try #require(a.ellipseSemiMajorM)
        #expect(semiMajor < 50, "tight after 35 s of clean fixes: \(semiMajor) m")
        // So the truth must not widen either: same σ, still outside.
        #expect(a.truthSigmaM == 30 && b.truthSigmaM == 30)
        #expect(a.inside95WithTruthSigma == false)
        #expect(b.inside95WithTruthSigma == false, "a config's pin σ moved the truth")
        #expect(ra.consistencyWithTruthSigma == rb.consistencyWithTruthSigma)
        // The frozen formula: today's engine rule with its N3.0 defaults.
        #expect(NavigationReplay.manualFixTruthSigmaM(mapSpanM: nil) == 30)
        #expect(NavigationReplay.manualFixTruthSigmaM(mapSpanM: 1_248) == 104)
        #expect(NavigationReplay.manualFixTruthSigmaM(mapSpanM: 372) == 31)
        for bad in [0, -5, Double.nan, .infinity] {
            #expect(NavigationReplay.manualFixTruthSigmaM(mapSpanM: bad) == 30, "span \(bad)")
        }
    }

    @Test("Adding a σ never turns inside into outside, and the variant is never below the engine-only share")
    func monotone() {
        let e = ErrorEllipse(semiMajorM: 80, semiMinorM: 20, orientationDeg: 60)
        var rng = NavigationRandom(seed: 3)
        for _ in 0..<2_000 {
            let de = 150 * rng.nextGaussian(), dn = 150 * rng.nextGaussian()
            let sigma = 50 * abs(rng.nextGaussian())
            if e.contains(dEast: de, dNorth: dn) {
                #expect(e.adding(isotropicSigmaM: sigma).contains(dEast: de, dNorth: dn))
            }
        }
    }
}
