import Foundation
import Testing

@testable import DriveLogger

// UX-7 (prompt 47), the map's part: the status card, the speed estimate, the
// uncertain treatment and its voice line. Synthetic instants only.

@Suite("No-OBD run on the map (UX-7)")
struct NoOBDMapTests {
    let timings = NavigateConfiguration()  // 30 s no-OBD start
    let t0 = ContinuousClock.Instant.now

    func status(
        _ navigate: NavigateState, recording: RecordingState = .idle,
        noOBD: NoOBDNavigationStatus? = nil, armedAt: ContinuousClock.Instant? = nil,
        timings custom: NavigateConfiguration? = nil, after: Duration = .zero
    ) -> NavigateStatus {
        NavigateStatus.make(
            navigate: navigate, recording: recording, startedAt: nil, timings: custom ?? timings,
            now: t0 + after, noOBD: noOBD, noOBDStartArmedAt: armedAt)
    }

    // MARK: Card

    @Test("A no-OBD run shows the persistent label and the Stop control, estimate drawn")
    func runLabel() {
        let s = status(.runningNoOBD, noOBD: NoOBDNavigationStatus())
        #expect(s == .noOBD(uncertain: false))
        #expect(s.text == "No OBD — lower accuracy")
        #expect(s.secondLine == nil)
        #expect(s.hasStop)
        #expect(s.showsEstimate)
        #expect(s.tone == .caution)
        // Before the service's first reading the label is already there.
        #expect(status(.runningNoOBD) == .noOBD(uncertain: false))
    }

    @Test("Uncertain keeps the label, adds the second line and turns the tone red")
    func runUncertain() {
        let s = status(.runningNoOBD, noOBD: NoOBDNavigationStatus(positionUncertain: true))
        #expect(s == .noOBD(uncertain: true))
        #expect(s.text == "No OBD — lower accuracy")
        #expect(s.secondLine == "Position uncertain")
        #expect(s.tone == .bad)
        #expect(s.hasStop)
        #expect(s.systemImage != status(.runningNoOBD).systemImage, "not colour alone")
    }

    @Test("No other state has the Stop control or the no-OBD label")
    func othersHaveNoStop() {
        let others: [NavigateStatus] = [
            status(.running), status(.calibrating), status(.waitingForOBD(since: t0)),
            status(.off), status(.off, armedAt: t0),
        ]
        for s in others {
            #expect(!s.hasStop)
            #expect(s.secondLine == nil)
            #expect(s.text != "No OBD — lower accuracy")
        }
        #expect(status(.running, noOBD: NoOBDNavigationStatus(positionUncertain: true)) == .hidden,
                "a stale no-OBD status never leaks into an OBD run")
    }

    @Test("Armed start timer: Starting without OBD with the seconds left, rounded up, never below 0")
    func startingCountdown() {
        func s(_ after: Duration) -> NavigateStatus { status(.off, armedAt: t0, after: after) }
        #expect(s(.zero) == .startingNoOBD(secondsLeft: 30))
        #expect(s(.milliseconds(1)) == .startingNoOBD(secondsLeft: 30))
        #expect(s(.seconds(9)) == .startingNoOBD(secondsLeft: 21))
        #expect(s(.seconds(30)) == .startingNoOBD(secondsLeft: 0))
        #expect(s(.seconds(40)) == .startingNoOBD(secondsLeft: 0))
        #expect(s(.seconds(9)).text == "Starting without OBD…")
        #expect(s(.seconds(9)).detail == "21")
        #expect(!s(.zero).showsEstimate, "no engine yet")
        #expect(s(.zero).tone == .caution)
    }

    @Test("Not armed: Connect OBD stays; without a start delay (demo) the timer never shows; a recording owns the screen")
    func startingOnlyWhenArmed() {
        #expect(status(.off) == .needsOBD)
        var demo = timings
        demo.noOBDStartAfter = nil
        #expect(status(.off, armedAt: t0, timings: demo) == .needsOBD)
        for recording in [RecordingState.calibrating, .recording, .stopping] {
            #expect(status(.off, recording: recording, armedAt: t0) == .hidden)
        }
    }

    // MARK: Display and speed estimate

    @Test("The display exists only in a no-OBD run")
    func displayOnlyInNoOBD() {
        let st = NoOBDNavigationStatus(positionUncertain: true, estimatedSpeedKmh: 40)
        for nav in [NavigateState.off, .calibrating, .running, .waitingForOBD(since: t0)] {
            #expect(NoOBDDisplay.make(navigate: nav, status: st) == nil)
        }
        #expect(NoOBDDisplay.make(navigate: .runningNoOBD, status: st) == NoOBDDisplay(uncertain: true, estimatedKmh: 40))
        #expect(NoOBDDisplay.make(navigate: .runningNoOBD, status: nil) == NoOBDDisplay(uncertain: false, estimatedKmh: nil))
    }

    @Test("The estimate shows as ≈ N, estimated: never OBD, never GPS, nothing emphasised")
    func estimateChip() {
        let shown = NoOBDDisplay(uncertain: false, estimatedKmh: 33.6).speed(base: .none)
        #expect(shown.source == .estimated)
        #expect(shown.kmh == 34)
        #expect(shown.valueText == "≈34")
        #expect(shown.sourceText == "estimated")
        #expect(shown.note == "estimated")
        #expect(shown.spokenSpeed == "about 34 km/h, estimated")
        #expect(shown.summary == "about 34 km/h, estimated")
        #expect(shown.measuredKmh == nil, "the camera's zoom never follows an estimate")
        let hud = MapHUDState.make(speed: shown, gps: .none, obd: .none, thermal: .nominal)
        #expect(hud.speedText == "≈34")
        #expect(hud.speedNote == "estimated")
        #expect(!hud.gps.emphasised && !hud.obd.emphasised)
        #expect(hud.accessibilitySummary.hasPrefix("about 34 km/h, estimated, "))
        #expect(MapHUDState.make(speed: .none, gps: .none, obd: .none, thermal: .nominal).speedNote == nil)
    }

    @Test("Estimate rounding: nearest km/h, never negative; zero shows ≈0")
    func estimateRounding() {
        func text(_ v: Double) -> String { NoOBDDisplay(uncertain: false, estimatedKmh: v).speed(base: .none).valueText }
        #expect(text(0) == "≈0")
        #expect(text(0.4) == "≈0")
        #expect(text(-3) == "≈0")
        #expect(text(88.5) == "≈89")
    }

    @Test("Hidden while uncertain, with no estimate, or a non-finite one")
    func estimateHidden() {
        #expect(NoOBDDisplay(uncertain: true, estimatedKmh: 34).speed(base: .none) == .none)
        #expect(NoOBDDisplay(uncertain: false, estimatedKmh: nil).speed(base: .none) == .none)
        #expect(NoOBDDisplay(uncertain: false, estimatedKmh: .nan).speed(base: .none) == .none)
        #expect(NoOBDDisplay(uncertain: false, estimatedKmh: .infinity).speed(base: .none) == .none)
    }

    @Test("A measurement wins: a fresh GPS speed is shown as GPS, uncertain or not")
    func measurementWins() {
        let gps = MapSpeedReadout(source: .gps, kmh: 52, quality: .good)
        for uncertain in [false, true] {
            #expect(NoOBDDisplay(uncertain: uncertain, estimatedKmh: 34).speed(base: gps) == gps)
        }
        #expect(gps.measuredKmh == 52)
    }

    @Test("DEBUG fakes: noOBD and noOBDUncertain describe a no-OBD run with a 34 km/h estimate")
    func fakes() {
        let run = HUDFakes.parse("noOBD")
        #expect(run.isActive && run.noOBDRun && run.obd == .none)
        #expect(run.noOBD == NoOBDDisplay(uncertain: false, estimatedKmh: 34))
        #expect(HUDFakes.parse("noOBDUncertain").noOBD == NoOBDDisplay(uncertain: true, estimatedKmh: 34))
        #expect(HUDFakes.parse("ok").noOBD == nil)
        #expect(run.noOBD?.speed(base: run.speed).valueText == "≈34")
    }
}

@MainActor
@Suite("Position uncertain voice (UX-7)")
struct PositionUncertainVoiceTests {
    @MainActor
    final class FakeSpeaker: GPSSpeaking {
        var said: [String] = []
        func speak(_ text: String) { said.append(text) }
    }

    private func note(_ t: inout PositionUncertainTracker, _ uncertain: Bool, _ run: Int?) -> Bool {
        t.note(uncertain, run: run)
    }

    @Test("Tracker: one line per episode; cleared by a fix, the next episode speaks again")
    func perEpisode() {
        var t = PositionUncertainTracker()
        #expect(!note(&t, false, 1))
        #expect(note(&t, true, 1), "the episode starts")
        #expect(!note(&t, true, 1), "still the same episode")
        #expect(!note(&t, true, 1))
        #expect(!note(&t, false, 1), "cleared by a fix or pin: silent")
        #expect(note(&t, true, 1), "a second episode speaks")
    }

    @Test("Tracker: no run resets; a new run starts certain, and one first seen uncertain speaks once")
    func runs() {
        var t = PositionUncertainTracker()
        #expect(note(&t, true, 1))
        #expect(!note(&t, true, nil), "no run: silent")
        #expect(!note(&t, false, nil))
        #expect(note(&t, true, 2), "a new run is its own episode")
        #expect(!note(&t, true, 2))
        #expect(note(&t, true, 3), "run swap without nil in between")
        var fresh = PositionUncertainTracker()
        #expect(!note(&fresh, false, nil), "never speaks without a run")
        #expect(!note(&fresh, true, nil))
    }

    @Test("Announcer: silent with the Settings switch off, spoken once with it on, no 5 min limiter between episodes")
    func announcer() {
        let speaker = FakeSpeaker()
        let voice = GPSVoiceAnnouncer(speaker: speaker, now: { 0 })
        #expect(!voice.noteUncertain(false, run: 1, enabled: true))
        #expect(!voice.noteUncertain(true, run: 1, enabled: false), "switch off: nothing")
        #expect(speaker.said.isEmpty)
        #expect(!voice.noteUncertain(true, run: 1, enabled: true), "same episode, already past its start")
        #expect(!voice.noteUncertain(false, run: 1, enabled: true))
        #expect(voice.noteUncertain(true, run: 1, enabled: true))
        #expect(speaker.said == ["Position uncertain"])
        #expect(!voice.noteUncertain(false, run: 1, enabled: true))
        #expect(voice.noteUncertain(true, run: 1, enabled: true), "a new episode (at least 120 s later) speaks")
        #expect(speaker.said.count == 2)
        #expect(!voice.noteUncertain(true, run: nil, enabled: true), "spoken only during a run")
    }
}
