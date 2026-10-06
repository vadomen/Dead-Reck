import CoreMotion
import DriveLoggerCore
import Foundation

// CoreMotion sources. Each converts into Core types field for field and stamps
// with `clock.timestamp(uptimeSeconds: item.timestamp)` — CoreMotion's own
// uptime, never arrival time. Callbacks run on a private OperationQueue, never
// the main queue, and only call `sink.record`; per `SensorSource`, the handler
// is a `@Sendable` closure that captures `clock` and `sink`, not `self`.
// Implemented in M2.

/// `CMDeviceMotion` at 100 Hz, reference frame `xArbitraryZVertical` → `motion`.
@MainActor
final class DeviceMotionSource: SensorSource {
    let name = "deviceMotion"
    let rateHz: Double

    init(rateHz: Double = 100) {
        self.rateHz = rateHz
    }

    var availability: SensorAvailability {
        fatalError("M2: DeviceMotionSource.availability")
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        fatalError("M2: DeviceMotionSource.start")
    }

    func stop() {
        fatalError("M2: DeviceMotionSource.stop")
    }
}

/// Raw accelerometer and gyroscope at 100 Hz, magnetometer at 10 Hz →
/// `accel`, `gyro`, `mag`.
@MainActor
final class RawIMUSource: SensorSource {
    let name = "rawIMU"
    let imuRateHz: Double
    let magnetometerRateHz: Double

    init(imuRateHz: Double = 100, magnetometerRateHz: Double = 10) {
        self.imuRateHz = imuRateHz
        self.magnetometerRateHz = magnetometerRateHz
    }

    var availability: SensorAvailability {
        fatalError("M2: RawIMUSource.availability")
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        fatalError("M2: RawIMUSource.start")
    }

    func stop() {
        fatalError("M2: RawIMUSource.stop")
    }
}

/// `CMAltimeter` relative altitude and pressure → `baro`.
@MainActor
final class AltimeterSource: SensorSource {
    let name = "altimeter"

    init() {}

    var availability: SensorAvailability {
        fatalError("M2: AltimeterSource.availability")
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        fatalError("M2: AltimeterSource.start")
    }

    func stop() {
        fatalError("M2: AltimeterSource.stop")
    }
}
