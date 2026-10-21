import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// R76.2-1: a run's start (Record start, Record stop, Navigate) never speaks "GPS lost" / "GPS back",
/// whatever GPS state the previous run left in the feed.
@MainActor
@Suite("GPS voice across run changes")
struct GPSRunHandoverTests {
    final class Speaker: GPSSpeaking {
        var said: [String] = []
        func speak(_ text: String) { said.append(text) }
    }

    /// The map's wiring in one place: the feed, the HUD function, the voice run, the announcer.
    @MainActor
    struct Map {
        let feed: NavigationFeed
        let speaker = Speaker()
        let voice: GPSVoiceAnnouncer
        var clock = 0.0
        /// The session's live run generation, as the view receives it.
        var current: Int?
        /// The map's own freshness (a fix in the last seconds).
        var stale = false

        init() {
            feed = NavigationFeed(display: nil)
            let speaker = speaker
            voice = GPSVoiceAnnouncer(speaker: speaker, now: { 0 })
        }

        func poll(_ run: Int?, inUse: Bool) {
            let snap = NavigationSnapshot(
                t: .zero, sessionID: run == nil ? nil : UUID(), estimate: nil, stats: .init(),
                gnssInUse: inUse, gpsSwitchedOff: false)
            _ = feed.apply(snap, run: run, at: .now)
        }

        /// What the view does at one render: HUD state, voice run, then the announcer.
        @discardableResult
        func render() -> HUDGPS {
            let hud = MapHUDState.gpsState(stale: stale, engine: feed.gps, currentRun: current)
            let run = MapHUDState.voiceRun(current: current, engine: feed.gps, estimateShown: true)
            voice.note(hud, run: run, enabled: true)
            return hud
        }

        /// The view's `.onChange(of: run)`.
        func runChanged() { feed.clearGPS() }
    }

    @Test("Record stop: R straight to N2 while the feed still holds R's inUse; no lost, no back")
    func recordStop() {
        var m = Map()
        m.current = 1
        m.poll(1, inUse: true)
        #expect(m.render() == .ok)
        // finishRecording: R -> N2 in one turn; the feed still holds R's state.
        m.current = 2
        m.stale = true  // the new run has no fix yet
        #expect(m.render() == .none, "R's state must not show as N2's, not even for one frame")
        m.runChanged()
        m.render()
        // N2's engine: nothing yet (idle snapshot), then a fresh engine without a fix, then its first fix.
        m.poll(nil, inUse: false)
        m.render()
        m.poll(2, inUse: false)
        m.render()
        m.poll(2, inUse: true)
        #expect(m.render() == .ok)
        #expect(m.speaker.said.isEmpty)
    }

    @Test("Record stop without the clear: a stale R state tagged R never reaches N2's baseline")
    func recordStopWithoutClear() {
        var m = Map()
        m.current = 1
        m.poll(1, inUse: true)
        m.render()
        m.current = 2
        m.render()
        m.poll(2, inUse: false)
        m.render()
        m.poll(2, inUse: true)
        m.render()
        #expect(m.speaker.said.isEmpty)
    }

    @Test("Record start: Settings covered the map, polling froze Navigate's inUse; Start swaps the run")
    func recordStart() {
        var m = Map()
        m.current = 1
        m.poll(1, inUse: true)
        m.render()
        m.current = 3
        m.stale = true
        m.render()
        m.poll(3, inUse: false)
        m.render()
        m.poll(3, inUse: true)
        m.render()
        #expect(m.speaker.said.isEmpty)
    }

    @Test("A real loss and recovery inside the new run is still announced")
    func lossWithinRun() {
        var m = Map()
        m.current = 1
        m.poll(1, inUse: true)
        m.render()
        m.current = 2
        m.render()
        m.poll(2, inUse: true)
        m.render()
        m.poll(2, inUse: false)
        m.render()
        m.poll(2, inUse: true)
        m.render()
        #expect(m.speaker.said == ["GPS lost", "GPS back"])
    }

    @Test("HUD ignores an engine state from another run; untagged (demo) and live-run states count")
    func hudIgnoresOtherRun() {
        let old = EngineGPS(inUse: true, switchedOff: false, run: 1)
        #expect(MapHUDState.gpsState(stale: true, engine: old, currentRun: 2) == .none)
        #expect(MapHUDState.gpsState(stale: true, engine: old, currentRun: nil) == .none)
        #expect(MapHUDState.gpsState(stale: true, engine: old, currentRun: 1) == .ok)
        let untagged = EngineGPS(inUse: true, switchedOff: false)
        #expect(MapHUDState.gpsState(stale: true, engine: untagged, currentRun: nil) == .ok)
        #expect(MapHUDState.voiceRun(current: 2, engine: old, estimateShown: true) == nil)
        #expect(MapHUDState.voiceRun(current: 2, engine: nil, estimateShown: true) == nil)
        #expect(MapHUDState.voiceRun(current: 2, engine: nil, estimateShown: false) == 2)
        #expect(MapHUDState.voiceRun(current: nil, engine: old, estimateShown: true) == nil)
    }

    @Test("The feed tags GPS with the service's generation and drops a poll that straddles a run change")
    func feedTagging() async {
        actor Gen {
            var values: [Int?]
            init(_ v: [Int?]) { values = v }
            func next() -> Int? { values.removeFirst() }
        }
        let snapshot = NavigationSnapshot(
            t: .zero, sessionID: UUID(), estimate: nil, stats: .init(), gnssInUse: true, gpsSwitchedOff: false)
        let steady = Gen([4, 4])
        let feed = NavigationFeed(source: { snapshot }, generation: { await steady.next() })
        await feed.poll()
        #expect(feed.gps == EngineGPS(inUse: true, switchedOff: false, run: 4))
        let straddle = Gen([4, 5])
        let other = NavigationFeed(source: { snapshot }, generation: { await straddle.next() })
        await other.poll()
        #expect(other.gps == nil, "a snapshot across a run change is not tagged with either run")
    }
}
