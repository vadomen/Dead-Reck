import Foundation

// Machinery behind `SimulatedMotionSource` and `SimulatedLocationSource`:
// deterministic sample models and a ticker that delivers on its own queue.
//
// Simulated data exists so previews, the simulator and tests can run the
// whole pipeline. It is plausible, not physical truth, and is never mixed
// with real data: locations carry `simulated: true`, and the header's
// `sensors`/`notes` are the recorder's to fill.

/// Delivers sample `n` at `start + n × period` on the session clock, from a
/// private serial queue — never the main actor.
///
/// Timestamps are computed, not read per tick, so spacing is exact however
/// late the timer fires; a late tick delivers every sample that has come due
/// (like a CoreMotion batch). No sample is ever stamped in the future.
///
/// `stop()` takes `lock`, which every delivery holds while it hands events
/// to the sink, so once `stop()` returns no further event can reach the
/// sink. The sink never blocks, so holding the lock across `record` is
/// cheap.
final class SimulatedTicker: Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var timer: (any DispatchSourceTimer)?
    /// Guarded by `lock`.
    private nonisolated(unsafe) var stopped = false
    /// Guarded by `lock`. Index of the next sample to deliver.
    private nonisolated(unsafe) var nextIndex = 0

    private let clock: SessionClock
    private let sink: LogSink
    private let start: MonotonicTimestamp
    private let periodNanoseconds: Int64
    private let events: @Sendable (_ index: Int, _ t: MonotonicTimestamp) -> [LogEvent]
    private let queue: DispatchQueue

    init(
        label: String,
        clock: SessionClock,
        sink: LogSink,
        period: Duration,
        events: @escaping @Sendable (_ index: Int, _ t: MonotonicTimestamp) -> [LogEvent]
    ) {
        self.clock = clock
        self.sink = sink
        self.start = clock.now()
        let (seconds, attoseconds) = period.components
        self.periodNanoseconds = max(1, seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        self.events = events
        self.queue = DispatchQueue(label: "DriveLogger.\(label)", qos: .userInitiated)
    }

    /// Starts ticking every `tick` (at most every 20 ms, at least once per
    /// sample period).
    func begin() {
        let tickNanoseconds = Int(min(periodNanoseconds, 20_000_000))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(tickNanoseconds), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.deliverDue()
        }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        let timer = lock.withLock { () -> (any DispatchSourceTimer)? in
            stopped = true
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    private func deliverDue() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let elapsed = clock.now().nanoseconds - start.nanoseconds
        guard elapsed >= 0 else { return }
        let due = Int(elapsed / periodNanoseconds) + 1
        while nextIndex < due {
            let t = MonotonicTimestamp(nanoseconds: start.nanoseconds + Int64(nextIndex) * periodNanoseconds)
            for event in events(nextIndex, t) {
                sink.record(event)
            }
            nextIndex += 1
        }
    }
}

/// A phone upright in a windscreen mount (device `y` up, screen facing the
/// driver, `-z` forward) in a car driving a 500 m circle anticlockwise at
/// 13.9 m/s (50 km/h), with a 12 Hz road vibration. Matches
/// `SimulatedLocationModel`'s loop.
enum SimulatedMotionModel {
    static let speed = 13.9
    static let radius = 500.0
    static var yawRate: Double { speed / radius }
    /// Raw gyroscope bias, rad/s: what bias correction would remove.
    static let gyroBias = Vector3(x: 0.002, y: -0.001, z: 0.0015)

    /// `[motion, accel, gyro]` for sample `index` at `rateHz`.
    static func payloads(index: Int, rateHz: Double) -> [LogEvent.Payload] {
        let t = Double(index) / rateHz
        let lateral = speed * speed / radius / 9.80665          // g, toward the centre (left, -x)
        let vibration = 0.02 * sin(2 * .pi * 12 * t)            // g, vertical
        let gravity = Vector3(x: 0, y: -1, z: 0)
        let user = Vector3(x: -lateral, y: vibration, z: 0.005 * sin(2 * .pi * 0.2 * t))
        let rotation = Vector3(x: 0, y: yawRate, z: 0)

        // Attitude: tilt 90° about x (screen upright), then yaw about the
        // vertical by the heading change.
        let half = yawRate * t / 2
        let s = sin(half), c = cos(half), a = 0.5.squareRoot()
        let attitude = Quaternion(x: c * a, y: s * a, z: s * a, w: c * a)

        let motion = MotionSample(
            userAcceleration: user,
            gravity: gravity,
            rotationRate: rotation,
            attitude: attitude,
            magneticField: nil,
            magneticAccuracy: -1
        )
        let accel = Vector3(x: gravity.x + user.x, y: gravity.y + user.y, z: gravity.z + user.z)
        let gyro = Vector3(x: rotation.x + gyroBias.x, y: rotation.y + gyroBias.y, z: rotation.z + gyroBias.z)
        return [.motion(motion), .accelerometer(accel), .gyroscope(gyro)]
    }
}

/// GNSS fixes on the same 500 m anticlockwise circle as
/// `SimulatedMotionModel`, centred in Kyiv. Fields only; the source adds
/// `receivedT`, `fixTime`, `ageS` and `simulated`.
enum SimulatedLocationModel {
    static let centreLatitude = 50.4501
    static let centreLongitude = 30.5234
    static let metresPerDegree = 111_320.0
    static var speed: Double { SimulatedMotionModel.speed }
    static var radius: Double { SimulatedMotionModel.radius }

    static func fix(index: Int, intervalS: Double) -> LocationSample {
        let angle = speed / radius * Double(index) * intervalS   // anticlockwise from east
        let north = radius * sin(angle)
        let east = radius * cos(angle)
        let latitude = centreLatitude + north / metresPerDegree
        let longitude = centreLongitude + east / (metresPerDegree * cos(centreLatitude * .pi / 180))
        // Velocity points 90° anticlockwise from the radius; course is
        // clockwise from north.
        var course = (-angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if course < 0 { course += 360 }
        course += 0  // -0.0 → 0.0, so JSON never says "-0"
        return LocationSample(
            latitude: latitude,
            longitude: longitude,
            altitude: 170,
            horizontalAccuracy: 5,
            verticalAccuracy: 3,
            speed: speed,
            speedAccuracy: 0.5,
            course: course,
            courseAccuracy: 5,
            ellipsoidalAltitude: 197,
            accessory: false
        )
    }
}
