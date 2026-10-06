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
        #expect(line.contains("\"formatVersion\":1"))
    }

    @Test("Every declared format version is readable")
    func allVersionsAreReadable() {
        // A version added to the enum without a reader is the failure mode this
        // invariant exists to prevent; keep a fixture per case above.
        #expect(LogFormatVersion.allCases == [.v1])
        #expect(LogFormatVersion.current == LogFormatVersion.allCases.max())
    }

    @Test("Event kind discriminators are part of the format and must not drift")
    func kindStringsAreStable() {
        #expect(LogEventKind.motion.rawValue == "motion")
        #expect(LogEventKind.location.rawValue == "location")
        #expect(LogEventKind.obd.rawValue == "obd")
        #expect(LogEventKind.marker.rawValue == "marker")
        #expect(LogEventKind.allCases.count == 4)
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
