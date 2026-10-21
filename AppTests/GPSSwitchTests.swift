import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Fixtures are small offsets around (0, 0); no real places.
private func fix(t: Double, lat: Double = 0.001, speed: Double = 15) -> LocationSample {
    LocationSample(
        latitude: lat, longitude: 0.001, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
        speed: speed, speedAccuracy: 1, course: 0, courseAccuracy: 5,
        receivedT: MonotonicTimestamp(seconds: t), ageS: 0)
}

@MainActor
@Suite("GPS switch: HUD, rail control, map")
struct GPSSwitchHUDTests {
    @Test("Switch wins over staleness; otherwise stale decides")
    func gpsState() {
        #expect(MapHUDState.gpsState(stale: false, switchedOff: true) == .off)
        #expect(MapHUDState.gpsState(stale: true, switchedOff: true) == .off)
        #expect(MapHUDState.gpsState(stale: true) == .none)
        #expect(MapHUDState.gpsState(stale: false) == .ok)
    }

    @Test("GPS off has its own label and glyph flag, distinct from No GPS")
    func offIndicator() {
        let speed = MapSpeedReadout(source: .obd, kmh: 40, quality: .good)
        let off = MapHUDState.make(speed: speed, gps: .off, obd: .connected, thermal: .nominal)
        let none = MapHUDState.make(speed: speed, gps: .none, obd: .connected, thermal: .nominal)
        #expect(off.gps.label == "GPS off" && off.gps.switchedOff && off.gps.failed)
        #expect(none.gps.label == "No GPS" && !none.gps.switchedOff && none.gps.failed)
        #expect(off.accessibilitySummary.contains("GPS off"))
    }

    @Test("Rail control: texts, state, enablement")
    func control() {
        let on = GPSSwitchControl.make(switchOn: true, runActive: true)
        #expect(on.caption == "GPS off" && on.inputLabels == ["GPS off"] && !on.active && on.enabled)
        #expect(on.accessibilityLabel == "Turn GPS off, dead reckoning only")
        let off = GPSSwitchControl.make(switchOn: false, runActive: true)
        #expect(off.caption == "Use GPS" && off.inputLabels == ["Use GPS"] && off.active)
        #expect(off.accessibilityLabel == "Turn GPS back on")
        #expect(off.symbol != on.symbol)
        #expect(!GPSSwitchControl.make(switchOn: true, runActive: false).enabled)
        #expect(!GPSSwitchControl.make(switchOn: false, runActive: false).enabled)
    }

    @Test("Four 56 pt rail buttons still clear the HUD card on the smallest phone (667 pt)")
    func railFits() {
        let railTop = 667 - MapLayout.bottomInset() - MapLayout.railHeight
        // Status bar (20) + HUD card with recording and thermal rows (~190).
        #expect(railTop > 20 + 190)
        #expect(MapLayout.railReserved == 80)
    }

    @Test("Speed never falls back to GPS while GPS is off; it returns with Use GPS")
    func speedDash() {
        let model = MapViewModel()
        model.ingest(fix(t: 10), file: nil, run: 1, isActive: true, elapsed: 10)
        model.setOBDSpeed(nil, replyUptime: nil, now: 100)
        #expect(model.speed.source == .gps)
        model.setGPSSwitch(on: false)
        #expect(model.speed == .none && model.speed.valueText == "—")
        // A fresh fix while off changes nothing.
        model.ingest(fix(t: 11), file: nil, run: 1, isActive: true, elapsed: 11)
        #expect(model.speed == .none)
        // OBD still wins while off.
        model.setOBDSpeed(50, replyUptime: 100, now: 100.5)
        #expect(model.speed.source == .obd)
        model.setOBDSpeed(nil, replyUptime: nil, now: 101)
        #expect(model.speed == .none)
        model.setGPSSwitch(on: true)
        #expect(model.speed.source == .gps)
    }

    @Test("While off: no marker, no track growth; after Use GPS the track resumes in a new segment")
    func trackAndMarker() {
        let model = MapViewModel()
        model.ingest(fix(t: 10), file: nil, run: 1, isActive: true, elapsed: 10)
        model.ingest(fix(t: 12, lat: 0.002), file: nil, run: 1, isActive: true, elapsed: 12)
        #expect(model.track.points.count == 2)
        #expect(model.shown(whileDemo: false).latest != nil)

        model.setGPSSwitch(on: false)
        #expect(model.shown(whileDemo: false).latest == nil, "marker and circle hidden")
        model.ingest(fix(t: 14, lat: 0.003), file: nil, run: 1, isActive: true, elapsed: 14)
        model.ingest(fix(t: 16, lat: 0.004), file: nil, run: 1, isActive: true, elapsed: 16)
        #expect(model.track.points.count == 2, "the spoofed fixes are not drawn")

        model.setGPSSwitch(on: true)
        #expect(model.shown(whileDemo: false).latest != nil)
        // The gap is only 6 s, far below the 30 s gap rule: the break is explicit.
        model.ingest(fix(t: 18, lat: 0.005), file: nil, run: 1, isActive: true, elapsed: 18)
        #expect(model.track.points.count == 3)
        #expect(model.track.points.last?.segmentStart == true)
        #expect(model.track.runs.count == 2, "no chord across the gap")
        model.ingest(fix(t: 20, lat: 0.006), file: nil, run: 1, isActive: true, elapsed: 20)
        #expect(model.track.points.last?.segmentStart == false)
    }

    @Test("Switch calls are idempotent; a new run's track starts on")
    func idempotentAndNewRun() {
        let model = MapViewModel()
        model.setGPSSwitch(on: true)
        #expect(!model.gpsOff)
        model.setGPSSwitch(on: false)
        model.setGPSSwitch(on: false)
        #expect(model.gpsOff)
        model.setGPSSwitch(on: true)
        model.ingest(fix(t: 10), file: nil, run: 2, isActive: true, elapsed: 10)
        #expect(model.track.points.count == 1)
    }

    @Test("GPSTrack.breakSegment only affects the next accepted point")
    func breakSegment() {
        var track = GPSTrack()
        track.append(fix(t: 0))
        track.append(fix(t: 2, lat: 0.002))
        track.breakSegment()
        track.append(fix(t: 4, lat: 0.003))
        track.append(fix(t: 6, lat: 0.004))
        #expect(track.points.map(\.segmentStart) == [true, false, true, false])
    }

    @Test("DEBUG fake: gpsOff with OBD lost shows a dash, not the GPS speed")
    func fakeSpeed() {
        let f = HUDFakes.parse("gpsOff,obdLost")
        #expect(f.gpsOff && f.speed == .none)
        #expect(HUDFakes.parse("obdLost").speed.source == .gps)
    }

    @Test("R74.2-1: no manual fixes are drawn on the render of the demo switch")
    func manualFixesMasked() {
        let model = MapViewModel(track: GPSTrack(), latest: nil, manualFixes: [ConfirmedFix(id: 1, latitude: 0.1, longitude: 0.1)])
        #expect(model.drawnManualFixes(excluding: [], whileDemo: false).count == 1)
        #expect(model.drawnManualFixes(excluding: [], whileDemo: true).isEmpty, "before resetForDemo has run")
        model.resetForDemo(demoOn: true)
        #expect(model.drawnManualFixes(excluding: [], whileDemo: true).isEmpty)
    }

    @Test("R74.1-6: the adapter screen says the link is held for the demo")
    func heldStatus() {
        let base = AdapterSettingsText.status(
            link: .idle, adapterName: nil, hasRemembered: true, foundAdapter: false, waitedLong: false)
        #expect(AdapterSettingsText.status(base, heldForDemo: false) == base)
        let held = AdapterSettingsText.status(base, heldForDemo: true)
        #expect(held.title == "Held for the demo drive" && held.detail == "Connects when you stop it.")
    }

    @Test("Settings: the voice row is in the driver group, off by default")
    func settingsRow() {
        #expect(SettingsRows.driver(adapterAvailable: false).contains(.speakGPSChanges))
        #expect(SettingsRows.speakGPSTitle == "Speak GPS changes")
        #expect(GPSVoiceSetting.key == "voice.gpsChanges")
        #expect(UserDefaults(suiteName: "gpsSwitchTests-fresh")?.bool(forKey: GPSVoiceSetting.key) == false)
    }
}

@MainActor
@Suite("GPS voice (UX-22)")
struct GPSVoiceTests {
    private func allow(_ l: inout GPSPhraseLimiter, _ p: GPSPhrase, now: TimeInterval) -> Bool { l.allow(p, now: now) }
    private func note(_ t: inout GPSPhraseTracker, _ s: HUDGPS, runActive: Bool) -> GPSPhrase? { t.note(s, runActive: runActive) }

    @MainActor
    final class FakeSpeaker: GPSSpeaking {
        var said: [String] = []
        func speak(_ text: String) { said.append(text) }
    }

    @Test("Limiter: first speaks, repeat within 5 min suppressed, after 5 min speaks, phrases independent")
    func limiter() {
        var limiter = GPSPhraseLimiter()
        #expect(allow(&limiter, .lost, now: 1000))
        #expect(!allow(&limiter, .lost, now: 1100))
        #expect(!allow(&limiter, .lost, now: 1299.9))
        #expect(allow(&limiter, .back, now: 1100), "another phrase is independent")
        #expect(allow(&limiter, .off, now: 1100))
        #expect(allow(&limiter, .lost, now: 1300))
        #expect(!allow(&limiter, .lost, now: 1599), "the window restarts at the last spoken phrase")
        #expect(allow(&limiter, .lost, now: 1600))
    }

    @Test("Tracker: lost, back after lost, off; the first fix and the driver's own Use GPS are silent")
    func tracker() {
        var t = GPSPhraseTracker()
        #expect(note(&t, .none, runActive: true) == nil, "run starts without a fix")
        #expect(note(&t, .ok, runActive: true) == nil, "first fix is not back")
        #expect(note(&t, .none, runActive: true) == .lost)
        #expect(note(&t, .none, runActive: true) == nil)
        #expect(note(&t, .ok, runActive: true) == .back)
        #expect(note(&t, .off, runActive: true) == .off)
        #expect(note(&t, .ok, runActive: true) == nil, "Use GPS is the driver's own tap")
        #expect(note(&t, .none, runActive: true) == .lost)
        #expect(note(&t, .off, runActive: true) == .off, "off from No GPS says off")
        #expect(note(&t, .none, runActive: true) == nil)
        #expect(note(&t, .ok, runActive: true) == .back, "the earlier loss is still unanswered")
    }

    @Test("Tracker: no run resets; Stop and the next first fix never speak")
    func trackerNoRun() {
        var t = GPSPhraseTracker()
        _ = note(&t, .ok, runActive: true)
        #expect(note(&t, .none, runActive: false) == nil)
        #expect(note(&t, .ok, runActive: false) == nil)
        #expect(note(&t, .none, runActive: true) == nil)
        #expect(note(&t, .ok, runActive: true) == nil)
    }

    @MainActor
    @Test("Announcer: off by default means silent; on speaks the phrase and applies the limit")
    func announcer() {
        let speaker = FakeSpeaker()
        var clock = 0.0
        let voice = GPSVoiceAnnouncer(speaker: speaker, now: { clock })
        voice.note(.ok, runActive: true, enabled: false)
        #expect(voice.note(.none, runActive: true, enabled: false) == nil)
        #expect(speaker.said.isEmpty, "switch off: nothing, demo included")
        #expect(voice.note(.ok, runActive: true, enabled: true) == .back, "the loss was real, the voice is on now")
        clock = 10
        #expect(voice.note(.none, runActive: true, enabled: true) == .lost)
        #expect(speaker.said == ["GPS back", "GPS lost"])
        clock = 20
        #expect(voice.note(.ok, runActive: true, enabled: true) == nil, "back again within 5 min")
        clock = 30
        #expect(voice.note(.none, runActive: true, enabled: true) == nil, "lost again within 5 min")
        #expect(speaker.said.count == 2)
        clock = 311
        #expect(voice.note(.ok, runActive: true, enabled: true) == .back)
        clock = 320
        #expect(voice.note(.none, runActive: true, enabled: true) == .lost)
        #expect(speaker.said.count == 4)
    }
}
