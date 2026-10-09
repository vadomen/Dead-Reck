import Foundation
import Testing

@testable import DriveLoggerCore

/// A scripted synthetic drive in local metres around (0, 0), rendered as the
/// log events a recording would hold: 100 Hz motion, 10 Hz OBD speed
/// (truncated to whole km/h, ECU 7E8) and location fixes from a pluggable
/// generator. No real place, date or recording is involved.
struct SyntheticDrive {
    /// One piece of the script. Speeds in m/s; yaw rate positive clockwise.
    enum Segment {
        /// Constant speed, straight.
        case straight(seconds: Double, speed: Double)
        /// Constant speed, turning `degrees` (positive = right) over `seconds`.
        case turn(degrees: Double, seconds: Double, speed: Double)
        /// Linear speed change, straight.
        case ramp(seconds: Double, from: Double, to: Double)
        /// Standing still.
        case stop(seconds: Double)
    }

    struct State {
        var t: Double
        var east: Double
        var north: Double
        /// Radians, clockwise from north.
        var heading: Double
        var speed: Double
        var yawRate: Double
        /// Longitudinal acceleration, m/s².
        var accel: Double = 0
    }

    /// What the fix generator returns for one 1 Hz tick.
    struct Fix {
        var east: Double
        var north: Double
        var accuracy: Double
        var speed: Double = -1
        var speedAccuracy: Double = -1
        var course: Double = -1
        var courseAccuracy: Double = -1
        /// Fix-to-arrival latency, s.
        var latency: Double = 0.05
    }

    static let plane = LocalTangentPlane(latitude: 0, longitude: 0)
    static let motionDt = 0.01

    let initialHeadingDeg: Double
    let segments: [Segment]
    private(set) var states: [State] = []

    init(initialHeadingDeg: Double = 0, initialSpeed: Double = 0, _ segments: [Segment]) {
        self.initialHeadingDeg = initialHeadingDeg
        self.segments = segments
        var state = State(t: 0, east: 0, north: 0,
                          heading: initialHeadingDeg * .pi / 180, speed: initialSpeed, yawRate: 0)
        states.append(state)
        let dt = Self.motionDt
        for segment in segments {
            let (duration, speedAt, yawRate): (Double, (Double) -> Double, Double) = {
                switch segment {
                case .straight(let s, let v): return (s, { _ in v }, 0)
                case .turn(let deg, let s, let v): return (s, { _ in v }, deg * .pi / 180 / s)
                case .ramp(let s, let a, let b): return (s, { a + (b - a) * $0 / s }, 0)
                case .stop(let s): return (s, { _ in 0 }, 0)
                }
            }()
            let steps = Int((duration / dt).rounded())
            let start = state.t
            for k in 1...max(1, steps) {
                let local = Double(k) * dt
                let v = speedAt(local)
                let midHeading = state.heading + 0.5 * yawRate * dt
                state.east += v * dt * sin(midHeading)
                state.north += v * dt * cos(midHeading)
                state.heading += yawRate * dt
                state.accel = (v - state.speed) / dt
                state.speed = v
                state.yawRate = yawRate
                state.t = start + local
                states.append(state)
            }
        }
    }

    var duration: Double { states.last?.t ?? 0 }

    /// Whether `t` is the 1 Hz tick at `second`.
    static func at(_ t: Double, _ second: Double) -> Bool { abs(t - second) < motionDt / 2 }

    /// Truth at `t` (nearest 10 ms sample).
    func truth(at t: Double) -> State {
        let index = min(states.count - 1, max(0, Int((t / Self.motionDt).rounded())))
        return states[index]
    }

    static func ms(_ seconds: Double) -> MonotonicTimestamp { MonotonicTimestamp(seconds: seconds) }

    /// The drive as log events (file order: by arrival, as a recorder writes).
    ///
    /// - gyroNoise: white noise on the yaw rate, rad/s (seeded).
    /// - accelNoise: white noise on each horizontal userAcceleration axis, g.
    ///   userAcceleration otherwise carries the scripted longitudinal
    ///   acceleration on the device y axis (device flat, y forward).
    /// - obdSpeed: OBD value (km/h) at a time, or nil for "no reply"; default
    ///   is the true speed truncated to whole km/h.
    /// - fix: the 1 Hz location generator; nil for no fix.
    func events(
        seed: UInt64 = 7,
        gyroNoise: Double = 0,
        accelNoise: Double = 0,
        obdSpeed: ((Double, State) -> Double?)? = nil,
        fixEvery: Double = 1,
        fix: (Double, State, inout NavigationRandom) -> Fix? = { _, _, _ in nil },
        extra: [LogEvent] = []
    ) -> [LogEvent] {
        var rng = NavigationRandom(seed: seed)
        var events: [LogEvent] = []
        let obdEvery = 10
        let fixEveryIndex = Int((fixEvery / Self.motionDt).rounded())
        for (index, state) in states.enumerated() {
            let t = state.t
            let rate = state.yawRate + gyroNoise * rng.nextGaussian()
            let ax = accelNoise > 0 ? accelNoise * rng.nextGaussian() : 0
            let ay = state.accel / 9.806_65 + (accelNoise > 0 ? accelNoise * rng.nextGaussian() : 0)
            events.append(.motion(MotionSample(
                userAcceleration: Vector3(x: ax, y: ay, z: 0),
                gravity: Vector3(x: 0, y: 0, z: -1),
                // rotationRate · ĝ with ĝ = (0, 0, −1) is −z: clockwise yaw.
                rotationRate: Vector3(x: 0, y: 0, z: -rate),
                attitude: .identity
            ), at: Self.ms(t)))
            if index % obdEvery == 5 {
                let value = obdSpeed.map { $0(t, state) } ?? (state.speed * 3.6).rounded(.down)
                if let value {
                    events.append(.obd(OBDSample(pid: .vehicleSpeed, value: value, unit: .kilometersPerHour,
                                                 ecu: "7E8"), at: Self.ms(t)))
                }
            }
            if index % fixEveryIndex == 0, let f = fix(t, state, &rng) {
                let p = Self.plane.geodetic(east: f.east, north: f.north)
                let sample = LocationSample(
                    latitude: p.latitude, longitude: p.longitude, altitude: 0,
                    horizontalAccuracy: f.accuracy, verticalAccuracy: -1,
                    speed: f.speed, speedAccuracy: f.speedAccuracy,
                    course: f.course, courseAccuracy: f.courseAccuracy,
                    receivedT: Self.ms(t + f.latency), ageS: f.latency
                )
                events.append(.location(sample, at: Self.ms(t)))
            }
        }
        // A recorder writes in arrival order; keep that, it is what the
        // replay re-sorts anyway.
        return (events + extra).sorted { NavigationInput($0)!.arrival < NavigationInput($1)!.arrival }
    }

    /// A clean GNSS fix of the truth, with seeded position noise.
    static func cleanFix(accuracy: Double = 5, positionNoise: Double = 2, courseOffsetDeg: Double = 0)
        -> (Double, State, inout NavigationRandom) -> Fix? {
        { _, state, rng in
            var course = (state.heading * 180 / .pi + courseOffsetDeg).truncatingRemainder(dividingBy: 360)
            if course < 0 { course += 360 }
            return Fix(
                east: state.east + positionNoise * rng.nextGaussian(),
                north: state.north + positionNoise * rng.nextGaussian(),
                accuracy: accuracy,
                speed: state.speed, speedAccuracy: 0.3,
                course: state.speed > 0.5 ? course : -1, courseAccuracy: state.speed > 0.5 ? 2 : -1
            )
        }
    }

    /// The engine's config for tests: fewer particles keep debug runs fast.
    static func config(particles: Int = 400, seed: UInt64 = 1) -> NavigationConfig {
        var config = NavigationConfig()
        config.particleCount = particles
        config.seed = seed
        return config
    }

    /// Navigation inputs in arrival order, ties in file order (what
    /// `NavigationReplay.inputs(from:)` does for a real recording).
    static func inputs(_ events: [LogEvent]) -> [NavigationInput] {
        events.compactMap(NavigationInput.init).enumerated()
            .sorted { $0.element.arrival != $1.element.arrival ? $0.element.arrival < $1.element.arrival : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Runs `events` through a fresh engine, returning it and the estimate
    /// sampled at each `sampleTimes` entry (from the state before any input
    /// arriving after it).
    static func run(
        _ events: [LogEvent], config: NavigationConfig, sampleTimes: [Double] = []
    ) -> (engine: NavigationEngine, samples: [NavigationEstimate?]) {
        var engine = NavigationEngine(config: config)
        var samples: [NavigationEstimate?] = []
        var pending = sampleTimes.sorted()[...]
        for input in inputs(events) {
            while let next = pending.first, ms(next) < input.arrival {
                samples.append(engine.estimate(at: ms(next)))
                pending = pending.dropFirst()
            }
            engine.ingest(input)
        }
        for next in pending { samples.append(engine.estimate(at: ms(next))) }
        return (engine, samples)
    }

    /// Horizontal distance between an estimate and the truth, metres.
    func error(_ estimate: NavigationEstimate, at t: Double) -> Double {
        let truth = truth(at: t)
        let p = Self.plane.enu(latitude: estimate.latitude, longitude: estimate.longitude)
        return ((p.east - truth.east) * (p.east - truth.east) + (p.north - truth.north) * (p.north - truth.north)).squareRoot()
    }

    /// Truth relative to the estimate, in the estimate's own local plane.
    func offset(_ estimate: NavigationEstimate, at t: Double) -> (dEast: Double, dNorth: Double) {
        let truth = truth(at: t)
        let p = Self.plane.enu(latitude: estimate.latitude, longitude: estimate.longitude)
        return (truth.east - p.east, truth.north - p.north)
    }
}

/// Smallest signed difference a − b between two bearings, degrees.
func angleDifference(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
    return d
}
