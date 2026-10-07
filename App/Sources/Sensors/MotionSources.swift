import CoreMotion
import DriveLoggerCore
import Foundation

// CoreMotion sources. Each converts into Core types field for field and stamps
// with `clock.timestamp(uptimeSeconds: item.timestamp)` — CoreMotion's own
// uptime, never arrival time, never clamped (a batch that began before the
// session gets negative `t`). Callbacks run on a private serial
// `OperationQueue`, never the main queue, and only hand events to a
// `SampleGate`, which calls `sink.record` (non-blocking). Per `SensorSource`,
// every handler is a `@Sendable` closure built in a `nonisolated` function
// that captures the gate, not `self`.
//
// Untested on hardware: achieved rates, batching behaviour and background
// delivery (docs/PLAN.md §6). The simulator has no motion sensors; the
// simulator build uses the simulated twins (`SensorSuite`).

/// The app's one `CMMotionManager`. Apple asks for a single instance per
/// app: several managers can lower the rate each of them receives.
@MainActor
enum SharedMotionManager {
    static let manager = CMMotionManager()
}

/// Why a source could not start; the recorder writes it as a `lifecycle`
/// `error` row (`SensorSource.start`).
struct SensorStartError: Error, CustomStringConvertible {
    let source: String
    let reason: String

    var description: String { "\(source): \(reason)" }
}

/// `CMDeviceMotion` at 100 Hz, reference frame `xArbitraryZVertical` → `motion`.
@MainActor
final class DeviceMotionSource: SensorSource {
    let name = "deviceMotion"
    let rateHz: Double
    /// Never uses the magnetometer, so no compass calibration prompt and no
    /// heading jumps from magnetic disturbances in a car; yaw drifts and is
    /// arbitrary at start. The raw magnetometer is recorded by `RawIMUSource`.
    static let referenceFrame = CMAttitudeReferenceFrame.xArbitraryZVertical

    private let queue = OperationQueue.serial(named: "DriveLogger.deviceMotion")
    private var gate: SampleGate?

    init(rateHz: Double = 100) {
        self.rateHz = rateHz
    }

    var availability: SensorAvailability {
        let manager = SharedMotionManager.manager
        guard manager.isDeviceMotionAvailable else {
            return .unavailable(reason: "Device motion is unavailable on this device")
        }
        guard CMMotionManager.availableAttitudeReferenceFrames().contains(Self.referenceFrame) else {
            return .unavailable(reason: "Reference frame xArbitraryZVertical is unavailable")
        }
        return .available
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        if case .unavailable(let reason) = availability {
            throw SensorStartError(source: name, reason: reason)
        }
        let gate = SampleGate(source: name, clock: clock, sink: sink)
        self.gate = gate
        let manager = SharedMotionManager.manager
        manager.deviceMotionUpdateInterval = 1 / rateHz
        manager.startDeviceMotionUpdates(using: Self.referenceFrame, to: queue, withHandler: Self.handler(gate: gate))
    }

    func stop() {
        guard let gate else { return }
        SharedMotionManager.manager.stopDeviceMotionUpdates()
        // Handlers already queued may still run; the closed gate drops them.
        gate.close()
        self.gate = nil
    }

    nonisolated static func handler(gate: SampleGate) -> CMDeviceMotionHandler {
        let handler: @Sendable (CMDeviceMotion?, (any Error)?) -> Void = { motion, error in
            if let error { gate.report(error) }
            guard let motion else { return }
            gate.deliver(LogEvent(
                timestamp: gate.clock.timestamp(uptimeSeconds: motion.timestamp),
                payload: .motion(MotionSample(motion))
            ))
        }
        return handler
    }
}

/// Raw accelerometer and gyroscope at 100 Hz, magnetometer at 10 Hz →
/// `accel`, `gyro`, `mag`. Uncorrected: gravity included, gyro bias not
/// removed, magnetometer uncalibrated (device hard-iron bias included).
///
/// Accelerometer and gyroscope are required; a phone without a magnetometer
/// still records the other two, and the missing magnetometer is written as
/// a `lifecycle` `error` row at start.
@MainActor
final class RawIMUSource: SensorSource {
    let name = "rawIMU"
    let imuRateHz: Double
    let magnetometerRateHz: Double

    private let queue = OperationQueue.serial(named: "DriveLogger.rawIMU")
    private var gate: SampleGate?

    init(imuRateHz: Double = 100, magnetometerRateHz: Double = 10) {
        self.imuRateHz = imuRateHz
        self.magnetometerRateHz = magnetometerRateHz
    }

    var availability: SensorAvailability {
        let manager = SharedMotionManager.manager
        guard manager.isAccelerometerAvailable else {
            return .unavailable(reason: "The accelerometer is unavailable on this device")
        }
        guard manager.isGyroAvailable else {
            return .unavailable(reason: "The gyroscope is unavailable on this device")
        }
        return .available
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        if case .unavailable(let reason) = availability {
            throw SensorStartError(source: name, reason: reason)
        }
        let gate = SampleGate(source: name, clock: clock, sink: sink)
        self.gate = gate
        let manager = SharedMotionManager.manager
        manager.accelerometerUpdateInterval = 1 / imuRateHz
        manager.gyroUpdateInterval = 1 / imuRateHz
        manager.startAccelerometerUpdates(to: queue, withHandler: Self.accelerometerHandler(gate: gate))
        manager.startGyroUpdates(to: queue, withHandler: Self.gyroHandler(gate: gate))
        if manager.isMagnetometerAvailable {
            manager.magnetometerUpdateInterval = 1 / magnetometerRateHz
            manager.startMagnetometerUpdates(to: queue, withHandler: Self.magnetometerHandler(gate: gate))
        } else {
            gate.deliver(LogEvent(
                timestamp: clock.now(),
                payload: .lifecycle(LifecycleSample(.error, detail: "\(name): magnetometer unavailable; recording accel and gyro only"))
            ))
        }
    }

    func stop() {
        guard let gate else { return }
        let manager = SharedMotionManager.manager
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        gate.close()
        self.gate = nil
    }

    nonisolated static func accelerometerHandler(gate: SampleGate) -> CMAccelerometerHandler {
        let handler: @Sendable (CMAccelerometerData?, (any Error)?) -> Void = { data, error in
            if let error { gate.report(error) }
            guard let data else { return }
            gate.deliver(LogEvent(
                timestamp: gate.clock.timestamp(uptimeSeconds: data.timestamp),
                payload: .accelerometer(Vector3(data.acceleration))
            ))
        }
        return handler
    }

    nonisolated static func gyroHandler(gate: SampleGate) -> CMGyroHandler {
        let handler: @Sendable (CMGyroData?, (any Error)?) -> Void = { data, error in
            if let error { gate.report(error) }
            guard let data else { return }
            gate.deliver(LogEvent(
                timestamp: gate.clock.timestamp(uptimeSeconds: data.timestamp),
                payload: .gyroscope(Vector3(data.rotationRate))
            ))
        }
        return handler
    }

    nonisolated static func magnetometerHandler(gate: SampleGate) -> CMMagnetometerHandler {
        let handler: @Sendable (CMMagnetometerData?, (any Error)?) -> Void = { data, error in
            if let error { gate.report(error) }
            guard let data else { return }
            gate.deliver(LogEvent(
                timestamp: gate.clock.timestamp(uptimeSeconds: data.timestamp),
                payload: .magnetometer(Vector3(data.magneticField))
            ))
        }
        return handler
    }
}

/// `CMAltimeter` relative altitude and pressure → `baro`, at the rate the
/// device chooses (about 1 Hz). Needs Motion & Fitness permission.
@MainActor
final class AltimeterSource: SensorSource {
    let name = "altimeter"

    private let altimeter = CMAltimeter()
    private let queue = OperationQueue.serial(named: "DriveLogger.altimeter")
    private var gate: SampleGate?

    init() {}

    var availability: SensorAvailability {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            return .unavailable(reason: "The barometer is unavailable on this device")
        }
        switch CMAltimeter.authorizationStatus() {
        case .denied:
            return .unavailable(reason: "Motion & Fitness access is denied (Settings → Privacy & Security → Motion & Fitness)")
        case .restricted:
            return .unavailable(reason: "Motion & Fitness access is restricted on this device")
        case .notDetermined, .authorized:
            return .available
        @unknown default:
            return .available
        }
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        if case .unavailable(let reason) = availability {
            throw SensorStartError(source: name, reason: reason)
        }
        let gate = SampleGate(source: name, clock: clock, sink: sink)
        self.gate = gate
        altimeter.startRelativeAltitudeUpdates(to: queue, withHandler: Self.handler(gate: gate))
    }

    func stop() {
        guard let gate else { return }
        altimeter.stopRelativeAltitudeUpdates()
        gate.close()
        self.gate = nil
    }

    nonisolated static func handler(gate: SampleGate) -> CMAltitudeHandler {
        let handler: @Sendable (CMAltitudeData?, (any Error)?) -> Void = { data, error in
            if let error { gate.report(error) }
            guard let data else { return }
            gate.deliver(LogEvent(
                timestamp: gate.clock.timestamp(uptimeSeconds: data.timestamp),
                payload: .barometer(BarometerSample(data))
            ))
        }
        return handler
    }
}

// MARK: - Field-for-field conversion at the app boundary

extension MotionSample {
    /// Every field as CoreMotion reports it. `magneticField` is the
    /// calibrated field, kept only once CoreMotion reports a calibration
    /// accuracy other than `uncalibrated` (Core's documented rule); the
    /// accuracy itself is always kept.
    nonisolated init(_ motion: CMDeviceMotion) {
        let field = motion.magneticField
        let q = motion.attitude.quaternion
        self.init(
            userAcceleration: Vector3(motion.userAcceleration),
            gravity: Vector3(motion.gravity),
            rotationRate: Vector3(motion.rotationRate),
            attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w),
            magneticField: field.accuracy == .uncalibrated ? nil : Vector3(field.field),
            magneticAccuracy: Int(field.accuracy.rawValue)
        )
    }
}

extension Vector3 {
    /// g.
    nonisolated init(_ acceleration: CMAcceleration) {
        self.init(x: acceleration.x, y: acceleration.y, z: acceleration.z)
    }

    /// rad/s.
    nonisolated init(_ rotation: CMRotationRate) {
        self.init(x: rotation.x, y: rotation.y, z: rotation.z)
    }

    /// µT.
    nonisolated init(_ field: CMMagneticField) {
        self.init(x: field.x, y: field.y, z: field.z)
    }
}

extension BarometerSample {
    /// `pressure` is in kPa and `relativeAltitude` in metres, as CoreMotion
    /// reports them.
    nonisolated init(_ data: CMAltitudeData) {
        self.init(pressureKPa: data.pressure.doubleValue, relativeAltitude: data.relativeAltitude.doubleValue)
    }
}

extension OperationQueue {
    /// A serial queue for one source's callbacks.
    nonisolated static func serial(named name: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }
}
