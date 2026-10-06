import Foundation
import Testing

@testable import DriveLoggerCore

/// Guards the "old log versions stay readable" invariant.
///
/// The fixture below is a frozen copy of a file written by the first release.
/// It must never be edited to accommodate a format change — if a change breaks
/// it, the change is wrong, or it needs a new `LogFormatVersion` case plus a
/// migration path that leaves this test passing.
@Suite("Log format compatibility")
struct LogFormatCompatibilityTests {
    let codec = LogCodec()

    /// Format v1, as written by DriveLogger 0.1.0 (build 1).
    static let version1Recording = """
        {"app":{"build":"1","name":"DriveLogger","version":"0.1.0"},"device":{"model":"iPhone15,2","systemName":"iOS","systemVersion":"17.4"},"formatVersion":1,"referenceUptimeSeconds":1234.5,"sessionID":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","startedAt":"2023-11-14T22:13:20Z"}
        {"data":{"attitude":{"w":1,"x":0,"y":0,"z":0},"gravity":{"x":0,"y":0,"z":-1},"rotationRate":{"x":0.01,"y":-0.02,"z":0.03},"userAcceleration":{"x":0.1,"y":0.2,"z":0.3}},"kind":"motion","t":1000000}
        {"data":{"altitude":12.5,"course":87.5,"courseAccuracy":5,"horizontalAccuracy":5,"latitude":59.4372,"longitude":24.7536,"speed":13.2,"speedAccuracy":1.1,"verticalAccuracy":3},"kind":"location","t":2000000}
        {"data":{"pid":13,"raw":"410D32","unit":"km/h","value":50},"kind":"obd","t":3000000}
        {"data":"entered tunnel","kind":"marker","t":4000000}
        """

    @Test("A v1 recording still parses")
    func readsVersion1() throws {
        let document = try codec.document(from: Data(Self.version1Recording.utf8))

        #expect(document.header.formatVersion == .v1)
        #expect(document.header.sessionID == LogFixtures.sessionID)
        #expect(document.header.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(document.header.referenceUptimeSeconds == 1_234.5)
        #expect(document.header.app == LogFixtures.app)
        #expect(document.header.device == LogFixtures.device)
        // v1 wrote no `notes` key at all; absent must mean nil, not empty.
        #expect(document.header.notes == nil)
        #expect(document.events.count == 4)
    }

    @Test("v1 sample values decode to the same numbers they were written with")
    func readsVersion1Samples() throws {
        let document = try codec.document(from: Data(Self.version1Recording.utf8))

        guard case .motion(let motion) = document.events[0].payload else {
            Issue.record("expected a motion payload first")
            return
        }
        #expect(document.events[0].timestamp.nanoseconds == 1_000_000)
        #expect(motion.userAcceleration == Vector3(x: 0.1, y: 0.2, z: 0.3))
        #expect(motion.rotationRate == Vector3(x: 0.01, y: -0.02, z: 0.03))
        #expect(motion.attitude == .identity)
        // v1 had no magnetometer field; readers must not invent a zero vector.
        #expect(motion.magneticField == nil)

        guard case .location(let location) = document.events[1].payload else {
            Issue.record("expected a location payload second")
            return
        }
        #expect(location.latitude == 59.4372)
        #expect(location.longitude == 24.7536)
        #expect(location.speed == 13.2)

        guard case .obd(let obd) = document.events[2].payload else {
            Issue.record("expected an OBD payload third")
            return
        }
        #expect(obd.pid == .vehicleSpeed)
        #expect(obd.value == 50)
        #expect(obd.unit == .kilometersPerHour)
        #expect(obd.raw == "410D32")

        guard case .marker(let note) = document.events[3].payload else {
            Issue.record("expected a marker payload fourth")
            return
        }
        #expect(note == "entered tunnel")
    }

    @Test("Rewriting a v1 recording reproduces it unchanged")
    func rewritesVersion1Identically() throws {
        // The fixture is written in the codec's own canonical spelling (sorted
        // keys, ISO 8601), so a read/write cycle on an untouched v1 file must be
        // byte-identical. Catches an accidental key rename or date-strategy
        // change that the value assertions above would miss.
        let original = Data(Self.version1Recording.utf8)
        let document = try codec.document(from: original)
        let rewritten = try codec.encode(document)

        #expect(rewritten == original + Data("\n".utf8))
    }

    @Test("An unknown event kind is preserved rather than dropped")
    func preservesUnknownEventKinds() throws {
        // Simulates reading a file written by a later build that added a
        // barometer stream. An older reader must keep the record intact so a
        // re-export doesn't quietly destroy research data.
        let withFutureEvent = Self.version1Recording + """
            \n{"data":{"pressureKPa":101.3,"relativeAltitude":2.5},"kind":"barometer","t":5000000}
            """
        let document = try codec.document(from: Data(withFutureEvent.utf8))

        #expect(document.events.count == 5)
        guard case .unrecognized(let kind, let data) = document.events[4].payload else {
            Issue.record("expected the barometer record to survive as unrecognized")
            return
        }
        #expect(kind == "barometer")
        #expect(data == .object([
            "pressureKPa": .double(101.3),
            "relativeAltitude": .double(2.5),
        ]))
    }

    @Test("An unknown event round-trips without losing fields")
    func roundTripsUnknownEventKinds() throws {
        let line = Data(
            """
            {"data":{"nested":{"flag":true,"list":[1,2.5,null,"x"]},"ns":1234567890123},"kind":"future","t":9000000}
            """.utf8
        )
        let decoded = try codec.event(from: line)
        let reencoded = try codec.line(for: decoded)

        #expect(try codec.event(from: reencoded) == decoded)
        // Large integers must not degrade through Double on the way out.
        guard case .unrecognized(_, .some(.object(let fields))) = decoded.payload else {
            Issue.record("expected an object payload")
            return
        }
        #expect(fields["ns"] == .int(1_234_567_890_123))
    }

    @Test("A newer format version is refused rather than guessed at")
    func refusesFutureFormatVersion() {
        // Reading v99 with v1 rules would produce plausible but wrong data,
        // which is worse than failing loudly.
        let future = """
            {"app":{"build":"9","name":"DriveLogger","version":"9.0"},"device":{"model":"iPhone99,1","systemName":"iOS","systemVersion":"30.0"},"formatVersion":99,"referenceUptimeSeconds":1,"sessionID":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","startedAt":"2030-01-01T00:00:00Z"}
            """
        #expect(throws: LogDecodingError.unsupportedFormatVersion(99)) {
            try codec.document(from: Data(future.utf8))
        }
    }

    @Test("New recordings are written in the current version")
    func writesCurrentVersion() throws {
        let header = LogHeader(
            sessionID: LogFixtures.sessionID,
            clock: SessionClock(source: FixedUptimeSource(uptimeSeconds: 1)),
            app: LogFixtures.app,
            device: LogFixtures.device
        )
        #expect(header.formatVersion == .current)

        let line = String(decoding: try codec.line(for: header), as: UTF8.self)
        #expect(line.contains("\"formatVersion\":2"))
    }

    @Test("Every declared format version is readable")
    func allVersionsAreReadable() {
        // A version added to the enum without a reader is the failure mode this
        // invariant exists to prevent; keep a fixture per case above.
        #expect(LogFormatVersion.allCases == [.v1, .v2])
        #expect(LogFormatVersion.current == LogFormatVersion.allCases.max())
    }

    @Test("Event kind discriminators are part of the format and must not drift")
    func kindStringsAreStable() {
        #expect(LogEventKind.motion.rawValue == "motion")
        #expect(LogEventKind.location.rawValue == "location")
        #expect(LogEventKind.obd.rawValue == "obd")
        #expect(LogEventKind.marker.rawValue == "marker")
        // Added in v2.
        #expect(LogEventKind.accelerometer.rawValue == "accel")
        #expect(LogEventKind.gyroscope.rawValue == "gyro")
        #expect(LogEventKind.magnetometer.rawValue == "mag")
        #expect(LogEventKind.barometer.rawValue == "baro")
        #expect(LogEventKind.elm.rawValue == "elm")
        #expect(LogEventKind.adapter.rawValue == "adapter")
        #expect(LogEventKind.link.rawValue == "link")
        #expect(LogEventKind.lifecycle.rawValue == "lifecycle")
        #expect(LogEventKind.stats.rawValue == "stats")
        #expect(LogEventKind.allCases.count == 13)
    }

    @Test("OBD PID and unit encodings are part of the format")
    func obdEncodingsAreStable() {
        #expect(OBDPID.vehicleSpeed.rawValue == 0x0D)
        #expect(OBDPID.engineSpeed.rawValue == 0x0C)
        #expect(OBDUnit.kilometersPerHour.rawValue == "km/h")
        #expect(OBDUnit.revolutionsPerMinute.rawValue == "rpm")
        #expect(OBDUnit.degreesCelsius.rawValue == "degC")
        #expect(OBDUnit.percent.rawValue == "%")
    }
}


/// Format v2 counterpart of the suite above. Same rule: the fixture is frozen at
/// the "contracts" commit and must never be edited to fit a later change.
@Suite("Log format compatibility v2")
struct LogFormatCompatibilityV2Tests {
    let codec = LogCodec()

    /// Format v2, canonical spelling, one event of every v2 kind plus a
    /// timed-out poll, a negative (pre-session) motion timestamp and a
    /// multi-PID reply decoded into two `obd` rows. Raw string literal so the
    /// JSON `\r` escapes in `rx`/`raw` stay escapes.
    static let version2Recording = #"""
        {"adapter":{"elmVersion":"ELM327 v2.1","gatt":{"maxWriteLength":20,"notify":"BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F","service":"E7810A71-73AE-499D-8C15-FAA9AEF0C3F2","write":"BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F","writeType":"withResponse"},"gattTable":[{"characteristics":[{"properties":["notify","write"],"uuid":"BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"}],"service":"E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"}],"identifier":"6A1F3C2E-0B4D-4E5F-9A8B-7C6D5E4F3A2B","name":"IOS-Vlink","protocol":"A6","voltage":12.4},"app":{"build":"7","name":"DriveLogger","version":"0.2.0"},"device":{"model":"iPhone16,1","systemName":"iOS","systemVersion":"18.6"},"formatVersion":2,"mount":"windscreen, portrait","polling":{"adaptiveTiming":2,"command":"010D0C1","multiPID":true,"pids":[13,12],"responseCount":1,"rpmEvery":1,"timeoutMs":1000},"referenceUptimeSeconds":5000.25,"sensors":{"accelerometerHz":100,"altimeter":true,"deviceMotionHz":100,"gyroHz":100,"magnetometerHz":10,"referenceFrame":"xArbitraryZVertical"},"sessionID":"9B2C1A40-5E7D-4F3A-8C21-6D0E4B7A1F52","startedAt":"2026-05-28T20:26:40Z","timeZone":"Europe/Kyiv","vehicle":"VW Touareg 2025"}
        {"data":{"event":"start"},"kind":"lifecycle","t":0}
        {"data":{"attitude":{"w":0.995,"x":0.1,"y":0,"z":0},"gravity":{"x":0,"y":-0.98,"z":-0.2},"magneticAccuracy":2,"magneticField":{"x":20.5,"y":-3.25,"z":-41},"rotationRate":{"x":0.001,"y":0.002,"z":-0.003},"userAcceleration":{"x":0.01,"y":-0.02,"z":0.005}},"kind":"motion","t":-20000000}
        {"data":{"x":0.012,"y":-0.981,"z":-0.195},"kind":"accel","t":5000000}
        {"data":{"x":0.004,"y":-0.001,"z":0.0125},"kind":"gyro","t":6000000}
        {"data":{"x":120.5,"y":-60.25,"z":-300},"kind":"mag","t":50000000}
        {"data":{"pressureKPa":99.874,"relativeAltitude":0.5},"kind":"baro","t":80000000}
        {"data":{"outcome":"ok","phase":"poll","requestT":95000000,"rx":"7E806410D320C1AF8\r\r","seq":41,"tx":"010D0C1"},"kind":"elm","t":120000000}
        {"data":{"command":"010D0C1","ecu":"7E8","pid":13,"raw":"7E806410D320C1AF8\r\r","requestT":95000000,"seq":41,"unit":"km/h","value":50},"kind":"obd","t":120000000}
        {"data":{"command":"010D0C1","ecu":"7E8","pid":12,"raw":"7E806410D320C1AF8\r\r","requestT":95000000,"seq":41,"unit":"rpm","value":1726},"kind":"obd","t":120000000}
        {"data":{"outcome":"timeout","phase":"poll","requestT":150000000,"seq":42,"tx":"010D0C1"},"kind":"elm","t":1150000000}
        {"data":{"from":"polling","layer":"elm","reason":"timeout","to":"retrying"},"kind":"link","t":1150000000}
        {"data":{"accessory":false,"ageS":0.25,"altitude":179,"course":271.5,"courseAccuracy":8,"ellipsoidalAltitude":207.5,"fixTime":"2026-05-28T20:26:41.150Z","horizontalAccuracy":4.5,"latitude":50.4501,"longitude":30.5234,"receivedT":1650000000,"simulated":false,"speed":13.9,"speedAccuracy":0.5,"verticalAccuracy":3},"kind":"location","t":1400000000}
        {"data":{"adapter":{"elmVersion":"ELM327 v2.1","identifier":"6A1F3C2E-0B4D-4E5F-9A8B-7C6D5E4F3A2B","name":"IOS-Vlink","protocol":"A6","voltage":12.3},"polling":{"adaptiveTiming":1,"command":"010D","multiPID":false,"pids":[13,12],"rpmEvery":5,"timeoutMs":1000}},"kind":"adapter","t":2000000000}
        {"data":"tunnel","kind":"marker","t":3000000000}
        {"data":{"bytesWritten":81920,"counts":{"accel":1000,"gyro":1000,"motion":1000,"obd":180},"dropped":0,"gaps":{"accel":0,"gyro":0,"motion":1},"maxGapMs":{"accel":10.5,"gyro":10.5,"motion":62},"motionHz":100,"obdHz":9,"queueDepthMax":34,"timeouts":1,"windowS":10},"kind":"stats","t":10000000000}
        {"data":{"detail":"user","event":"stop"},"kind":"lifecycle","t":10500000000}
        """#

    var document: LogDocument {
        get throws { try codec.document(from: Data(Self.version2Recording.utf8)) }
    }

    @Test("A v2 recording parses, header sections included")
    func readsVersion2Header() throws {
        let header = try document.header

        #expect(header.formatVersion == .v2)
        #expect(header.startedAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(header.referenceUptimeSeconds == 5_000.25)
        #expect(header.adapter?.name == "IOS-Vlink")
        #expect(header.adapter?.protocolNumber == "A6")
        #expect(header.adapter?.elmVersion == "ELM327 v2.1")
        #expect(header.adapter?.voltage == 12.4)
        #expect(header.adapter?.gatt?.maxWriteLength == 20)
        #expect(header.adapter?.gattTable?.first?.characteristics.first?.properties == ["notify", "write"])
        #expect(header.polling?.command == "010D0C1")
        #expect(header.polling?.pids == [13, 12])
        #expect(header.polling?.responseCount == 1)
        #expect(header.sensors?.referenceFrame == "xArbitraryZVertical")
        #expect(header.mount == "windscreen, portrait")
        #expect(header.vehicle == "VW Touareg 2025")
        #expect(header.timeZone == "Europe/Kyiv")
        #expect(header.notes == nil)
    }

    @Test("Every v2 event kind decodes to its own payload, none as unrecognized")
    func readsEveryVersion2Kind() throws {
        let events = try document.events
        #expect(events.count == 16)

        let kinds = Set(events.map(\.payload.kind))
        #expect(kinds == Set(LogEventKind.allCases.map(\.rawValue)))
        for event in events {
            if case .unrecognized(let kind, _) = event.payload {
                Issue.record("\(kind) decoded as unrecognized")
            }
        }
    }

    @Test("v2 OBD rows keep both timestamps, command, ECU and sequence")
    func readsVersion2OBD() throws {
        let events = try document.events
        let readings = events.compactMap { event -> (MonotonicTimestamp, OBDSample)? in
            guard case .obd(let sample) = event.payload else { return nil }
            return (event.timestamp, sample)
        }
        #expect(readings.count == 2)

        let (t, speed) = try #require(readings.first)
        #expect(t.nanoseconds == 120_000_000)
        #expect(speed.requestT?.nanoseconds == 95_000_000)
        #expect(speed.pid == .vehicleSpeed)
        #expect(speed.value == 50)
        #expect(speed.command == "010D0C1")
        #expect(speed.ecu == "7E8")
        #expect(speed.seq == 41)
        #expect(speed.raw == "7E806410D320C1AF8\r\r")
        #expect(readings[1].1.pid == .engineSpeed)
        #expect(readings[1].1.value == 1_726)

        guard case .elm(let exchange) = events[6].payload else {
            Issue.record("expected the elm exchange the readings came from")
            return
        }
        #expect(exchange.seq == speed.seq)
        #expect(exchange.rx == speed.raw)
    }

    @Test("A timed-out exchange has no reply and is followed by its transition")
    func readsVersion2Timeout() throws {
        let events = try document.events
        guard case .elm(let exchange) = events[9].payload,
              case .link(let link) = events[10].payload else {
            Issue.record("expected elm timeout then link transition")
            return
        }
        #expect(exchange.outcome == "timeout")
        #expect(exchange.rx == nil)
        #expect(link == LinkSample(layer: "elm", from: "polling", to: "retrying", reason: "timeout"))
    }

    @Test("v2 location keeps fix time on the session clock and its inputs")
    func readsVersion2Location() throws {
        let events = try document.events
        guard case .location(let fix) = events[11].payload else {
            Issue.record("expected a location payload")
            return
        }
        // t = receivedT - ageS
        #expect(events[11].timestamp.nanoseconds == 1_400_000_000)
        #expect(fix.receivedT?.nanoseconds == 1_650_000_000)
        #expect(fix.ageS == 0.25)
        #expect(fix.fixTime == "2026-05-28T20:26:41.150Z")
        #expect(fix.ellipsoidalAltitude == 207.5)
        #expect(fix.simulated == false)
        #expect(fix.accessory == false)
    }

    @Test("A pre-session motion timestamp stays negative")
    func keepsNegativeOffsets() throws {
        let events = try document.events
        #expect(events[1].timestamp.nanoseconds == -20_000_000)
        guard case .motion(let motion) = events[1].payload else {
            Issue.record("expected a motion payload")
            return
        }
        #expect(motion.magneticAccuracy == 2)
    }

    @Test("Rewriting a v2 recording reproduces it unchanged")
    func rewritesVersion2Identically() throws {
        let original = Data(Self.version2Recording.utf8)
        let rewritten = try codec.encode(try document)
        #expect(rewritten == original + Data("\n".utf8))
    }

    @Test("v2 vocabularies written by the app are stable on-disk strings")
    func vocabulariesAreStable() {
        #expect(LifecycleSample.Event.allCases.map(\.rawValue) == [
            "start", "stop", "pause", "resume", "background", "foreground",
            "calibrationStart", "calibrationEnd", "error", "memoryWarning",
            "thermalState", "protectedDataUnavailable",
        ])
        #expect(ELMPhase.allCases.map(\.rawValue) == ["init", "probe", "poll", "manual", "keepalive"])
        #expect(ELMOutcome.allCases.map(\.rawValue) == [
            "ok", "noData", "timeout", "stopped", "notRecognised", "canError",
            "busError", "busInitError", "bufferFull", "dataError",
            "unableToConnect", "adapterError", "malformed", "rejected",
        ])
        #expect(ELMState.allCases.map(\.rawValue) == [
            "idle", "resetting", "initialising", "searching", "probing", "ready",
            "polling", "retrying", "reinitialising", "failed",
        ])
    }
}
