import Foundation

/// Whether a sensor can run on this device right now.
public enum SensorAvailability: Hashable, Sendable {
    case available
    /// Shown in the UI as-is, e.g. "Motion unavailable on the simulator".
    case unavailable(reason: String)
}

/// One stream of samples into a recording.
///
/// Real sources (CoreMotion, CoreLocation) live in the app and convert into
/// Core sample types at the boundary; simulated ones live here. Every source
/// stamps its events with the recording's single `SessionClock` — via
/// `clock.timestamp(uptimeSeconds:)` when the framework supplies an uptime,
/// `clock.now()` otherwise — and hands them to `sink`, which never blocks.
///
/// Main-actor isolated: `start`/`stop` are called by `RecordingSession` on the
/// main actor, and `CLLocationManager` must be created and driven on a thread
/// with a run loop. Samples must **not** be delivered on the main actor. Give
/// the framework a handler explicitly marked `@Sendable` (or built in a
/// `nonisolated` function) that captures only `clock` and `sink` — both
/// `Sendable` — and not `self`. A non-`Sendable` closure written inside a
/// `@MainActor` method is inferred main-actor isolated, and Swift 6 traps at
/// runtime when CoreMotion calls it on its own queue.
@MainActor
public protocol SensorSource: AnyObject {
    /// Short stable name for logs and UI, e.g. `deviceMotion`.
    var name: String { get }
    var availability: SensorAvailability { get }
    /// Starts delivering. Throws if the sensor is unavailable or permission
    /// was denied; the recorder writes that as a `lifecycle` error row.
    func start(clock: SessionClock, sink: LogSink) throws
    /// Stops delivering. Idempotent. No events reach `sink` after it returns.
    func stop()
}

/// Deterministic fake motion for previews and the simulator: device motion,
/// raw accelerometer and gyroscope at `rateHz`, as if the phone sat in a mount
/// in a car going round a gentle curve.
@MainActor
public final class SimulatedMotionSource: SensorSource {
    public let name = "simulatedMotion"
    public let availability = SensorAvailability.available
    public let rateHz: Double

    public init(rateHz: Double = 100) {
        self.rateHz = rateHz
    }

    public func start(clock: SessionClock, sink: LogSink) throws {
        fatalError("M1: SimulatedMotionSource.start")
    }

    public func stop() {
        fatalError("M1: SimulatedMotionSource.stop")
    }
}

/// Deterministic fake GNSS at 1 Hz along a loop, with `simulated: true` set
/// so it can never be mistaken for a real fix.
@MainActor
public final class SimulatedLocationSource: SensorSource {
    public let name = "simulatedLocation"
    public let availability = SensorAvailability.available

    public init() {}

    public func start(clock: SessionClock, sink: LogSink) throws {
        fatalError("M1: SimulatedLocationSource.start")
    }

    public func stop() {
        fatalError("M1: SimulatedLocationSource.stop")
    }
}
