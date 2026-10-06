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
