import Foundation
import Testing

@testable import DriveLoggerCore

/// Reference fixes for the gate, near (0, 0) only: no real place in tests.
/// Times are on one session clock; `now` is 10 s unless a test says
/// otherwise, and a fix is received at `now` with no age by default.
enum ManualFixFixtures {
    static let nowMs: Int64 = 10_000
    static var now: MonotonicTimestamp { ms(nowMs) }

    static func fix(
        speed: Double = 1,
        speedAccuracy: Double = 0.5,
        horizontalAccuracy: Double = 10,
        receivedMs: Int64? = nowMs,
        ageS: Double? = 0
    ) -> LocationSample {
        LocationSample(
            latitude: 0.001,
            longitude: -0.002,
            altitude: 5,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: 4,
            speed: speed,
            speedAccuracy: speedAccuracy,
            course: -1,
            courseAccuracy: -1,
            receivedT: receivedMs.map(ms),
            ageS: ageS
        )
    }

    static func ms(_ value: Int64) -> MonotonicTimestamp {
        MonotonicTimestamp(nanoseconds: value * 1_000_000)
    }

    /// The gate at `now`, with an OBD reply `obdAgeMs` old (fresh by default).
    static func gate(
        obd: Double? = nil,
        obdAgeMs: Int64 = 0,
        fix: LocationSample? = nil,
        nowMs: Int64 = nowMs
    ) -> ManualFixGate.Result {
        ManualFixGate.evaluate(
            now: ms(nowMs),
            obdSpeedKmh: obd,
            obdSpeedT: obd == nil ? nil : ms(nowMs - obdAgeMs),
            referenceFix: fix
        )
    }

    static let unknown = ManualFixGate.Result(speedSource: .unknown, speedKmh: nil, isAllowed: true)
}

@Suite("Manual fix gate")
struct ManualFixGateTests {
    typealias F = ManualFixFixtures

    @Test("A fresh OBD speed is the gate speed whatever GPS says")
    func obdWins() {
        #expect(F.gate(obd: 5, fix: F.fix(speed: 20)) == ManualFixGate.Result(speedSource: .obd, speedKmh: 5, isAllowed: true))
        #expect(F.gate(obd: 30, fix: F.fix(speed: 0)) == ManualFixGate.Result(speedSource: .obd, speedKmh: 30, isAllowed: false))
        #expect(F.gate(obd: 0) == ManualFixGate.Result(speedSource: .obd, speedKmh: 0, isAllowed: true))
    }

    @Test("OBD speed boundary: 10 km/h is allowed, 10.01 km/h is not")
    func obdSpeedBoundary() {
        #expect(F.gate(obd: 10).isAllowed)
        #expect(!F.gate(obd: 10.01).isAllowed)
        #expect(ManualFixGate.maxSpeedKmh == 10)
    }

    @Test("OBD age boundary: a reply exactly 2.0 s old counts, 2.01 s old does not")
    func obdAgeBoundary() {
        #expect(ManualFixGate.maxOBDAgeS == 2)
        #expect(F.gate(obd: 30, obdAgeMs: 2_000) == ManualFixGate.Result(speedSource: .obd, speedKmh: 30, isAllowed: false))
        #expect(F.gate(obd: 30, obdAgeMs: 2_010) == F.unknown)
        // Nanosecond precision at the boundary.
        let edge = ManualFixGate.evaluate(
            now: MonotonicTimestamp(nanoseconds: 5_000_000_001),
            obdSpeedKmh: 30,
            obdSpeedT: MonotonicTimestamp(nanoseconds: 3_000_000_000),
            referenceFix: nil
        )
        #expect(edge == F.unknown)
    }

    @Test("An OBD speed without its reply time does not count")
    func obdWithoutTime() {
        #expect(ManualFixGate.evaluate(now: F.now, obdSpeedKmh: 30, obdSpeedT: nil, referenceFix: nil) == F.unknown)
    }

    @Test("A stale OBD speed falls through to a fresh GPS speed")
    func staleOBDFallsThroughToGPS() {
        let gate = F.gate(obd: 50, obdAgeMs: 3_000, fix: F.fix(speed: 1))
        #expect(gate.speedSource == .gps)
        #expect(gate.speedKmh == 3.6)
        #expect(gate.isAllowed)
        // …and a stale 0 km/h does not let a fast fix through.
        let fast = F.gate(obd: 0, obdAgeMs: 2_500, fix: F.fix(speed: 20))
        #expect(fast == ManualFixGate.Result(speedSource: .gps, speedKmh: 72, isAllowed: false))
    }

    @Test("Both stale: unknown, allowed")
    func bothStale() {
        #expect(F.gate(obd: 50, obdAgeMs: 2_010, fix: F.fix(speed: 20, receivedMs: F.nowMs - 5_010)) == F.unknown)
    }

    @Test("Fix age boundary: a fix exactly 5.0 s old counts, 5.01 s old does not; fix time is receivedT − ageS")
    func fixAgeBoundary() {
        #expect(ManualFixGate.maxFixAgeS == 5)
        let gps = ManualFixGate.Result(speedSource: .gps, speedKmh: 72, isAllowed: false)
        // Received late…
        #expect(F.gate(fix: F.fix(speed: 20, receivedMs: F.nowMs - 5_000)) == gps)
        #expect(F.gate(fix: F.fix(speed: 20, receivedMs: F.nowMs - 5_010)) == F.unknown)
        // …or received now but old at receipt.
        #expect(F.gate(fix: F.fix(speed: 20, ageS: 5.0)) == gps)
        #expect(F.gate(fix: F.fix(speed: 20, ageS: 5.01)) == F.unknown)
        #expect(F.gate(fix: F.fix(speed: 20, receivedMs: F.nowMs - 3_000, ageS: 2.01)) == F.unknown)
        // No ageS (as a v1-shaped sample): the fix time is receivedT.
        #expect(F.gate(fix: F.fix(speed: 20, receivedMs: F.nowMs - 4_000, ageS: nil)) == gps)
    }

    @Test("A fix without receivedT does not count")
    func fixWithoutReceivedT() {
        #expect(F.gate(fix: F.fix(speed: 20, receivedMs: nil)) == F.unknown)
    }

    @Test("Negative ages (clock skew) count as fresh")
    func negativeAges() {
        #expect(F.gate(obd: 30, obdAgeMs: -500) == ManualFixGate.Result(speedSource: .obd, speedKmh: 30, isAllowed: false))
        #expect(F.gate(fix: F.fix(speed: 20, ageS: -0.3)).speedSource == .gps)
        #expect(F.gate(fix: F.fix(speed: 20, receivedMs: F.nowMs + 1_000)).speedSource == .gps)
    }

    @Test("Without OBD, a valid reference fix's speed is the gate speed, in km/h")
    func gpsFallback() {
        let slow = F.gate(fix: F.fix(speed: 2.5))
        #expect(slow.speedSource == .gps)
        #expect(slow.speedKmh == 2.5 * 3.6)
        #expect(slow.isAllowed)

        let fast = F.gate(fix: F.fix(speed: 2.78))  // 10.008 km/h
        #expect(fast.speedSource == .gps)
        #expect(!fast.isAllowed)

        let atLimit = F.gate(fix: F.fix(speed: 10 / 3.6))
        #expect(atLimit.speedSource == .gps)
        #expect(atLimit.isAllowed == ((10 / 3.6) * 3.6 <= 10))
    }

    @Test("GPS horizontal accuracy boundary: 100 m counts, 100.01 m makes the speed unknown")
    func accuracyBoundary() {
        #expect(F.gate(fix: F.fix(speed: 20, horizontalAccuracy: 100)) == ManualFixGate.Result(speedSource: .gps, speedKmh: 72, isAllowed: false))
        #expect(F.gate(fix: F.fix(speed: 20, horizontalAccuracy: 100.01)) == F.unknown)
        #expect(ManualFixGate.maxReferenceHorizontalAccuracyM == 100)
    }

    @Test("Invalid GPS speed, speed accuracy or position makes the speed unknown, and unknown is allowed")
    func invalidGPS() {
        #expect(F.gate(fix: F.fix(speed: 20, speedAccuracy: -1)) == F.unknown)
        #expect(F.gate(fix: F.fix(speed: -1)) == F.unknown)
        #expect(F.gate(fix: F.fix(speed: 20, horizontalAccuracy: -1)) == F.unknown)
        #expect(F.gate() == F.unknown)
        // speedAccuracy 0 and speed 0 are valid values, not "unavailable".
        let zero = F.gate(fix: F.fix(speed: 0, speedAccuracy: 0, horizontalAccuracy: 0))
        #expect(zero == ManualFixGate.Result(speedSource: .gps, speedKmh: 0, isAllowed: true))
    }

    @Test("A non-finite speed never passes the gate")
    func nonFinite() {
        #expect(!F.gate(obd: .nan).isAllowed)
        #expect(!F.gate(obd: .infinity).isAllowed)
    }
}

@Suite("Manual fix sample")
struct ManualFixSampleTests {
    typealias F = ManualFixFixtures

    static func sample(
        latitude: Double = 0,
        longitude: Double = 0,
        mapSpanM: Double? = nil,
        obd: Double? = nil,
        obdT: MonotonicTimestamp? = nil,
        fix: LocationSample? = nil,
        note: String? = nil
    ) -> ManualFixSample? {
        ManualFixGate.sample(
            now: F.now,
            latitude: latitude, longitude: longitude, pressedT: F.ms(8_000), mapSpanM: mapSpanM,
            obdSpeedKmh: obd, obdSpeedT: obdT, referenceFix: fix, note: note
        )
    }

    @Test("Builds the row from the gate's inputs: OBD speed and its time, GPS speed for reference, gate result")
    func buildsWithOBD() throws {
        let sample = try #require(ManualFixGate.sample(
            now: F.now,
            latitude: 0.0125, longitude: -0.025,
            pressedT: F.ms(8_200),
            mapSpanM: 250,
            obdSpeedKmh: 5, obdSpeedT: F.ms(9_000),
            referenceFix: F.fix(speed: 1.5),
            note: "  tunnel exit  "
        ))
        #expect(sample == ManualFixSample(
            latitude: 0.0125, longitude: -0.025,
            pressedT: F.ms(8_200),
            mapSpanM: 250,
            obdSpeedKmh: 5, obdSpeedT: F.ms(9_000),
            gpsSpeedKmh: 1.5 * 3.6,
            speedSource: "obd", gateSpeedKmh: 5,
            note: "tunnel exit"
        ))
    }

    @Test("GPS and unknown sources; GPS speed is kept for reference even when it is not the gate speed")
    func buildsWithoutOBD() throws {
        let gps = try #require(Self.sample(fix: F.fix(speed: 1)))
        #expect(gps.speedSource == "gps")
        #expect(gps.gateSpeedKmh == 3.6)
        #expect(gps.gpsSpeedKmh == 3.6)
        #expect(gps.obdSpeedKmh == nil && gps.obdSpeedT == nil)

        // Inaccurate position: not usable for the gate, still recorded.
        let unknown = try #require(Self.sample(fix: F.fix(speed: 20, horizontalAccuracy: 250)))
        #expect(unknown.speedSource == "unknown")
        #expect(unknown.gateSpeedKmh == nil)
        #expect(unknown.gpsSpeedKmh == 72)

        // No speed at all.
        let none = try #require(Self.sample(fix: F.fix(speed: -1)))
        #expect(none.speedSource == "unknown")
        #expect(none.gpsSpeedKmh == nil)
    }

    @Test("A stale OBD speed and a stale fix are still recorded, but the gate used neither")
    func staleInputsAreRecorded() throws {
        let sample = try #require(Self.sample(
            obd: 40, obdT: F.ms(F.nowMs - 2_500),
            fix: F.fix(speed: 20, receivedMs: F.nowMs - 6_000)
        ))
        #expect(sample.speedSource == "unknown")
        #expect(sample.gateSpeedKmh == nil)
        #expect(sample.obdSpeedKmh == 40)
        #expect(sample.obdSpeedT == F.ms(F.nowMs - 2_500))
        #expect(sample.gpsSpeedKmh == 72)

        // Stale OBD, fresh GPS: the row says gps, and keeps the OBD reading.
        let gps = try #require(Self.sample(obd: 40, obdT: F.ms(F.nowMs - 2_500), fix: F.fix(speed: 1)))
        #expect(gps.speedSource == "gps" && gps.gateSpeedKmh == 3.6 && gps.obdSpeedKmh == 40)
    }

    @Test("Refused when the gate refuses")
    func refusedAboveLimit() {
        #expect(Self.sample(obd: 10.01, obdT: F.ms(F.nowMs - 100)) == nil)
        #expect(Self.sample(fix: F.fix(speed: 3)) == nil)
    }

    @Test("Refused for a coordinate that is not a WGS 84 position")
    func refusesInvalidCoordinates() {
        for (lat, lon) in [(Double.nan, 0.0), (0, .infinity), (90.0001, 0), (-90.0001, 0), (0, 180.0001), (0, -180.0001)] {
            #expect(Self.sample(latitude: lat, longitude: lon, obd: 0, obdT: F.now) == nil, "\(lat), \(lon)")
        }
        #expect(Self.sample(latitude: -90, longitude: 180, obd: 0, obdT: F.now) != nil)
    }

    @Test("A non-finite or negative map span is dropped, not written (JSON has no NaN)")
    func sanitisesMapSpan() throws {
        for span in [Double.nan, .infinity, -1] {
            let sample = try #require(Self.sample(mapSpanM: span, obd: 0, obdT: F.now))
            #expect(sample.mapSpanM == nil)
        }
    }

    @Test("obdSpeedT is written only with an OBD speed")
    func obdTimeNeedsSpeed() throws {
        let sample = try #require(Self.sample(obdT: F.ms(5)))
        #expect(sample.obdSpeedT == nil)
    }

    @Test("Note: trimmed, empty becomes absent, at most 80 characters")
    func notes() {
        #expect(ManualFixSample.normalizedNote(nil) == nil)
        #expect(ManualFixSample.normalizedNote("   \n ") == nil)
        #expect(ManualFixSample.normalizedNote("\tgate\n") == "gate")
        let long = String(repeating: "a", count: 79) + "é" + "bcd"
        #expect(ManualFixSample.normalizedNote(long) == String(repeating: "a", count: 79) + "é")
        #expect(ManualFixSample.normalizedNote(long)?.count == ManualFixSample.maxNoteLength)
        // Whitespace left at the cut is trimmed too.
        #expect(ManualFixSample.normalizedNote(String(repeating: "b", count: 79) + " tail") == String(repeating: "b", count: 79))
        #expect(ManualFixSample.maxNoteLength == 80)
    }

    @Test("Round-trips through the codec with only the fields that are present")
    func roundTrip() throws {
        let codec = LogCodec()
        let minimal = LogEvent(
            timestamp: F.ms(9_000),
            payload: .manualFix(ManualFixSample(latitude: 0, longitude: 0, pressedT: F.ms(8_000), speedSource: "unknown"))
        )
        let line = String(decoding: try codec.line(for: minimal), as: UTF8.self)
        #expect(line == #"{"data":{"latitude":0,"longitude":0,"pressedT":8000000000,"speedSource":"unknown"},"kind":"manualFix","t":9000000000}"# + "\n")
        #expect(try codec.event(from: Data(line.utf8)) == minimal)
    }
}
