import Foundation
import Testing

@testable import DriveLoggerCore

/// Shared fixtures for the log-format tests.
enum LogFixtures {
    static let sessionID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

    static let app = AppIdentity(name: "DriveLogger", version: "0.1.0", build: "1")

    static let device = DeviceIdentity(
        model: "iPhone15,2",
        systemName: "iOS",
        systemVersion: "17.4"
    )

    static let header = LogHeader(
        sessionID: sessionID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        referenceUptimeSeconds: 1_234.5,
        app: app,
        device: device,
        notes: "windscreen mount, dry"
    )

    static let motion = MotionSample(
        userAcceleration: Vector3(x: 0.1, y: 0.2, z: 0.3),
        gravity: Vector3(x: 0, y: 0, z: -1),
        rotationRate: Vector3(x: 0.01, y: -0.02, z: 0.03),
        attitude: .identity,
        magneticField: Vector3(x: 12, y: -34, z: 56)
    )

    static let location = LocationSample(
        latitude: 59.4372,
        longitude: 24.7536,
        altitude: 12.5,
        horizontalAccuracy: 5,
        verticalAccuracy: 3,
        speed: 13.2,
        speedAccuracy: 1.1,
        course: 87.5,
        courseAccuracy: 5
    )

    static let document = LogDocument(
        header: header,
        events: [
            .motion(motion, at: MonotonicTimestamp(nanoseconds: 1_000_000)),
            .location(location, at: MonotonicTimestamp(nanoseconds: 2_000_000)),
            .obd(
                OBDSample(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour, raw: "410D32"),
                at: MonotonicTimestamp(nanoseconds: 3_000_000)
            ),
            .marker("entered tunnel", at: MonotonicTimestamp(nanoseconds: 4_000_000)),
        ]
    )
}

@Suite("LogCodec round trip")
struct LogCodecTests {
    let codec = LogCodec()

    @Test("A full recording survives encode and decode")
    func roundTripsDocument() throws {
        let data = try codec.encode(LogFixtures.document)
        let decoded = try codec.document(from: data)
        #expect(decoded.header == LogFixtures.header)
        #expect(decoded.events == LogFixtures.document.events)
        #expect(decoded.skippedLineIndices.isEmpty)
    }

    @Test("Every line is a standalone JSON object")
    func writesOneObjectPerLine() throws {
        let data = try codec.encode(LogFixtures.document)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        // Header plus four events, and nothing pretty-printed across lines.
        #expect(lines.count == 5)
        for line in lines {
            #expect(line.hasPrefix("{"))
            #expect(line.hasSuffix("}"))
            #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
        }
    }

    @Test("The file ends with a newline so appending is safe")
    func terminatesLines() throws {
        let data = try codec.encode(LogFixtures.document)
        #expect(data.last == UInt8(ascii: "\n"))
    }

    @Test("Encoding is byte-stable across instances")
    func encodesDeterministically() throws {
        // Sorted keys matter: fixture tests and content hashes of recordings are
        // only meaningful if the same input produces the same bytes.
        let first = try LogCodec().encode(LogFixtures.document)
        let second = try LogCodec().encode(LogFixtures.document)
        #expect(first == second)
    }

    @Test("The header timestamp is written as ISO 8601")
    func writesISO8601Dates() throws {
        let line = String(decoding: try codec.line(for: LogFixtures.header), as: UTF8.self)
        #expect(line.contains("\"startedAt\":\"2023-11-14T22:13:20Z\""))
    }

    @Test("Optional sample fields are preserved, including absent ones")
    func preservesOptionals() throws {
        var withoutMagnetometer = LogFixtures.motion
        withoutMagnetometer.magneticField = nil
        let event = LogEvent.motion(withoutMagnetometer, at: .zero)

        let decoded = try codec.event(from: codec.line(for: event))
        #expect(decoded == event)

        let obd = LogEvent.obd(
            OBDSample(pid: .engineSpeed, value: 1_726, unit: .revolutionsPerMinute),
            at: .zero
        )
        #expect(try codec.event(from: codec.line(for: obd)) == obd)
    }

    @Test("Negative CoreLocation sentinels are not normalised away")
    func preservesInvalidFixSentinels() throws {
        let unusableFix = LocationSample(
            latitude: 0,
            longitude: 0,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            speed: -1,
            speedAccuracy: -1,
            course: -1,
            courseAccuracy: -1
        )
        let event = LogEvent.location(unusableFix, at: .zero)
        let decoded = try codec.event(from: codec.line(for: event))
        #expect(decoded == event)

        guard case .location(let sample) = decoded.payload else {
            Issue.record("expected a location payload")
            return
        }
        #expect(!sample.hasValidPosition)
        #expect(!sample.hasValidSpeed)
        #expect(!sample.hasValidCourse)
    }

    @Test("An empty file reports a missing header")
    func rejectsEmptyFile() {
        #expect(throws: LogDecodingError.missingHeader) {
            try codec.document(from: Data())
        }
    }

    @Test("A file whose first line is an event reports a missing header")
    func rejectsHeaderlessFile() throws {
        let data = try codec.line(for: .marker("no header", at: .zero))
        #expect(throws: LogDecodingError.missingHeader) {
            try codec.document(from: data)
        }
    }
}

@Suite("LogCodec damaged recordings")
struct LogRecoveryTests {
    let codec = LogCodec()

    /// A recording cut off mid-line, as a flat battery or a crash leaves it.
    func truncatedRecording() throws -> Data {
        var data = try codec.encode(LogFixtures.document)
        data = data.dropLast(40)
        return data
    }

    @Test("Strict reading fails on a truncated final line")
    func strictRejectsTruncation() throws {
        let data = try truncatedRecording()
        #expect(throws: LogDecodingError.self) {
            try codec.document(from: data, recovery: .strict)
        }
    }

    @Test("Recovery keeps the drive and reports the lost line")
    func recoverySalvagesDrive() throws {
        let data = try truncatedRecording()
        let decoded = try codec.document(from: data, recovery: .skipMalformedLines)

        #expect(decoded.header == LogFixtures.header)
        #expect(decoded.events.count == 3)
        #expect(decoded.skippedLineIndices == [4])
    }

    @Test("Blank and CRLF-terminated lines are tolerated")
    func toleratesLineNoise() throws {
        var data = Data()
        data.append(try codec.line(for: LogFixtures.header))
        data.append(UInt8(ascii: "\n"))
        var eventLine = try codec.line(for: .marker("tunnel", at: .zero))
        eventLine = eventLine.dropLast() + Data("\r\n".utf8)
        data.append(eventLine)

        let decoded = try codec.document(from: data)
        #expect(decoded.events.count == 1)
    }
}
