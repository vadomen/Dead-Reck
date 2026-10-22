import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-20 replay tooling (`replay_nav --save-prior`, `--prior`, `--start-at`,
/// `--prior-offset`): the same Core code as the app. Synthetic drive and
/// clock at (0, 0) only.
@Suite("Navigation UX-20: restore in the replay")
struct NavigationRestoreReplayTests {
    typealias S = SyntheticDrive

    static let drive = S(initialHeadingDeg: 45, [
        .ramp(seconds: 4, from: 0, to: 12), .straight(seconds: 30, speed: 12), .ramp(seconds: 4, from: 12, to: 0),
        .stop(seconds: 10), .ramp(seconds: 4, from: 0, to: 10), .straight(seconds: 20, speed: 10),
    ])
    static let inputs = S.inputs(drive.events(gyroNoise: 0.001, fix: S.cleanFix()))
    static let clock = SessionClock(referenceUptimeSeconds: 100, wallClockStart: Date(timeIntervalSince1970: 2_000_000_000))

    static func options() -> ReplayOptions {
        ReplayOptions(gps: .use, config: S.config(particles: 200))
    }

    @Test func saveCapturesTheEngineStateAtTheTime() throws {
        var options = Self.options()
        options.savePrior = ReplaySavePrior(atS: 45, referenceUptimeSeconds: 100,
                                            wallClockStart: Date(timeIntervalSince1970: 2_000_000_000))
        let result = NavigationReplay.run(logName: "synthetic", inputs: Self.inputs, options: options)
        let saved = try #require(result.savedRestoreState)
        var engine = NavigationEngine(config: options.config)
        for input in Self.inputs where input.arrival <= S.ms(45) { engine.ingest(input) }
        let expected = try #require(NavigationRestoreState.capture(engine, at: S.ms(45), clock: Self.clock,
                                                                   bootSessionID: nil, engineOff: false))
        #expect(saved == expected)
        #expect(saved.restoreClass == .standingStop)
        // Saving changes no number and no label.
        let plain = NavigationReplay.run(logName: "synthetic", inputs: Self.inputs, options: Self.options())
        var stripped = result
        stripped.savedRestoreState = nil
        stripped.msPerStep = plain.msPerStep
        stripped.maxIngestMs = plain.maxIngestMs
        #expect(stripped == plain)
        // At the end.
        options.savePrior?.atS = .infinity
        let atEnd = NavigationReplay.run(logName: "synthetic", inputs: Self.inputs, options: options)
        #expect(try #require(atEnd.savedRestoreState).uptimeSeconds == 100 + atEnd.endT)
    }

    @Test func startAtAndPriorSeedTheCutRun() throws {
        var save = Self.options()
        save.savePrior = ReplaySavePrior(atS: 45, referenceUptimeSeconds: 100,
                                         wallClockStart: Date(timeIntervalSince1970: 2_000_000_000))
        let state = try #require(NavigationReplay.run(logName: "synthetic", inputs: Self.inputs, options: save)
            .savedRestoreState)
        // Relaunched at 47 s, still stopped: the inputs before are gone.
        var cut = Self.options()
        cut.gps = .none
        cut.startAtS = 47
        let fresh = NavigationReplay.run(logName: "synthetic", inputs: Self.inputs, options: cut)
        #expect(fresh.startT >= 47)
        #expect(fresh.restore == nil)
        #expect(fresh.track.isEmpty || fresh.track.allSatisfy { $0.t >= 47 })
        #expect(fresh.counters.fixesUsed == 0)
        #expect(cut.label == "none-from-47")
        cut.prior = state.prior(at: S.ms(47), clock: Self.clock, bootSessionID: nil)
        let prior = try #require(cut.prior)
        #expect(abs(prior.savedT.seconds - 45) < 1e-6)
        #expect(cut.label == "none-from-47-restored")
        let restored = NavigationReplay.run(logName: "synthetic", inputs: Self.inputs, options: cut)
        let restore = try #require(restored.restore)
        #expect(restore.status == .unconfirmed)
        #expect(restore.savedT == prior.savedT)
        // No fix at all after the cut, yet a track from the restored prior,
        // near the truth at the end.
        let last = try #require(restored.track.last)
        let p = S.plane.enu(latitude: last.latitude, longitude: last.longitude)
        let truth = Self.drive.truth(at: last.t)
        #expect(((p.east - truth.east) * (p.east - truth.east) + (p.north - truth.north) * (p.north - truth.north))
            .squareRoot() < 30)
        #expect(last.converged)
    }

    @Test func priorOffsetMovesTheSavedPosition() {
        let p = S.plane.geodetic(east: 100, north: 200)
        let state = NavigationRestoreState(
            savedAt: Date(timeIntervalSince1970: 2_000_000_000), bootSessionID: nil, uptimeSeconds: 100,
            latitude: p.latitude, longitude: p.longitude, covEE: 25, covEN: 0, covNN: 25, headingDeg: 10,
            headingStdDeg: 2, converged: true, restoreClass: .parked, speedMps: 0, lastOBDSpeedKmh: 0, lastOBDAgeS: 3)
        let moved = state.shifted(eastM: 2000, northM: -300)
        let q = S.plane.enu(latitude: moved.latitude, longitude: moved.longitude)
        #expect(abs(q.east - 2100) < 0.5 && abs(q.north - (-100)) < 0.5)
        #expect(moved.covEE == state.covEE && moved.restoreClass == state.restoreClass)
    }
}
