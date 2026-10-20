import Foundation

/// The demo drive's sensor streams (REL-DEMO), derived from `DemoDrive`:
/// device motion with raw accelerometer and gyroscope, location fixes and
/// the OBD vehicle-speed reply. Every value is a pure function of the time
/// since the demo started (`t`, seconds, the demo session's clock: the
/// session clock's 0 is the demo's 0) or of a sample index on that clock,
/// so the same run gives the same stream on every run and every device.
/// Noise is fixed-seed (`NavigationRandom` seeded from the stream and the
/// index), never `SystemRandomNumberGenerator`.
///
/// Plausible, not measured: the car is `DemoDrive`'s (flat road, no slip),
/// the phone is `SimulatedMotionModel`'s (upright windscreen mount, device
/// `y` up, screen facing the driver, `-z` forward, `x` to the right).
///
/// - **Motion** (`motion(at:)`): gravity `(0, -1, 0)` g; user acceleration
///   longitudinal on `-z` and lateral (+ right) on `+x`, in the direction
///   of the car's acceleration, as `SimulatedMotionModel` (the engine reads
///   only its horizontal magnitude); rotation rate about the vertical
///   `-yawRateRadPerS` on `y`, so `rotationRate · ĝ` (the engine's yaw,
///   + clockwise) is the route's yaw rate; attitude = the mount tilt, then
///   yaw about the vertical by minus the route's unwrapped heading change,
///   so it is continuous across laps and consistent with the rotation rate.
///   Road vibration (accel and pitch/roll rate) only while moving, growing
///   with speed; stationary, only a 0.0015 g idle hum on the vertical axis,
///   far below the engine's parked threshold, and no rotation at all.
///   Device motion's rotation rate is bias-free (CoreMotion's is
///   bias-corrected); the raw gyroscope carries `gyroBias`. No magnetic
///   field (nil, accuracy -1, as `SimulatedMotionModel`): the engine never
///   reads it, and a field would have to be invented for the demo area.
/// - **Location** (`locationFix(second:)`): one candidate per whole second.
///   Before `gnssUntilS`: a GNSS fix every second, 5 m accuracy, Doppler
///   speed and (while moving) course, ~1.5 m fixed-seed scatter. From then
///   on GNSS is gone: only network (cell tower) fixes, shaped like the
///   ones the engine treats as network fixes (`hasValidSpeed` false: speed,
///   speed accuracy, course and course accuracy all -1, no altitude),
///   claimed accuracy `networkAccuracyM`, one per `networkSlotS` slot at a
///   fixed-seed second inside it (6–18 s apart, ~12 s on average), offset
///   from the truth by a fixed-seed tower error that holds for
///   `towerWindowS` (per-axis σ `towerOffsetSigmaM`, the tower residuals
///   measured on the manual drive) plus `networkScatterSigmaM` per fix.
/// - **OBD** (`obdSpeedKmh(at:)`, `elmReply`): vehicle speed in whole km/h,
///   truncated as an ECU reports it (the engine adds its +0.5 km/h
///   truncation offset back), and a plausible engine speed, written into
///   the scripted ELM reply of each speed/RPM poll.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public struct DemoSensorModel: Sendable {
    public let drive: DemoDrive

    /// GNSS fixes stop here, s; network fixes only after.
    public static let gnssUntilS = 60.0
    /// One network fix per slot of this many seconds.
    public static let networkSlotS = 12
    /// A slot's fix comes 0 … this − 1 seconds into it (fixed-seed).
    public static let networkJitterS = 7
    /// The claimed accuracy of a network fix, m (a cell tower's typical
    /// `horizontalAccuracy`).
    public static let networkAccuracyM = 1414.0
    /// A tower error holds for this long, s, then the next one starts.
    public static let towerWindowS = 90.0
    /// Per-axis σ of a tower error, m.
    public static let towerOffsetSigmaM = 160.0
    /// Per-axis σ of a network fix around its tower error, m.
    public static let networkScatterSigmaM = 25.0
    /// GNSS: claimed accuracy and per-axis scatter, m.
    public static let gnssAccuracyM = 5.0
    public static let gnssScatterSigmaM = 1.5
    /// Raw gyroscope bias, rad/s (what bias correction removes; device
    /// motion's rotation rate has none). As `SimulatedMotionModel`.
    public static let gyroBias = Vector3(x: 0.002, y: -0.001, z: 0.0015)
    /// Engine idle, rpm.
    public static let idleRPM = 760.0
    /// The OBD poll grid the demo's navigation is fed (`obdInput(poll:)`,
    /// `DemoFeedSequencer`): poll `k` is requested at `k × 61 ms` of demo
    /// time and its `7E8` reply arrives 59 ms later, the bench's ~16.4 Hz
    /// and p50 latency. In nanoseconds, so the grid is exact.
    public static let obdPollIntervalNs: Int64 = 61_000_000
    public static let obdReplyLatencyNs: Int64 = 59_000_000

    /// Every demo run's session ID, so its navigation seed
    /// (`NavigationSeed.derive(sessionID:)`, as for any run) is the same on
    /// every start, every device: derived from the bundled pack's content
    /// hash. The demo writes nothing, so the ID names no file.
    public static let sessionID: UUID = {
        let h = DemoRoadPack.contentHash
        let hex = NavigationSeed.hex(h).uppercased()
        return UUID(uuidString: "DE30D21E-0000-4000-8\(hex.prefix(3))-\(hex.suffix(12))")!
    }()

    /// The demo run's navigation seed.
    public static var navigationSeed: UInt64 { NavigationSeed.derive(sessionID: sessionID) }

    static let standardGravity = 9.80665

    /// Turn accumulated before each path piece, rad (+ clockwise), and over
    /// a whole lap.
    private let turnBefore: [Double]
    private let lapTurn: Double
    private let startHeading: Double

    public init(drive: DemoDrive) {
        self.drive = drive
        var sum = 0.0
        var before: [Double] = []
        for piece in drive.path.pieces {
            before.append(sum)
            sum += piece.turn
        }
        turnBefore = before
        lapTurn = sum
        startHeading = drive.path.pieces.first?.heading0 ?? 0
    }

    // MARK: Heading

    /// Heading at `time`, radians clockwise from north, **unwrapped**: the
    /// lap-start heading plus every turn since the demo started (± 2π per
    /// lap of a loop). Modulo 2π it is `state(at:).headingDeg`.
    public func unwrappedHeading(at time: Double) -> Double {
        unwrappedHeading(drive.state(at: time))
    }

    func unwrappedHeading(_ state: DemoDriveState) -> Double {
        startHeading + Double(state.lap) * lapTurn + turn(atS: state.distanceAlongLapM)
    }

    /// The turn from the lap start to arc length `s`, rad.
    private func turn(atS s: Double) -> Double {
        let pieces = drive.path.pieces
        guard !pieces.isEmpty else { return 0 }
        var lo = 0, hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pieces[mid].s0 <= s { lo = mid } else { hi = mid - 1 }
        }
        let p = pieces[lo]
        guard p.turn != 0, p.length > 0 else { return turnBefore[lo] }
        let x = min(max((s - p.s0) / p.length, 0), 1)
        return turnBefore[lo] + p.turn * (x - sin(2 * .pi * x) / (2 * .pi))
    }

    // MARK: Motion

    /// Device motion, raw accelerometer (gravity + user acceleration, g) and
    /// raw gyroscope (rotation rate + `gyroBias`, rad/s) at `time`.
    public func motion(at time: Double) -> (motion: MotionSample, accelerometer: Vector3, gyroscope: Vector3) {
        let state = drive.state(at: time)
        let t = time
        let g0 = Self.standardGravity
        // Road vibration grows with speed up to 8 m/s; none while stationary.
        let level = min(1, state.speedMps / 8)
        let vertical = state.isStationary
            ? 0.0015 * sin(2 * .pi * 12.7 * t)
            : level * (0.015 * sin(2 * .pi * 11.7 * t) + 0.008 * sin(2 * .pi * 17.3 * t + 1.1))
        let user = Vector3(
            x: state.lateralAccelerationMps2 / g0 + level * 0.004 * sin(2 * .pi * 5.3 * t + 0.4),
            y: vertical,
            z: -state.accelerationMps2 / g0 + level * 0.004 * sin(2 * .pi * 7.1 * t + 2.0)
        )
        let gravity = Vector3(x: 0, y: -1, z: 0)
        // Pitch/roll vibration only; the vertical axis carries the yaw rate
        // alone, so the attitude below integrates it exactly.
        let rotation = Vector3(
            x: level * 0.004 * sin(2 * .pi * 9.1 * t),
            y: -state.yawRateRadPerS,
            z: level * 0.004 * sin(2 * .pi * 8.2 * t + 1.9)
        )
        // Tilt 90° about x (screen upright), then yaw about the vertical by
        // minus the heading change (+ about up is anticlockwise).
        let yaw = -(unwrappedHeading(state) - startHeading)
        let s = sin(yaw / 2), c = cos(yaw / 2), a = 0.5.squareRoot()
        let attitude = Quaternion(x: c * a, y: s * a, z: s * a, w: c * a)
        let motion = MotionSample(
            userAcceleration: user, gravity: gravity, rotationRate: rotation, attitude: attitude,
            magneticField: nil, magneticAccuracy: -1
        )
        let accel = Vector3(x: gravity.x + user.x, y: gravity.y + user.y, z: gravity.z + user.z)
        let b = Self.gyroBias
        let gyro = Vector3(x: rotation.x + b.x, y: rotation.y + b.y, z: rotation.z + b.z)
        return (motion, accel, gyro)
    }

    /// `[motion, accel, gyro]` for sample `index` at `rateHz` (t = index /
    /// rateHz), as `SimulatedMotionModel.payloads`.
    public func motionPayloads(index: Int, rateHz: Double) -> [LogEvent.Payload] {
        let m = motion(at: Double(index) / rateHz)
        return [.motion(m.motion), .accelerometer(m.accelerometer), .gyroscope(m.gyroscope)]
    }

    // MARK: Location

    /// The fix for whole second `second` of the demo, if one is due then:
    /// GNSS every second before `gnssUntilS`, a network fix at one second
    /// per `networkSlotS` slot after it. Fields only; the source adds
    /// `receivedT`, `fixTime`, `ageS` and `simulated`.
    public func locationFix(second: Int) -> LocationSample? {
        guard second >= 0 else { return nil }
        let t = Double(second)
        if t < Self.gnssUntilS { return gnssFix(second: second) }
        return isNetworkSecond(second) ? networkFix(second: second) : nil
    }

    /// Whether `second` (≥ `gnssUntilS`) carries a network fix.
    public func isNetworkSecond(_ second: Int) -> Bool {
        let k = second - Int(Self.gnssUntilS)
        guard k >= 0 else { return false }
        let slot = k / Self.networkSlotS
        var rng = NavigationRandom(seed: Self.seed(stream: 3, index: slot))
        return k % Self.networkSlotS == Int(rng.next() % UInt64(Self.networkJitterS))
    }

    func gnssFix(second: Int) -> LocationSample {
        let state = drive.state(at: Double(second))
        var rng = NavigationRandom(seed: Self.seed(stream: 1, index: second))
        let (de, dn) = rng.nextGaussianPair()
        let g = drive.plane.geodetic(east: state.east + de * Self.gnssScatterSigmaM,
                                     north: state.north + dn * Self.gnssScatterSigmaM)
        let moving = state.speedMps >= 0.5
        var course = -1.0, courseAccuracy = -1.0
        if moving {
            course = (state.headingDeg + 0.5 * rng.nextGaussian()).truncatingRemainder(dividingBy: 360)
            if course < 0 { course += 360 }
            courseAccuracy = 5
        }
        let speed = state.isStationary ? 0 : max(0, state.speedMps + 0.1 * rng.nextGaussian())
        return LocationSample(
            latitude: g.latitude, longitude: g.longitude, altitude: 100,
            horizontalAccuracy: Self.gnssAccuracyM, verticalAccuracy: 3,
            speed: speed, speedAccuracy: 0.5, course: course + 0, courseAccuracy: courseAccuracy,
            ellipsoidalAltitude: 130, accessory: false
        )
    }

    func networkFix(second: Int) -> LocationSample {
        let t = Double(second)
        let state = drive.state(at: t)
        let window = Int(((t - Self.gnssUntilS) / Self.towerWindowS).rounded(.down))
        var tower = NavigationRandom(seed: Self.seed(stream: 4, index: window))
        let (oe, on) = tower.nextGaussianPair()
        var rng = NavigationRandom(seed: Self.seed(stream: 2, index: second))
        let (se, sn) = rng.nextGaussianPair()
        let g = drive.plane.geodetic(
            east: state.east + oe * Self.towerOffsetSigmaM + se * Self.networkScatterSigmaM,
            north: state.north + on * Self.towerOffsetSigmaM + sn * Self.networkScatterSigmaM
        )
        return LocationSample(
            latitude: g.latitude, longitude: g.longitude, altitude: 0,
            horizontalAccuracy: Self.networkAccuracyM, verticalAccuracy: -1,
            speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
            accessory: false
        )
    }

    /// The seed of sample `index` of noise stream `stream`.
    static func seed(stream: UInt64, index: Int) -> UInt64 {
        0xDE30_D21E_0000_0000 ^ (stream << 40) ^ UInt64(bitPattern: Int64(index))
    }

    // MARK: OBD

    /// Vehicle speed an ECU reports at `time`, whole km/h, truncated (as
    /// J1979 PID 0x0D carries it); 0 when `time` is nil (no demo running:
    /// the car is parked).
    public func obdSpeedKmh(at time: Double?) -> Int {
        guard let time else { return 0 }
        let kmh = drive.state(at: time).speedMps * 3.6
        return min(255, max(0, Int(kmh.rounded(.down))))
    }

    /// Engine speed at `time`, rpm: idle when stopped, else a five-gear
    /// model (plausible, not a vehicle's).
    public func obdRPM(at time: Double?) -> Double {
        let kmh = Double(obdSpeedKmh(at: time))
        guard kmh > 0 else { return Self.idleRPM }
        let rpmPerKmh: Double = switch kmh {
        case ..<15: 100
        case ..<30: 55
        case ..<45: 40
        case ..<60: 32
        default: 26
        }
        return max(Self.idleRPM + 140, kmh * rpmPerKmh)
    }

    /// The reply an adapter gives at `time` to `command`: `scripted` with
    /// every vehicle-speed byte (after `410D`) set to `obdSpeedKmh(at:)`
    /// and every engine-speed pair (after `410C`, or after the speed byte
    /// as `0C` in a multi-PID answer) to `obdRPM(at:)`. Other commands, and
    /// lines without those PIDs (`NO DATA`, `?`), pass unchanged.
    public func elmReply(command: String, scripted: String, at time: Double?) -> String {
        let wire = command.uppercased()
        guard wire.hasPrefix("010D") || wire.hasPrefix("010C") else { return scripted }
        let speed = obdSpeedKmh(at: time)
        let rpm = min(0xFFFF, max(0, Int((obdRPM(at: time) * 4).rounded())))
        let lines = scripted.split(separator: "\r", omittingEmptySubsequences: false).map { line in
            Self.rewrite(String(line), speed: speed, rpmRaw: rpm)
        }
        return lines.joined(separator: "\r")
    }

    static func rewrite(_ line: String, speed: Int, rpmRaw: Int) -> String {
        var chars = Array(line.utf8)
        // Headers on: 3 header digits and the PCI byte come first.
        let from = line.hasPrefix("7E") && chars.count >= 9 ? 5 : 0
        func find(_ pattern: String, after start: Int) -> Int? {
            let p = Array(pattern.utf8)
            guard chars.count >= p.count, start <= chars.count - p.count else { return nil }
            for i in start...(chars.count - p.count) where Array(chars[i..<(i + p.count)]) == p { return i + p.count }
            return nil
        }
        func put(_ hex: String, at index: Int) {
            let h = Array(hex.utf8)
            guard index + h.count <= chars.count else { return }
            chars.replaceSubrange(index..<(index + h.count), with: h)
        }
        let speedHex = String(format: "%02X", speed), rpmHex = String(format: "%04X", rpmRaw)
        if let i = find("410D", after: from) {
            put(speedHex, at: i)
            if chars.count >= i + 8, Array(chars[(i + 2)..<(i + 4)]) == Array("0C".utf8) { put(rpmHex, at: i + 4) }
        } else if let i = find("410C", after: from) {
            put(rpmHex, at: i)
        }
        return String(decoding: chars, as: UTF8.self)
    }

    // MARK: Navigation inputs on the canonical grid

    /// Poll `k` of the OBD grid as the engine gets it: the primary ECU's
    /// vehicle speed at the request time, stamped with the reply's arrival.
    public func obdInput(poll k: Int) -> NavigationInput {
        let requestNs = Int64(k) * Self.obdPollIntervalNs
        let arrival = MonotonicTimestamp(nanoseconds: requestNs + Self.obdReplyLatencyNs)
        let kmh = obdSpeedKmh(at: Double(requestNs) / 1e9)
        let sample = OBDSample(
            pid: .vehicleSpeed, value: Double(kmh), unit: .kilometersPerHour,
            raw: String(format: "7E806410D%02X0C%04X", kmh, min(0xFFFF, Int((obdRPM(at: Double(requestNs) / 1e9) * 4).rounded()))),
            requestT: MonotonicTimestamp(nanoseconds: requestNs), command: "010D0C1", ecu: "7E8", seq: k
        )
        return .obd(sample, at: arrival)
    }

    /// Second `second`'s fix as the engine gets it (`t` = `receivedT` =
    /// the second, age 0, `simulated`), as `DemoLocationSource` records it
    /// but without `fixTime` (wall clock; the engine never reads it).
    public func locationInput(second: Int) -> NavigationInput? {
        guard var fix = locationFix(second: second) else { return nil }
        let t = MonotonicTimestamp(nanoseconds: Int64(second) * 1_000_000_000)
        fix.receivedT = t
        fix.ageS = 0
        fix.simulated = true
        return .location(fix, at: t)
    }

    /// The demo's navigation inputs from 0 to `end` seconds in the order
    /// `DemoFeedSequencer` releases them: what the demo's engine is fed,
    /// whatever the live delivery did.
    public func canonicalInputs(until end: Double, motionRateHz: Double = 100) -> [NavigationInput] {
        var sequencer = DemoFeedSequencer(model: self)
        let periodNs = Int64((1e9 / motionRateHz).rounded())
        var out: [NavigationInput] = []
        for n in 0...Int(end * motionRateHz) {
            let t = MonotonicTimestamp(nanoseconds: Int64(n) * periodNs)
            out += sequencer.accept(.motion(motion(at: Double(n) / motionRateHz).motion, at: t))
        }
        return out
    }

    /// The bench car's script (`MockELMAdapter.Rule.benchCar`) with the poll
    /// replies at the bench's measured latency (p50 59 ms, about 16 polls a
    /// second): the demo adapter's rules, its speed written in by
    /// `elmReply` through `MockELMAdapter`'s reply transform.
    public static var elmRules: [MockELMAdapter.Rule] {
        MockELMAdapter.Rule.benchCar.map { rule in
            var rule = rule
            if rule.command.hasPrefix("010D") { rule.delay = .milliseconds(59) }
            return rule
        }
    }
}

/// When the running demo started, for streams that carry no session time of
/// their own (the simulated adapter's replies): the demo session clock's
/// reference uptime, set by the demo sources when they start on that clock
/// and cleared when the demo ends. Thread-safe; never blocks for long.
public final class DemoTimeline: Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var origin: Double?

    public init() {}

    /// The demo's 0 is `clock`'s 0.
    public func begin(clock: SessionClock) {
        lock.withLock { origin = clock.referenceUptimeSeconds }
    }

    /// No demo running: `seconds(atUptime:)` is nil.
    public func reset() {
        lock.withLock { origin = nil }
    }

    public var originUptimeSeconds: Double? { lock.withLock { origin } }

    /// Demo time at `uptime` (seconds since boot, `UptimeSource`'s base);
    /// nil before the demo's sources started. Negative values are legal.
    public func seconds(atUptime uptime: Double) -> Double? {
        lock.withLock { origin.map { uptime - $0 } }
    }
}
