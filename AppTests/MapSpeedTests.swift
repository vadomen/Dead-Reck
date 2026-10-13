import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// A fix with the given speed (m/s), accuracies (metres; speed accuracy in m/s).
private func fix(
    speed: Double = 15, speedAccuracy: Double = 0.5, accuracy: Double = 10
) -> LocationSample {
    LocationSample(
        latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
        speed: speed, speedAccuracy: speedAccuracy, course: 0, courseAccuracy: 5,
        receivedT: MonotonicTimestamp(seconds: 0), ageS: 0
    )
}

@Suite("Map speed rule")
struct MapSpeedRuleTests {
    @Test("Fresh OBD wins over a fresh GPS fix; shown as received, no +0.5")
    func freshOBD() {
        let r = MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 0.1, fix: fix(speed: 20), fixAgeS: 0.1)
        #expect(r.source == .obd)
        #expect(r.kmh == 54)
        #expect(r.summary == "54 km/h · OBD")
        #expect(MapSpeedRule.resolve(obdKmh: 0, obdAgeS: 0, fix: nil, fixAgeS: nil).kmh == 0)
    }

    @Test("OBD exactly 2 s old counts; a hair older does not")
    func obdBoundary() {
        #expect(MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 2.0, fix: nil, fixAgeS: nil).source == .obd)
        #expect(MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 2.000001, fix: nil, fixAgeS: nil).source == .none)
        // Clock skew: a reply stamped after now is the most recent there is.
        #expect(MapSpeedRule.resolve(obdKmh: 54, obdAgeS: -0.01, fix: nil, fixAgeS: nil).source == .obd)
    }

    @Test("Stale OBD falls back to a fresh GPS fix; and OBD with no age or value does not count")
    func staleOBD() {
        let r = MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 2.5, fix: fix(speed: 15), fixAgeS: 1)
        #expect(r.source == .gps)
        #expect(r.kmh == 54)
        #expect(r.summary == "54 km/h · GPS")
        #expect(MapSpeedRule.resolve(obdKmh: 54, obdAgeS: nil, fix: fix(), fixAgeS: 0).source == .gps)
        #expect(MapSpeedRule.resolve(obdKmh: nil, obdAgeS: 0, fix: fix(), fixAgeS: 0).source == .gps)
        #expect(MapSpeedRule.resolve(obdKmh: .nan, obdAgeS: 0, fix: nil, fixAgeS: nil).source == .none)
    }

    @Test("GPS: same 2 s freshness, boundary included; stale fix gives none")
    func gpsFreshness() {
        #expect(MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(), fixAgeS: 2.0).source == .gps)
        let stale = MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(), fixAgeS: 2.001)
        #expect(stale == .none)
        #expect(MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(), fixAgeS: nil) == .none)
    }

    @Test("Invalid GPS speed (-1) is not a speed; speed 0 is")
    func invalidGPSSpeed() {
        #expect(MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(speed: -1), fixAgeS: 0) == .none)
        let still = MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(speed: 0), fixAgeS: 0)
        #expect(still.source == .gps)
        #expect(still.kmh == 0)
    }

    @Test("No inputs: none, shown as an em dash with no chip")
    func nothing() {
        let r = MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: nil, fixAgeS: nil)
        #expect(r == .none)
        #expect(r.valueText == "—")
        #expect(r.sourceText == nil)
        #expect(r.summary == "— km/h")
    }

    @Test("GPS m/s to km/h rounds to the nearest whole km/h")
    func gpsRounding() {
        func kmh(_ ms: Double) -> Int? {
            MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(speed: ms), fixAgeS: 0).kmh
        }
        #expect(kmh(15) == 54)         // 54.0
        #expect(kmh(15.013) == 54)     // 54.05
        #expect(kmh(15.0 + 0.5 / 3.6 + 0.001) == 55)  // just over 54.5
        #expect(kmh(15.0 + 0.5 / 3.6 - 0.001) == 54)  // just under 54.5
        #expect(kmh(0.1) == 0)         // 0.36
        #expect(kmh(0.14) == 1)        // 0.504
    }

    @Test("OBD is not rounded again: the integer as received")
    func obdAsReceived() {
        #expect(MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 0, fix: nil, fixAgeS: nil).valueText == "54")
        #expect(MapSpeedRule.resolve(obdKmh: 255, obdAgeS: 0, fix: nil, fixAgeS: nil).valueText == "255")
    }

    @Test("Chip colour: green up to 15 m, amber up to 100 m, grey beyond")
    func qualityBands() {
        func q(_ accuracy: Double) -> MapSpeedQuality {
            MapSpeedRule.resolve(obdKmh: nil, obdAgeS: nil, fix: fix(accuracy: accuracy), fixAgeS: 0).quality
        }
        #expect(q(0) == .good)
        #expect(q(15) == .good)
        #expect(q(15.01) == .fair)
        #expect(q(100) == .fair)
        #expect(q(100.01) == .unknown)
        #expect(q(-1) == .unknown)
    }

    @Test("Network fixes are grey whatever accuracy they report")
    func networkFix() {
        // No valid speed or speed accuracy: cell tower / Wi-Fi.
        #expect(MapSpeedRule.quality(of: fix(speed: -1, speedAccuracy: -1, accuracy: 10)) == .unknown)
        #expect(MapSpeedRule.quality(of: fix(speed: 15, speedAccuracy: -1, accuracy: 10)) == .unknown)
        #expect(MapSpeedRule.quality(of: nil) == .unknown)
    }

    @Test("The chip keeps showing GPS quality when OBD is the source; a stale fix is grey")
    func qualityWithOBD() {
        let good = MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 0, fix: fix(accuracy: 8), fixAgeS: 0.5)
        #expect(good.source == .obd)
        #expect(good.quality == .good)
        let jammed = MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 0, fix: fix(accuracy: 400), fixAgeS: 0.5)
        #expect(jammed.quality == .unknown)
        let stale = MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 0, fix: fix(accuracy: 8), fixAgeS: 3)
        #expect(stale.quality == .unknown)
        let none = MapSpeedRule.resolve(obdKmh: 54, obdAgeS: 0, fix: nil, fixAgeS: nil)
        #expect(none.quality == .unknown)
    }
}

@Suite("Map speed from the recorder's data")
@MainActor
struct MapSpeedFeedTests {
    private func reading(_ value: Double, ecu: String?) -> LinkEvent {
        let now = ProcessInfo.processInfo.systemUptime
        return .session(.reading(OBDReading(
            seq: 1, command: "010D0C1", ecu: ecu,
            measurement: OBDMeasurement(pid: .vehicleSpeed, value: value, unit: .kilometersPerHour),
            raw: "7E804410D32", requestUptime: now - 0.04, replyUptime: now
        )))
    }

    /// What `MapFeed` does: read the session's speed, its reply uptime and
    /// the uptime now, and hand them to the model.
    private func feed(_ session: RecordingSession, into model: MapViewModel) {
        model.setOBDSpeed(
            session.live.obdSpeedKmh, replyUptime: session.obdSpeedReplyUptime,
            now: session.currentUptimeSeconds
        )
    }

    @Test("OBD speed from a 7E8 reply and from a no-ECU (headers off) reply; 7E9 is ignored")
    func ecuSources() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        let model = MapViewModel()

        link.send(reading(50, ecu: "7E8"))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 50 })
        feed(session, into: model)
        #expect(model.speed.source == .obd)
        #expect(model.speed.kmh == 50)

        // Not the engine ECU: ignored. Link events are handled in order, so
        // once the later pollRate has landed the 7E9 reading has been handled.
        link.send(reading(80, ecu: "7E9"))
        link.send(.session(.pollRate(hz: 21.5, uptime: ProcessInfo.processInfo.systemUptime)))
        #expect(await eventually(2) { session.live.obdHz == 21.5 })
        #expect(session.live.obdSpeedKmh == 50)
        feed(session, into: model)
        #expect(model.speed.kmh == 50)

        link.send(reading(60, ecu: nil))     // headers off: counts
        #expect(await eventually(2) { session.live.obdSpeedKmh == 60 })
        feed(session, into: model)
        #expect(model.speed.summary == "60 km/h · OBD")
    }

    @Test("A fix alone gives GPS; a fresh OBD reading replaces it; an old OBD reading does not")
    func modelSwitchesSource() {
        let model = MapViewModel()
        model.ingest(fix(speed: 15, accuracy: 8), file: nil, isActive: true)
        model.setOBDSpeed(nil, replyUptime: nil, now: 100)
        #expect(model.speed == MapSpeedReadout(source: .gps, kmh: 54, quality: .good))

        model.setOBDSpeed(70, replyUptime: 100, now: 100.5)
        #expect(model.speed == MapSpeedReadout(source: .obd, kmh: 70, quality: .good))

        // OBD drops (no new reply): after 2 s the chip is GPS again.
        model.setOBDSpeed(70, replyUptime: 100, now: 102.5)
        #expect(model.speed.source == .gps)
        #expect(model.speed.kmh == 54)
    }

    @Test("No fix and no OBD: none")
    func modelNone() {
        let model = MapViewModel()
        model.setOBDSpeed(nil, replyUptime: nil, now: 0)
        #expect(model.speed == .none)
    }
}
