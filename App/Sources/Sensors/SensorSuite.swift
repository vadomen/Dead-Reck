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
            note: nil
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
            note: simulatedNote
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
