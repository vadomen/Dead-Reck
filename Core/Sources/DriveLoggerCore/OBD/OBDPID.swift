/// Service 01 ("show current data") PIDs this logger samples.
///
/// Byte layout and scaling follow SAE J1979. Adding a PID means adding a case
/// here plus its rule in `OBDDecoder.decode(pid:payload:)`; the compiler will
/// point at the switch that needs updating.
public enum OBDPID: UInt8, Hashable, Sendable, CaseIterable, Codable {
    case calculatedEngineLoad = 0x04
    case engineCoolantTemperature = 0x05
    case engineSpeed = 0x0C
    case vehicleSpeed = 0x0D
    case intakeAirTemperature = 0x0F
    case throttlePosition = 0x11
    case fuelTankLevel = 0x2F

    /// Data bytes a well-formed reply carries, excluding the service/PID echo.
    public var payloadByteCount: Int {
        switch self {
        case .engineSpeed:
            2
        case .calculatedEngineLoad, .engineCoolantTemperature, .vehicleSpeed,
             .intakeAirTemperature, .throttlePosition, .fuelTankLevel:
            1
        }
    }

    public var unit: OBDUnit {
        switch self {
        case .engineSpeed:
            .revolutionsPerMinute
        case .vehicleSpeed:
            .kilometersPerHour
        case .calculatedEngineLoad, .throttlePosition, .fuelTankLevel:
            .percent
        case .engineCoolantTemperature, .intakeAirTemperature:
            .degreesCelsius
        }
    }

    /// The PIDs worth polling for dead-reckoning work, fastest-changing first.
    ///
    /// Vehicle speed is the one that actually constrains a dead-reckoning
    /// solution; the rest are context for interpreting a drive afterwards.
    public static let deadReckoningSet: [OBDPID] = [
        .vehicleSpeed,
        .engineSpeed,
        .throttlePosition,
        .calculatedEngineLoad,
        .engineCoolantTemperature,
        .intakeAirTemperature,
        .fuelTankLevel,
    ]
}

/// Physical unit of a decoded OBD value.
///
/// Raw values are stored in these units rather than normalised to SI, so a log
/// line can be checked against a scan tool without converting anything.
public enum OBDUnit: String, Hashable, Sendable, Codable {
    case revolutionsPerMinute = "rpm"
    case kilometersPerHour = "km/h"
    case percent = "%"
    case degreesCelsius = "degC"
}
