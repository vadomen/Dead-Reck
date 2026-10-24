import DriveLoggerCore
import Foundation

/// The sensor sources a recording starts, with the configuration written to
/// the header's `sensors` section and, for simulated data, a header note.
///
/// `makeDefault()` picks the real CoreMotion/CoreLocation sources on a device
/// and their simulated twins on the simulator, which has no motion sensors
/// (and whose location would need a permission prompt and a scripted route).
@MainActor
struct SensorSuite {
    let sources: [any SensorSource]
    /// Requested configuration — what was asked for, not what was achieved
    /// (achieved rates are in `stats` rows).
    let configuration: SensorConfigRecord
    /// Header `notes` saying what is simulated; nil for real sensors.
    let note: String?
    /// The map-only position feed for while no run owns location (R61.1-4):
    /// not one of `sources`, never started by a run, never given a clock or
    /// a sink. nil: the map shows no plain GPS position.
    var displayLocation: (any DisplayLocationProviding)?

    nonisolated static let deviceMotionHz = 100.0
    nonisolated static let imuHz = 100.0
    nonisolated static let magnetometerHz = 10.0

    static func makeDefault() -> SensorSuite {
        #if targetEnvironment(simulator)
        simulated()
        #else
        device()
        #endif
    }

    /// CoreMotion device motion, raw IMU, altimeter and the reference
    /// location source.
    static func device() -> SensorSuite {
        SensorSuite(
            sources: [
                DeviceMotionSource(rateHz: deviceMotionHz),
                RawIMUSource(imuRateHz: imuHz, magnetometerRateHz: magnetometerHz),
                AltimeterSource(),
                ReferenceLocationSource(),
            ],
            configuration: configuration,
            note: nil,
            displayLocation: DisplayLocationSource()
        )
    }

    /// Deterministic twins: Core's `SimulatedMotionSource` (motion, accel,
    /// gyro) and `SimulatedLocationSource` (fixes marked `simulated: true`),
    /// plus `SimulatedMagBaroSource` (mag, baro). Same requested rates as
    /// the device, so a simulator recording has the shape of a real one.
    static func simulated() -> SensorSuite {
        SensorSuite(
            sources: [
                SimulatedMotionSource(rateHz: deviceMotionHz),
                SimulatedMagBaroSource(magnetometerRateHz: magnetometerHz),
                SimulatedLocationSource(),
            ],
            configuration: configuration,
            note: simulatedNote,
            displayLocation: SimulatedDisplayLocationSource()
        )
    }

    nonisolated static let simulatedNote = "Simulated sensors (simulator build): motion, accel, gyro, mag, baro and location are generated, not measured."

    nonisolated static var configuration: SensorConfigRecord {
        SensorConfigRecord(
            deviceMotionHz: deviceMotionHz,
            accelerometerHz: imuHz,
            gyroHz: imuHz,
            magnetometerHz: magnetometerHz,
            referenceFrame: "xArbitraryZVertical",
            altimeter: true
        )
    }
}

/// The `SensorAvailability.unavailable(reason:)` strings of the real sources
/// (UX-15). The raw value is what the recording holds: `RecordingSession`
/// writes "<source> unavailable: <raw value>" as a `lifecycle` `error` row,
/// so it is on-disk text, English, never reworded. The screen shows
/// `display`, the catalog text in the app language.
enum SensorUnavailableReason: String, CaseIterable, Sendable {
    case deviceMotionUnsupported = "Device motion is unavailable on this device"
    case referenceFrameUnsupported = "Reference frame xArbitraryZVertical is unavailable"
    case accelerometerUnsupported = "The accelerometer is unavailable on this device"
    case gyroscopeUnsupported = "The gyroscope is unavailable on this device"
    case barometerUnsupported = "The barometer is unavailable on this device"
    case motionDenied = "Motion & Fitness access is denied (Settings → Privacy & Security → Motion & Fitness)"
    case motionRestricted = "Motion & Fitness access is restricted on this device"
    case locationDenied = "Location access is denied, or Location Services are off (Settings → Privacy & Security → Location Services)"
    case locationRestricted = "Location access is restricted on this device"

    var availability: SensorAvailability { .unavailable(reason: rawValue) }

    /// The catalog key is the English text (= `rawValue`), spelled out so
    /// string extraction sees each one.
    var resource: LocalizedStringResource {
        switch self {
        case .deviceMotionUnsupported: "Device motion is unavailable on this device"
        case .referenceFrameUnsupported: "Reference frame xArbitraryZVertical is unavailable"
        case .accelerometerUnsupported: "The accelerometer is unavailable on this device"
        case .gyroscopeUnsupported: "The gyroscope is unavailable on this device"
        case .barometerUnsupported: "The barometer is unavailable on this device"
        case .motionDenied: "Motion & Fitness access is denied (Settings → Privacy & Security → Motion & Fitness)"
        case .motionRestricted: "Motion & Fitness access is restricted on this device"
        case .locationDenied: "Location access is denied, or Location Services are off (Settings → Privacy & Security → Location Services)"
        case .locationRestricted: "Location access is restricted on this device"
        }
    }

    /// The text in `language` ("uk", "en"); nil: the app language.
    func display(language: String? = nil) -> String {
        var r = resource
        if let language { r.locale = Locale(identifier: language) }
        return String(localized: r)
    }

    /// What the screen shows for an `unavailable(reason:)` string: the
    /// catalog text for one of these reasons, any other reason (a simulated
    /// or test source) as it is.
    static func display(_ reason: String, language: String? = nil) -> String {
        Self(rawValue: reason)?.display(language: language) ?? reason
    }
}
