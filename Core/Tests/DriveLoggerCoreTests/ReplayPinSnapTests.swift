import Foundation
import Testing

@testable import DriveLoggerCore

/// Prompt 46 Part B, replay side: pin truth is the raw tap (format v6), and
/// `replay_nav --snap-pins` (`ReplayOptions.snapPins`). Synthetic drive
/// near (0, 0): straight east along a road on north = 0.
@Suite("Replay pin snap")
struct ReplayPinSnapTests {
    typealias S = SyntheticDrive

    /// 10 m/s due east from (0, 0) for 60 s, then a stop; clean GNSS for
    /// the first 15 s only.
    static let drive = S(initialHeadingDeg: 90, initialSpeed: 10, [
        .straight(seconds: 60, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 5),
    ])

    static func road() throws -> ReplayRoadSet {
        ReplayRoadSet(try RoadNetwork(packs: [RoadFixture.build([
            RoadFixture.way(1, ["highway": "primary"], [
                RoadFixture.Node(id: 1, east: -200, north: 0), RoadFixture.Node(id: 2, east: 1200, north: 0),
            ]),
        ])]))
    }

    static func geodetic(_ east: Double, _ north: Double) -> (latitude: Double, longitude: Double) {
        S.plane.geodetic(east: east, north: north)
    }

    /// A pin at `t`: the row's point `logged` metres off the truth, and a
    /// raw tap `tap` metres off it (nil: no tap fields, a pre-v6 row).
    static func pin(at t: Double, logged: (Double, Double), tap: (Double, Double)?, span: Double = 852) -> LogEvent {
        let truth = drive.truth(at: t)
        let p = geodetic(truth.east + logged.0, truth.north + logged.1)
        let q = tap.map { geodetic(truth.east + $0.0, truth.north + $0.1) }
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t), mapSpanM: span, speedSource: "obd",
            tapLatitude: q?.latitude, tapLongitude: q?.longitude)))
    }

    static func run(_ pins: [LogEvent], roads: ReplayRoadSet?, snap: Bool) -> ReplayResult {
        let events = drive.events(fix: { t, state, rng in t <= 15 ? S.cleanFix()(t, state, &rng) : nil }, extra: pins)
        var options = ReplayOptions(gps: .use, config: S.config(particles: 200))
        options.roads = roads
        if snap { options.snapPins = ReplayPinSnap() }
        return NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events),
                                    options: options)
    }

    static func pinCheckpoint(_ r: ReplayResult) -> ReplayResult.Checkpoint? {
        r.checkpoints.first { $0.kind == .manualFix }
    }

    /// Everything the engine produced (not the scoring, not the label).
    static func engineOutput(_ r: ReplayResult) -> [String] {
        ["\(r.track)", "\(r.ellipses)", "\(r.counters)", "\(r.fixes)",
         "\(r.pins.map(\.pin.prior))", "\(r.checkpoints.map { [$0.estimateLatitude, $0.estimateLongitude] })"]
    }

    @Test("A v6 snapped pin is scored against the raw tap, while the engine gets the snapped point")
    func snappedPinScoredAgainstTap() throws {
        // The row: snapped point 150 m east of the truth, tap on the truth.
        let snapped = Self.run([Self.pin(at: 40, logged: (150, 0), tap: (0, 0))], roads: nil, snap: false)
        // The same tap as a plain row (no snap).
        let plain = Self.run([Self.pin(at: 40, logged: (0, 0), tap: nil)], roads: nil, snap: false)
        let a = try #require(Self.pinCheckpoint(snapped)), b = try #require(Self.pinCheckpoint(plain))
        let truth = Self.drive.truth(at: 40)
        let t = Self.geodetic(truth.east, truth.north)
        #expect(a.latitude == t.latitude && a.longitude == t.longitude)
        #expect(a.latitude == b.latitude && a.longitude == b.longitude)
        #expect(a.errorM == b.errorM, "the prior is the same; the truth is the tap in both")
        #expect(snapped.pins[0].pin.latitude == t.latitude && snapped.pins[0].pin.longitude == t.longitude)
        // The engine got the snapped point: after the pin the runs differ.
        #expect(snapped.track.last != plain.track.last)
        // A scored point after the pin (truth `end` is absent: the end is the
        // last scored checkpoint): the end estimate is pulled east.
        let endA = try #require(snapped.track.last), endB = try #require(plain.track.last)
        let pa = S.plane.enu(latitude: endA.latitude, longitude: endA.longitude)
        let pb = S.plane.enu(latitude: endB.latitude, longitude: endB.longitude)
        #expect(pa.east > pb.east)
    }

    @Test("--snap-pins is off by default: no label part, no pinSnaps, no metrics key")
    func offByDefault() throws {
        #expect(ReplayOptions(gps: .use).snapPins == nil)
        let r = Self.run([Self.pin(at: 40, logged: (0, 20), tap: nil)], roads: try Self.road(), snap: false)
        #expect(!r.mode.contains("snap"))
        #expect(r.pinSnaps == nil)
        let json = try JSONEncoder().encode(ReplayMetrics(r))
        #expect(!String(decoding: json, as: UTF8.self).contains("pinSnaps"))
        let decoded = try JSONDecoder().decode(ReplayMetrics.self, from: json)
        #expect(decoded.pinSnaps == nil)
    }

    @Test("--snap-pins with roads: the engine gets the snapped point, scoring keeps the raw tap")
    func snapsWithRoads() throws {
        let roads = try Self.road()
        let pins = [Self.pin(at: 40, logged: (0, 20), tap: nil)]
        let off = Self.run(pins, roads: roads, snap: false)
        let on = Self.run(pins, roads: roads, snap: true)
        #expect(on.mode == off.mode + "-snap-pins")
        let snaps = try #require(on.pinSnaps)
        #expect(snaps.count == 1)
        let s = snaps[0]
        #expect(s.result == "edge" && s.placement == "snapped" && s.decision == "onlyRoad")
        #expect(abs((s.snapDistanceM ?? 0) - 20) < 0.1)
        #expect(abs((s.snapNorthM ?? 0) + 20) < 0.1 && abs(s.snapEastM ?? 1) < 0.1, "the road is 20 m south of the tap")
        #expect(abs(s.radiusM - 44) < 1e-9, "852 m span in 852 pt: 1 m per point")
        #expect(s.differsFromNearest == false && s.contested == 0 && s.contestedSpreadM == nil)
        #expect(abs(s.t - 40) < 1e-9 && s.mapSpanM == 852)
        // Truth: the raw tap in both runs.
        let a = try #require(Self.pinCheckpoint(on)), b = try #require(Self.pinCheckpoint(off))
        #expect(a.latitude == b.latitude && a.longitude == b.longitude)
        #expect(on.pins[0].pin.latitude == off.pins[0].pin.latitude)
        // The engine: identical up to the pin, different after it.
        #expect(on.track.filter { $0.t < 40 } == off.track.filter { $0.t < 40 })
        #expect(on.track.last != off.track.last)
        // Same engine input as a row that already has the snapped point
        // (the app's row: snapped point and tap).
        let truth = Self.drive.truth(at: 40)
        let tap = Self.geodetic(truth.east, truth.north + 20)
        let point = try #require(PinSnap.snap(latitude: tap.latitude, longitude: tap.longitude, mapSpanM: 852,
                                              viewportHeightPt: 852, network: roads.network, cloud: nil).result.snap)
        let row = LogEvent(timestamp: S.ms(40), payload: .manualFix(ManualFixSample(
            latitude: point.latitude, longitude: point.longitude, pressedT: S.ms(40), mapSpanM: 852, speedSource: "obd",
            tapLatitude: tap.latitude, tapLongitude: tap.longitude)))
        let preSnapped = Self.run([row], roads: roads, snap: false)
        #expect(Self.engineOutput(on) == Self.engineOutput(preSnapped))
        // A v6 row is re-snapped from its tap, not from its logged point.
        let resnapped = Self.run([Self.pin(at: 40, logged: (300, -300), tap: (0, 20))], roads: roads, snap: true)
        #expect(Self.engineOutput(resnapped) == Self.engineOutput(on))
        // The metrics row carries the records and decodes them.
        let decoded = try JSONDecoder().decode(ReplayMetrics.self, from: JSONEncoder().encode(ReplayMetrics(on)))
        #expect(decoded.pinSnaps == snaps)
        #expect(ReplayReport.summary(on).contains("Pin snap      1 pins: edge 1, node 0, ambiguous 0"))
    }

    @Test("--snap-pins without roads: every pin noNetwork, the engine output unchanged")
    func noRoadsUnchanged() throws {
        let pins = [Self.pin(at: 40, logged: (0, 20), tap: nil, span: 200),
                    Self.pin(at: 50, logged: (5, 5), tap: nil, span: 300)]
        let off = Self.run(pins, roads: nil, snap: false)
        let on = Self.run(pins, roads: nil, snap: true)
        #expect(Self.engineOutput(on) == Self.engineOutput(off))
        #expect(on.checkpoints.map(\.errorM) == off.checkpoints.map(\.errorM))
        #expect(on.pinSnaps?.map(\.result) == ["noNetwork", "noNetwork"])
        #expect(on.pinSnaps?.map(\.placement) == ["raw", "raw"])
        // --snap-span: as if tapped at 1000 m (radius 51.6 m): a tap 40 m
        // off the road snaps, the record carries the override span.
        var options = ReplayOptions(gps: .use, config: S.config(particles: 200))
        options.roads = try Self.road()
        options.snapPins = ReplayPinSnap(spanOverrideM: 1000)
        let events = Self.drive.events(fix: { t, state, rng in t <= 15 ? S.cleanFix()(t, state, &rng) : nil },
                                       extra: [Self.pin(at: 40, logged: (0, 40), tap: nil, span: 200)])
        let stressed = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events),
                                            options: options)
        #expect(stressed.pinSnaps?.map(\.result) == ["edge"])
        #expect(stressed.pinSnaps?.first?.mapSpanM == 1000)
        #expect(Self.run([Self.pin(at: 40, logged: (0, 40), tap: nil, span: 200)], roads: try Self.road(), snap: true)
            .pinSnaps?.map(\.result) == ["noEdgeInRadius"])
        // A span the app would refuse: the engine still gets the raw tap.
        let wide = Self.run([Self.pin(at: 40, logged: (0, 20), tap: nil, span: 2000)], roads: try Self.road(), snap: true)
        #expect(wide.pinSnaps?.map(\.placement) == ["zoomIn"])
        #expect(Self.engineOutput(wide) == Self.engineOutput(
            Self.run([Self.pin(at: 40, logged: (0, 20), tap: nil, span: 2000)], roads: try Self.road(), snap: false)))
    }

    @Test("Label: -snap-pins before -obd-none; a non-default viewport is named")
    func label() {
        var o = ReplayOptions(gps: .use)
        o.snapPins = ReplayPinSnap()
        o.obd = .none
        #expect(o.label == "use-snap-pins-obd-none")
        o.snapPins = ReplayPinSnap(viewportHeightPt: 700)
        #expect(o.label == "use-snap-pins-vp-700-obd-none")
        o.snapPins = ReplayPinSnap(spanOverrideM: 1000)
        #expect(o.label == "use-snap-pins-span-1000-obd-none")
    }
}
