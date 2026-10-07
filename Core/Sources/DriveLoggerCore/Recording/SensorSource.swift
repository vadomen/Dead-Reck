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
/// in a car going round a gentle curve (`SimulatedMotionModel`).
///
/// Sample `n` is stamped `start + n / rateHz` on the session clock, where
/// `start` is `clock.now()` at `start(clock:sink:)` — exact spacing, no
/// jitter, no gaps — and its values depend only on `n` and `rateHz`. The three
/// events of one instant share a timestamp and are recorded in the order
/// `motion`, `accel`, `gyro`, from a private queue, never the main actor.
/// `start` while running restarts from the new clock.
@MainActor
public final class SimulatedMotionSource: SensorSource {
    public let name = "simulatedMotion"
    public let availability = SensorAvailability.available
    public let rateHz: Double
    private var ticker: SimulatedTicker?

    public init(rateHz: Double = 100) {
        self.rateHz = rateHz
    }

    public func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        let rateHz = rateHz
        let ticker = SimulatedTicker(
            label: name,
            clock: clock,
            sink: sink,
            period: .nanoseconds(Int64((1_000_000_000 / rateHz).rounded()))
        ) { index, t in
            SimulatedMotionModel.payloads(index: index, rateHz: rateHz).map { LogEvent(timestamp: t, payload: $0) }
        }
        self.ticker = ticker
        ticker.begin()
    }

    /// Idempotent. No event reaches the sink after it returns.
    public func stop() {
        ticker?.stop()
        ticker = nil
    }
}

/// Deterministic fake GNSS along a loop (`SimulatedLocationModel`), one fix
/// per `interval` (1 s by default), with `simulated: true` set so it can never
/// be mistaken for a real fix — GNSS is reference data, and a simulated fix
/// even more so.
///
/// Fix `n` is stamped `start + n × interval`; `receivedT` equals `t` and
/// `ageS` is 0 (no delivery delay to model). `fixTime` is that instant on the
/// header's wall clock (`SessionClock.wallClock(for:)`), so the v2 fields are
/// all exercised; no `Date()` is read per sample. Delivered from a private
/// queue, never the main actor.
@MainActor
public final class SimulatedLocationSource: SensorSource {
    public let name = "simulatedLocation"
    public let availability = SensorAvailability.available
    public let interval: Duration
    private var ticker: SimulatedTicker?

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    public func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        let (seconds, attoseconds) = interval.components
        let intervalS = Double(seconds) + Double(attoseconds) / 1e18
        let ticker = SimulatedTicker(label: name, clock: clock, sink: sink, period: interval) { index, t in
            var fix = SimulatedLocationModel.fix(index: index, intervalS: intervalS)
            fix.receivedT = t
            fix.ageS = 0
            fix.fixTime = clock.wallClock(for: t).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            fix.simulated = true
            return [.location(fix, at: t)]
        }
        self.ticker = ticker
        ticker.begin()
    }

    /// Idempotent. No event reaches the sink after it returns.
    public func stop() {
        ticker?.stop()
        ticker = nil
    }
}
