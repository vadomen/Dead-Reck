import Foundation

/// The demo drive (REL-DEMO): a car looping forever over a fixed route of
/// the bundled demo pack, as a pure function of time since the demo
/// started. It is what the simulated sensors, OBD and GPS are derived from;
/// nothing here is random, so the same time gives the same state on every
/// run and every device.
///
/// One lap: stationary for `startDwellS` (the app calibrates at a
/// stationary start), then the loop with a full stop at a junction, back to
/// the start, where it stops. The next lap starts at once, so every
/// quantity is continuous at the wrap. Acceleration is continuous with
/// bounded jerk (`DemoSpeedProfile`); turns have sin²-shaped curvature
/// (heading and yaw rate continuous).
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public struct DemoDrive: Sendable {
    /// Lap length along the driven path, m.
    public let lapLengthM: Double
    /// Lap duration, s (the period of `state(at:)`).
    public let lapDurationS: Double
    /// Stationary at the start of each lap, s.
    public let startDwellS: Double
    /// The intervals of a lap with the car stationary, in lap time (s): the
    /// start, the junction stop. The lap ends arriving at the start, so the
    /// first interval also continues the previous lap's end.
    public let stationaryIntervals: [ClosedRange<Double>]
    /// The local east/north plane `DemoDriveState.east/north` refer to.
    public let plane: LocalTangentPlane
    /// The road polyline the loop follows (pack coordinates), starting and
    /// ending at the lap start: for drawing the route.
    public var roadShape: [RoadPoint] { path.roadShape }

    let path: DemoPath
    let profile: DemoSpeedProfile

    /// The standard demo loop over the bundled demo pack
    /// (`DemoRoadPack.open(at:)`).
    public init(pack: RoadPack) throws {
        try self.init(pack: pack, definition: .standard, parameters: .standard)
    }

    init(pack: RoadPack, definition: DemoRouteDefinition, parameters: DemoDriveParameters) throws {
        path = try DemoPath(pack: pack, definition: definition, parameters: parameters)
        profile = DemoSpeedProfile(path: path, parameters: parameters)
        lapLengthM = path.length
        lapDurationS = profile.period
        startDwellS = parameters.startDwellS
        stationaryIntervals = profile.stationary.map(\.range)
        plane = path.plane
    }

    /// The car at `time` seconds since the demo started (any real number;
    /// the drive repeats with period `lapDurationS`).
    public func state(at time: Double) -> DemoDriveState {
        let period = lapDurationS
        var lap = (time / period).rounded(.down)
        var lapTime = time - lap * period
        if lapTime >= period { lapTime -= period; lap += 1 }
        if lapTime < 0 { lapTime = 0 }
        let m = profile.motion(at: lapTime)
        let pose = path.pose(at: m.s)
        let g = plane.geodetic(east: pose.east, north: pose.north)
        return DemoDriveState(
            time: time, lap: Int(lap), lapTime: lapTime,
            distanceAlongLapM: m.s, odometerM: lap * lapLengthM + m.s,
            latitude: g.latitude, longitude: g.longitude, east: pose.east, north: pose.north,
            headingDeg: pose.heading * 180 / .pi,
            speedMps: m.v, accelerationMps2: m.a, jerkMps3: m.jerk,
            curvaturePerM: pose.curvature,
            yawRateRadPerS: m.v * pose.curvature,
            lateralAccelerationMps2: m.v * m.v * pose.curvature,
            activity: m.activity
        )
    }
}

/// The demo car at one instant. The car does not slip: heading is the
/// course over ground. The road is flat (no pitch, roll or altitude).
public struct DemoDriveState: Hashable, Sendable {
    public enum Activity: String, Hashable, Sendable {
        /// Stationary at the lap start.
        case startStop
        /// Stationary at the junction stop.
        case junctionStop
        case driving
    }

    /// Seconds since the demo started, as asked.
    public var time: Double
    /// Completed laps (negative before the demo started).
    public var lap: Int
    /// Seconds since this lap started, [0, lapDurationS).
    public var lapTime: Double
    /// Distance along the lap's path, m.
    public var distanceAlongLapM: Double
    /// Distance driven since the demo started, m (negative before it).
    public var odometerM: Double
    /// WGS-84 position.
    public var latitude: Double
    public var longitude: Double
    /// Position in `DemoDrive.plane`, m.
    public var east: Double
    public var north: Double
    /// Heading = course, degrees clockwise from true north, [0, 360).
    public var headingDeg: Double
    /// Speed, m/s (≥ 0).
    public var speedMps: Double
    /// Longitudinal acceleration dv/dt, m/s² (+ speeding up).
    public var accelerationMps2: Double
    /// d(acceleration)/dt, m/s³.
    public var jerkMps3: Double
    /// Path curvature, 1/m, + turning right (clockwise seen from above).
    public var curvaturePerM: Double
    /// Yaw rate = speed × curvature, rad/s, + clockwise seen from above, so
    /// heading integrates like a compass bearing.
    public var yawRateRadPerS: Double
    /// Centripetal acceleration = speed² × curvature, m/s², + towards the
    /// car's right.
    public var lateralAccelerationMps2: Double
    public var activity: Activity

    public var isStationary: Bool { speedMps == 0 }
}

// MARK: - Speed profile

/// Speed along the path as a function of lap time.
///
/// First the fastest profile within the path's speed limits and the nominal
/// acceleration and deceleration, stopped at the lap start, the junction
/// stop and the lap end (constant acceleration between breakpoints). Then
/// its position is averaged over a sliding window of `smoothingWindowS`,
/// exactly (closed form): speed, acceleration and jerk are the window
/// differences of position, speed and acceleration, so they stay mutually
/// consistent; speed stays ≥ 0 and is exactly 0 wherever the window is
/// inside a stop; acceleration is continuous, never above the nominal
/// values, and jerk is at most (acceleration + deceleration) / window.
/// Stops are planned one window longer, so the smoothed car is stationary
/// for exactly `startDwellS` and `stopDwellS`, and lap time 0 is the start
/// of the stationary start.
struct DemoSpeedProfile: Sendable {
    /// A raw phase of constant acceleration (v0 → v1 over `duration`).
    struct Phase: Hashable, Sendable {
        var t0: Double
        var duration: Double
        var s0: Double
        var v0: Double
        var v1: Double
        /// ∫ s dt over the raw lap up to `t0`.
        var integral0: Double
    }

    let phases: [Phase]
    let period: Double
    let length: Double
    /// ∫ s dt over one raw lap.
    let lapIntegral: Double
    let window: Double
    /// The smoothed car's stationary intervals, lap time.
    let stationary: [(range: ClosedRange<Double>, activity: DemoDriveState.Activity)]

    init(path: DemoPath, parameters: DemoDriveParameters) {
        let a = parameters.accelerationMps2, d = parameters.decelerationMps2
        let window = parameters.smoothingWindowS
        // Intervals: one per path piece, the one holding the stop split there.
        var bounds: [Double] = []
        var caps: [Double] = []
        for p in path.pieces {
            bounds.append(p.s0); caps.append(p.speedLimit)
            if path.stopS > p.s0 + 1e-9, path.stopS < p.s0 + p.length - 1e-9 {
                bounds.append(path.stopS); caps.append(p.speedLimit)
            }
        }
        bounds.append(path.length)
        let count = caps.count
        let isStop = bounds.map { abs($0 - path.stopS) < 1e-9 }
        // Speed limit at each boundary, then forward and backward passes.
        var limit = [Double](repeating: 0, count: count + 1)
        for i in 1..<count where !isStop[i] { limit[i] = min(caps[i - 1], caps[i]) }
        var forward = limit, backward = limit
        for i in 0..<count {
            let l = bounds[i + 1] - bounds[i]
            forward[i + 1] = min(limit[i + 1], (forward[i] * forward[i] + 2 * a * l).squareRoot())
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            let l = bounds[i + 1] - bounds[i]
            backward[i] = min(limit[i], (backward[i + 1] * backward[i + 1] + 2 * d * l).squareRoot())
        }
        let v = zip(forward, backward).map { min($0, $1) }

        // Pieces of constant acceleration: within an interval, speed up from
        // its start, cruise at its limit, slow down to its end.
        var raw: [(s0: Double, s1: Double, v0: Double, v1: Double)] = []
        func add(_ s0: Double, _ s1: Double, _ v0: Double, _ v1: Double) {
            if s1 - s0 > 1e-9 { raw.append((s0, s1, v0, v1)) }
        }
        for i in 0..<count {
            let s0 = bounds[i], l = bounds[i + 1] - s0, c = caps[i]
            let va = v[i], vb = v[i + 1]
            let x1 = (c * c - va * va) / (2 * a)
            let x2 = l - (c * c - vb * vb) / (2 * d)
            if x1 <= x2 {
                add(s0, s0 + x1, va, c)
                add(s0 + x1, s0 + x2, c, c)
                add(s0 + x2, s0 + l, c, vb)
            } else {
                let x = min(max((vb * vb + 2 * d * l - va * va) / (2 * (a + d)), 0), l)
                let peak = (va * va + 2 * a * x).squareRoot()
                add(s0, s0 + x, va, peak)
                add(s0 + x, s0 + l, peak, vb)
            }
        }

        // Timing, with each stop one window longer.
        var phases: [Phase] = []
        var t = 0.0, integral = 0.0
        func append(_ duration: Double, _ s0: Double, _ v0: Double, _ v1: Double) {
            let p = Phase(t0: t, duration: duration, s0: s0, v0: v0, v1: v1, integral0: integral)
            phases.append(p)
            integral = Self.integral(p, at: duration)
            t += duration
        }
        var stationary: [(ClosedRange<Double>, DemoDriveState.Activity)] = [(0...parameters.startDwellS, .startStop)]
        append(parameters.startDwellS + window, 0, 0, 0)
        for r in raw {
            append(2 * (r.s1 - r.s0) / (r.v0 + r.v1), r.s0, r.v0, r.v1)
            if abs(r.s1 - path.stopS) < 1e-9 {
                stationary.append((t...(t + parameters.stopDwellS), .junctionStop))
                append(parameters.stopDwellS + window, path.stopS, 0, 0)
            }
        }
        self.phases = phases
        period = t
        length = path.length
        lapIntegral = integral
        self.window = window
        self.stationary = stationary
    }

    /// ∫ s dt over the raw lap from 0 to `phase.t0 + tau`.
    static func integral(_ p: Phase, at tau: Double) -> Double {
        let acceleration = p.duration > 0 ? (p.v1 - p.v0) / p.duration : 0
        return p.integral0 + p.s0 * tau + p.v0 * tau * tau / 2 + acceleration * tau * tau * tau / 6
    }

    /// The raw profile at raw time `t` ∈ [−period, 2·period): position
    /// unwrapped across the lap boundary (+length per lap), speed,
    /// acceleration and ∫₀ᵗ s dt of the unwrapped position.
    func raw(at t: Double) -> (s: Double, v: Double, a: Double, integral: Double) {
        let lap = t < 0 ? -1.0 : (t >= period ? 1.0 : 0.0)
        let tl = min(max(t - lap * period, 0), period)
        var lo = 0, hi = phases.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if phases[mid].t0 <= tl { lo = mid } else { hi = mid - 1 }
        }
        let p = phases[lo]
        let tau = min(max(tl - p.t0, 0), p.duration)
        let acceleration = p.duration > 0 ? (p.v1 - p.v0) / p.duration : 0
        let s = p.s0 + p.v0 * tau + acceleration * tau * tau / 2
        let speed = max(0, p.v0 + acceleration * tau)
        let phi = Self.integral(p, at: tau)
        // ∫₀ᵗ of the unwrapped position.
        let integral: Double
        if lap == 0 {
            integral = phi
        } else if lap > 0 {
            integral = lapIntegral + phi + length * tl
        } else {
            integral = -((lapIntegral - phi) - length * (period - tl))
        }
        return (s + lap * length, speed, acceleration, integral)
    }

    /// Smoothed arc length, speed, acceleration and jerk at `lapTime` ∈
    /// [0, period).
    func motion(at lapTime: Double) -> (s: Double, v: Double, a: Double, jerk: Double, activity: DemoDriveState.Activity) {
        let h = window / 2
        let centre = lapTime + h
        let early = raw(at: centre - h), late = raw(at: centre + h)
        let s = (late.integral - early.integral) / window
        let speed = max(0, (late.s - early.s) / window)
        let acceleration = (late.v - early.v) / window
        let jerk = (late.a - early.a) / window
        let activity = stationary.first { $0.range.contains(lapTime) }?.activity ?? .driving
        return (min(max(s, 0), length), speed, acceleration, jerk, activity)
    }
}
