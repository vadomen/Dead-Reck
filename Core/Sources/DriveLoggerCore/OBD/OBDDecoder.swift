/// A decoded reading for one PID, in that PID's native unit.
public struct OBDMeasurement: Hashable, Sendable, Codable {
    public let pid: OBDPID
    public let value: Double
    public let unit: OBDUnit

    public init(pid: OBDPID, value: Double, unit: OBDUnit) {
        self.pid = pid
        self.value = value
        self.unit = unit
    }
}

/// Applies SAE J1979 scaling to raw service 01 payloads.
public enum OBDDecoder {
    /// Decodes data bytes for a PID.
    ///
    /// The payload must be the bytes *after* the service/PID echo — what
    /// `ELM327ResponseParser.dataBytes(in:mode:pid:)` returns. Extra trailing
    /// bytes are tolerated (some adapters pad to the CAN frame length); too few
    /// is an error, because a short read would otherwise decode as a plausible
    /// low value.
    public static func decode(pid: OBDPID, payload: [UInt8]) throws -> OBDMeasurement {
        guard payload.count >= pid.payloadByteCount else {
            throw ELM327Error.truncatedFrame(
                expected: pid.payloadByteCount,
                actual: payload.count
            )
        }

        let a = Double(payload[0])
        let value: Double

        switch pid {
        case .calculatedEngineLoad, .throttlePosition, .fuelTankLevel:
            // A * 100 / 255
            value = a * 100.0 / 255.0
        case .engineCoolantTemperature, .intakeAirTemperature:
            // A - 40, offset so -40 degC fits in an unsigned byte
            value = a - 40.0
        case .engineSpeed:
            // ((A * 256) + B) / 4 — quarter-RPM resolution
            value = ((a * 256.0) + Double(payload[1])) / 4.0
        case .vehicleSpeed:
            // A, already km/h
            value = a
        }

        return OBDMeasurement(pid: pid, value: value, unit: pid.unit)
    }

    /// Decodes a raw adapter reply end to end: line splitting, error status
    /// detection, multi-frame reassembly, echo validation, then scaling.
    public static func decode(pid: OBDPID, raw: String) throws -> OBDMeasurement {
        let payload = try ELM327ResponseParser.dataBytes(in: raw, mode: 0x01, pid: pid.rawValue)
        return try decode(pid: pid, payload: payload)
    }
}
