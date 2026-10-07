import DriveLoggerCore
import Foundation

/// Simulated magnetometer (10 Hz) and barometer (1 Hz) → `mag`, `baro`:
/// the simulator twin of `RawIMUSource`'s magnetometer and of
/// `AltimeterSource`. Core's `SimulatedMotionSource` already covers device
/// motion, raw accelerometer and gyroscope, and `SimulatedLocationSource` the
/// reference fixes, so with this one the simulator build writes every sensor
/// kind a phone does.
///
/// Plausible, not physical: the phone sits upright in a windscreen mount on
/// the same 500 m anticlockwise circle as Core's simulated motion and
/// location, in Kyiv's field (about 19 µT horizontal, 47 µT down) plus a
/// fixed hard-iron bias, as an uncalibrated magnetometer reports it. Pressure
/// is 100.5 kPa with a slow ±0.3 m altitude swell.
///
/// Sample `n` of a stream is stamped `start + n × period` on the session
/// clock, from a private queue, never the main actor; `stop()` guarantees no
/// sample after it returns (`SimulatedSampleTicker`). Recordings made with it
/// say so in the header (`SensorSuite.simulated`).
@MainActor
final class SimulatedMagBaroSource: SensorSource {
    let name = "simulatedMagBaro"
    let availability = SensorAvailability.available
    let magnetometerRateHz: Double
    let barometerInterval: Duration
    private var tickers: [SimulatedSampleTicker] = []

    init(magnetometerRateHz: Double = 10, barometerInterval: Duration = .seconds(1)) {
        self.magnetometerRateHz = magnetometerRateHz
        self.barometerInterval = barometerInterval
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        let magPeriod = Duration.nanoseconds(Int64((1_000_000_000 / magnetometerRateHz).rounded()))
        let magPeriodS = 1 / magnetometerRateHz
        let baroPeriodS = Self.seconds(barometerInterval)
        tickers = [
            SimulatedSampleTicker(label: "simulatedMag", clock: clock, sink: sink, period: magPeriod) { index, t in
                [LogEvent(timestamp: t, payload: .magnetometer(Self.magneticField(atSeconds: Double(index) * magPeriodS)))]
            },
            SimulatedSampleTicker(label: "simulatedBaro", clock: clock, sink: sink, period: barometerInterval) { index, t in
                [LogEvent(timestamp: t, payload: .barometer(Self.barometer(atSeconds: Double(index) * baroPeriodS)))]
            },
        ]
        for ticker in tickers { ticker.begin() }
    }

    func stop() {
        for ticker in tickers { ticker.stop() }
        tickers = []
    }

    nonisolated static let horizontalField = 19.0
    nonisolated static let verticalField = 47.0
    nonisolated static let hardIronBias = Vector3(x: 12, y: -7, z: 25)
    /// rad/s, as Core's `SimulatedMotionModel` (13.9 m/s on a 500 m circle).
    nonisolated static let yawRate = 13.9 / 500

    /// µT in the device frame (x right, y up, z towards the driver), heading
    /// starting north and turning anticlockwise.
    nonisolated static func magneticField(atSeconds t: Double) -> Vector3 {
        let heading = -yawRate * t   // clockwise from north
        return Vector3(
            x: -horizontalField * sin(heading) + hardIronBias.x,
            y: -verticalField + hardIronBias.y,
            z: -horizontalField * cos(heading) + hardIronBias.z
        )
    }

    nonisolated static func barometer(atSeconds t: Double) -> BarometerSample {
        let altitude = 0.3 * sin(2 * .pi * t / 120)
        // About 0.012 kPa per metre near sea level.
        return BarometerSample(pressureKPa: 100.5 - 0.012 * altitude, relativeAltitude: altitude)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Delivers sample `n` at `start + n × period` on the session clock from a
/// private serial queue, like Core's (internal) simulated ticker: timestamps
/// are computed, not read per tick, so spacing is exact however late the
/// timer fires, and a late tick delivers every sample that has come due.
/// `stop()` closes a `SampleGate`, so no sample reaches the sink after it
/// returns.
final class SimulatedSampleTicker: Sendable {
    private let gate: SampleGate
    private let start: MonotonicTimestamp
    private let periodNanoseconds: Int64
    private let events: @Sendable (_ index: Int, _ t: MonotonicTimestamp) -> [LogEvent]
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var timer: (any DispatchSourceTimer)?
    /// Guarded by `lock`. Index of the next sample.
    private nonisolated(unsafe) var nextIndex = 0

    init(
        label: String,
        clock: SessionClock,
        sink: LogSink,
        period: Duration,
        events: @escaping @Sendable (_ index: Int, _ t: MonotonicTimestamp) -> [LogEvent]
    ) {
        gate = SampleGate(source: label, clock: clock, sink: sink)
        start = clock.now()
        let (seconds, attoseconds) = period.components
        periodNanoseconds = max(1, seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        self.events = events
        queue = DispatchQueue(label: "DriveLogger.\(label)", qos: .userInitiated)
    }

    deinit {
        timer?.cancel()
    }

    func begin() {
        let tick = Int(min(periodNanoseconds, 20_000_000))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(tick), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.deliverDue() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        gate.close()
        let timer = lock.withLock { () -> (any DispatchSourceTimer)? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    private func deliverDue() {
        lock.withLock {
            let elapsed = gate.clock.now().nanoseconds - start.nanoseconds
            guard elapsed >= 0 else { return }
            let due = Int(elapsed / periodNanoseconds) + 1
            while nextIndex < due {
                let t = MonotonicTimestamp(nanoseconds: start.nanoseconds + Int64(nextIndex) * periodNanoseconds)
                gate.deliver(events(nextIndex, t))
                nextIndex += 1
            }
        }
    }
}
