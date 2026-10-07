import Testing

@testable import DriveLoggerCore

@Suite("OBDDecoder")
struct OBDDecoderTests {
    @Test("Engine speed uses quarter-RPM resolution")
    func decodesEngineSpeed() throws {
        // 0x1AF8 = 6904 quarter-RPM = 1726 rpm
        let measurement = try OBDDecoder.decode(pid: .engineSpeed, payload: [0x1A, 0xF8])
        #expect(measurement.value == 1_726)
        #expect(measurement.unit == .revolutionsPerMinute)
    }

    @Test("Idle engine speed decodes without rounding drift")
    func decodesIdleEngineSpeed() throws {
        // 0x0BB8 = 3000 quarter-RPM = 750 rpm
        #expect(try OBDDecoder.decode(pid: .engineSpeed, payload: [0x0B, 0xB8]).value == 750)
    }

    @Test("Vehicle speed is already km/h")
    func decodesVehicleSpeed() throws {
        let measurement = try OBDDecoder.decode(pid: .vehicleSpeed, payload: [0x32])
        #expect(measurement.value == 50)
        #expect(measurement.unit == .kilometersPerHour)
    }

    @Test("Temperatures carry the -40 degC offset")
    func decodesTemperatures() throws {
        #expect(try OBDDecoder.decode(pid: .engineCoolantTemperature, payload: [0x5A]).value == 50)
        // 0x00 is the bottom of the range, not a missing value.
        #expect(try OBDDecoder.decode(pid: .intakeAirTemperature, payload: [0x00]).value == -40)
        #expect(try OBDDecoder.decode(pid: .engineCoolantTemperature, payload: [0xFF]).value == 215)
    }

    @Test("Percentage PIDs scale 0...255 onto 0...100")
    func decodesPercentages() throws {
        #expect(try OBDDecoder.decode(pid: .throttlePosition, payload: [0x00]).value == 0)
        #expect(try OBDDecoder.decode(pid: .throttlePosition, payload: [0xFF]).value == 100)
        #expect(try OBDDecoder.decode(pid: .calculatedEngineLoad, payload: [0xFF]).value == 100)
        #expect(try OBDDecoder.decode(pid: .fuelTankLevel, payload: [0xFF]).value == 100)

        let half = try OBDDecoder.decode(pid: .throttlePosition, payload: [0x80])
        #expect(abs(half.value - 50.196) < 0.001)
        #expect(half.unit == .percent)
    }

    @Test("Trailing CAN padding is ignored")
    func toleratesPadding() throws {
        // An eight-byte CAN frame pads a one-byte PID reply; the extra bytes
        // must not change the decoded value.
        let padded = try OBDDecoder.decode(pid: .vehicleSpeed, payload: [0x32, 0x00, 0x00, 0x00])
        #expect(padded.value == 50)
    }

    @Test("A short payload is an error, not a low reading")
    func rejectsShortPayload() {
        // Decoding [0x1A] as engine speed would silently yield a plausible
        // 1664 rpm from a half-read frame.
        #expect(throws: ELM327Error.truncatedFrame(expected: 2, actual: 1)) {
            try OBDDecoder.decode(pid: .engineSpeed, payload: [0x1A])
        }
        #expect(throws: ELM327Error.truncatedFrame(expected: 1, actual: 0)) {
            try OBDDecoder.decode(pid: .vehicleSpeed, payload: [])
        }
    }

    @Test("Decodes straight from a raw adapter reply")
    func decodesFromRaw() throws {
        let measurement = try OBDDecoder.decode(pid: .engineSpeed, raw: "41 0C 1A F8\r\r>")
        #expect(measurement.value == 1_726)
    }

    @Test("NO DATA from an unsupported PID surfaces as an error")
    func propagatesNoData() {
        #expect(throws: ELM327Error.noData) {
            try OBDDecoder.decode(pid: .fuelTankLevel, raw: "NO DATA\r>")
        }
    }

    @Test("Spec formulas: 0x0D is A km/h, 0x0C is (256A+B)/4 rpm")
    func specFormulas() throws {
        for a in [0, 1, 0x3C, 0xFF] {
            #expect(try OBDDecoder.decode(pid: .vehicleSpeed, payload: [UInt8(a)]).value == Double(a))
        }
        for (a, b) in [(0, 0), (0x0B, 0xB8), (0x1A, 0xF8), (0xFF, 0xFF)] {
            let expected = (256.0 * Double(a) + Double(b)) / 4.0
            #expect(try OBDDecoder.decode(pid: .engineSpeed, payload: [UInt8(a), UInt8(b)]).value == expected)
        }
    }

    @Test("Every PID declares a payload length and a unit")
    func everyPIDIsDescribed() {
        // Catches a PID case added without a matching decode rule: the switch in
        // OBDDecoder is exhaustive, so this only has to prove the metadata is
        // filled in and decoding a minimal payload succeeds.
        for pid in OBDPID.allCases {
            #expect(pid.payloadByteCount >= 1)
            let payload = [UInt8](repeating: 0, count: pid.payloadByteCount)
            #expect(throws: Never.self) {
                let measurement = try OBDDecoder.decode(pid: pid, payload: payload)
                #expect(measurement.unit == pid.unit)
            }
        }
    }
}

@Suite("OBDDecoder multi-PID")
struct OBDDecoderMultiPIDTests {
    @Test("Speed and RPM in one answer: 41 0D 3C 0C 1A F8")
    func speedAndRPM() throws {
        let measurements = try OBDDecoder.decode(
            requested: [.vehicleSpeed, .engineSpeed],
            bytes: [0x41, 0x0D, 0x3C, 0x0C, 0x1A, 0xF8]
        )
        #expect(measurements == [
            OBDMeasurement(pid: .vehicleSpeed, value: 60, unit: .kilometersPerHour),
            OBDMeasurement(pid: .engineSpeed, value: 1_726, unit: .revolutionsPerMinute),
        ])
    }

    @Test("PIDs may come back in any order; results follow the reply")
    func anyOrder() throws {
        let measurements = try OBDDecoder.decode(
            requested: [.vehicleSpeed, .engineSpeed],
            bytes: [0x41, 0x0C, 0x1A, 0xF8, 0x0D, 0x3C]
        )
        #expect(measurements.map(\.pid) == [.engineSpeed, .vehicleSpeed])
        #expect(measurements.map(\.value) == [1_726, 60])
    }

    @Test("An ECU may answer only the PIDs it supports")
    func subset() throws {
        let measurements = try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: [0x41, 0x0D, 0x3C])
        #expect(measurements == [OBDMeasurement(pid: .vehicleSpeed, value: 60, unit: .kilometersPerHour)])
    }

    @Test("A single-PID answer decodes through the same path")
    func single() throws {
        #expect(try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: [0x41, 0x0D, 0x00]).map(\.value) == [0])
    }

    @Test("Bytes after every requested PID are padding")
    func trailingPadding() throws {
        let measurements = try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: [0x41, 0x0D, 0x3C, 0x00, 0x00])
        #expect(measurements.count == 1)
    }

    @Test("An unrequested PID is rejected: its length would be a guess")
    func unrequested() {
        #expect(throws: ELM327Error.unexpectedPID(expected: 0x0C, actual: 0x11)) {
            try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: [0x41, 0x0D, 0x3C, 0x11, 0x80])
        }
    }

    @Test("A PID unknown to the table is rejected")
    func unknown() {
        #expect(throws: ELM327Error.unexpectedPID(expected: 0x0D, actual: 0x42)) {
            try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: [0x41, 0x42, 0x30, 0xD4])
        }
    }

    @Test("A repeated PID is rejected")
    func repeated() {
        #expect(throws: ELM327Error.unexpectedPID(expected: 0x0C, actual: 0x0D)) {
            try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: [0x41, 0x0D, 0x3C, 0x0D, 0x3C])
        }
    }

    @Test("A PID cut short is truncated, not a low value")
    func truncated() {
        #expect(throws: ELM327Error.truncatedFrame(expected: 2, actual: 1)) {
            try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: [0x41, 0x0D, 0x3C, 0x0C, 0x1A])
        }
    }

    @Test("A different service is rejected")
    func wrongMode() {
        #expect(throws: ELM327Error.unexpectedMode(expected: 0x41, actual: 0x7F)) {
            try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: [0x7F, 0x01, 0x12])
        }
    }

    @Test("A reply with no PID at all is truncated")
    func noPID() {
        #expect(throws: ELM327Error.truncatedFrame(expected: 2, actual: 1)) {
            try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: [0x41])
        }
    }

    @Test("Parser and decoder end to end on a header-on multi-PID reply")
    func endToEnd() throws {
        let replies = try ELM327ResponseParser.replies(in: "7E806410D3C0C1AF8\r\r", headers: true)
        let measurements = try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: replies[0].bytes)
        #expect(replies[0].header == "7E8")
        #expect(measurements.map(\.value) == [60, 1_726])
    }
}
