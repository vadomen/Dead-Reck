import Foundation
import Testing

@testable import DriveLoggerCore

/// Review run 14, round 3 (R14.3-1): the app writes a double-tap manual fix
/// when its 3 s undo window closes, with `t` = the tap, so the live engine
/// ingests it about 3 s late. Synthetic drives around (0, 0), no GPS.
@Suite("Navigation late manual fix (R14.3-1)")
struct NavigationLatePinTests {
    typealias S = SyntheticDrive

    static func pin(at t: Double, east: Double, north: Double, span: Double = 300) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t), mapSpanM: span, speedSource: "obd")))
    }

    /// `inputs` with the manual fix at `t` moved to arrive `delay` seconds
    /// later: after every input arriving at or before t + delay, as the
    /// app's tap delivers the row when the undo window closes.
    static func delayingPin(_ inputs: [NavigationInput], at t: Double, by delay: Double) -> [NavigationInput] {
        var rest = inputs
        guard let k = rest.firstIndex(where: {
            if case .manualFix(_, let ts) = $0 { return ts == S.ms(t) }
            return false
        }) else { return inputs }
        let pin = rest.remove(at: k)
        let at = rest.firstIndex { $0.arrival > S.ms(t + delay) } ?? rest.count
        rest.insert(pin, at: at)
        return rest
    }

    /// Runs `inputs` and returns the engine's estimate at `t`, from the
    /// state before the first input arriving after `t`.
    static func estimate(_ inputs: [NavigationInput], config: NavigationConfig, at t: Double)
        -> (estimate: NavigationEstimate?, engine: NavigationEngine) {
        var engine = NavigationEngine(config: config)
        var out: NavigationEstimate?
        for input in inputs {
            if out == nil, input.arrival > S.ms(t) { out = engine.estimate(at: S.ms(t)) }
            engine.ingest(input)
        }
        return (out ?? engine.estimate(at: S.ms(t)), engine)
    }

    /// Initialised by a pin at 20 s (heading unknown: a ring-shaped cloud),
    /// then 60 s at `speed` with a 60° right turn; a second pin at the
    /// truth at 80 s. Light gyro noise, OBD speed truncated, no GPS.
    static func drive(speed v: Double) -> (drive: SyntheticDrive, inputs: [NavigationInput]) {
        let drive = S(initialHeadingDeg: 70, initialSpeed: v, [
            .straight(seconds: 30, speed: v), .turn(degrees: 60, seconds: 10, speed: v), .straight(seconds: 60, speed: v),
        ])
        let a = drive.truth(at: 20), b = drive.truth(at: 80)
        let events = drive.events(gyroNoise: 0.002, extra: [
            Self.pin(at: 20, east: a.east, north: a.north), Self.pin(at: 80, east: b.east, north: b.north),
        ])
        return (drive, S.inputs(events))
    }

    static func distance(_ a: NavigationEstimate, _ b: NavigationEstimate) -> Double {
        let p = S.plane.enu(latitude: a.latitude, longitude: a.longitude)
        let q = S.plane.enu(latitude: b.latitude, longitude: b.longitude)
        return ((p.east - q.east) * (p.east - q.east) + (p.north - q.north) * (p.north - q.north)).squareRoot()
    }

    // MARK: Late pin, heading unknown

    /// Delay 3 s: the app's undo window. Delay 0.1 s: exactly one grid
    /// step late (R14.4-2) — the pin arrives right after the step at
    /// floor(t) + 1 step has run, the smallest delay that is late. A late
    /// test of "more than one step past floor(t)" would take it for an
    /// arrival-order pin and shift it by the mean motion (≤ 2.5 m at 25 m/s).
    @Test("A pin 3 s or one grid step late while heading is unknown lands where it lands in arrival order (8, 15, 25 m/s)",
          arguments: [8.0, 15.0, 25.0], [3.0, 0.1])
    func latePinMatchesArrivalOrder(speed: Double, delay: Double) throws {
        let (drive, inputs) = Self.drive(speed: speed)
        let config = S.config(particles: 2000, seed: 1)
        let inOrder = Self.estimate(inputs, config: config, at: 83.5)
        let late = Self.estimate(Self.delayingPin(inputs, at: 80, by: delay), config: config, at: 83.5)
        let a = try #require(inOrder.estimate), b = try #require(late.estimate)
        #expect(inOrder.engine.counters.lateManualFixes == 0)
        #expect(late.engine.counters.lateManualFixes == 1 && late.engine.counters.lateManualFixesMeanShift == 0,
                "pin \(delay) s late at \(speed) m/s")
        let gap = Self.distance(a, b)
        #expect(gap < 3, "pin \(delay) s late: \(gap) m from arrival order at \(speed) m/s (errors: in order \(drive.error(a, at: 83.5)) m, late \(drive.error(b, at: 83.5)) m)")
        #expect(drive.error(b, at: 83.5) < drive.error(a, at: 83.5) + 3)
        #expect(abs(angleDifference(b.headingDeg, a.headingDeg)) < 2)
    }

    // MARK: Late initialising pin

    @Test("A late pin that initialises the engine keeps the truth inside its 95 % ellipse (8, 15, 25 m/s)",
          arguments: [8.0, 15.0, 25.0])
    func lateInitialisingPinCoversTruth(speed: Double) throws {
        let (drive, inputs) = Self.drive(speed: speed)
        let config = S.config(particles: 2000, seed: 1)
        let late = Self.estimate(Self.delayingPin(inputs, at: 20, by: 3), config: config, at: 23.5)
        let inOrder = Self.estimate(inputs, config: config, at: 23.5)
        let e = try #require(late.estimate), a = try #require(inOrder.estimate)
        let offset = drive.offset(e, at: 23.5)
        #expect(late.engine.counters.lateManualFixes == 1)
        #expect(e.ellipse.contains(dEast: offset.dEast, dNorth: offset.dNorth),
                "truth \(drive.error(e, at: 23.5)) m from the estimate, 95 % ellipse \(e.ellipse.semiMajorM) × \(e.ellipse.semiMinorM) m at \(speed) m/s")
        // The same belief as a pin that arrived at the tap.
        #expect(Self.distance(e, a) < 1, "\(Self.distance(e, a)) m from arrival order")
        #expect(abs(e.ellipse.semiMajorM - a.ellipse.semiMajorM) < 0.05 * a.ellipse.semiMajorM)
    }

    // MARK: Older than the ring

    @Test("A pin older than the per-particle ring: own motion over the ring plus the mean motion before it")
    func pinOlderThanRingUsesMeanShiftForTheRest() throws {
        // 2 s ring, pin 4 s late, after the cloud has converged on clean
        // fixes (so the mean motion is the motion): the 2 s before the ring
        // come from the mean shift. Without it the pin lands 2 s × v behind.
        let v = 15.0
        let drive = S(initialHeadingDeg: 40, initialSpeed: v, [.straight(seconds: 70, speed: v)])
        let clean = S.cleanFix()
        let tPin = 60.0, end = drive.truth(at: tPin)
        let events = drive.events(fix: { t, state, rng in t < 40 ? clean(t, state, &rng) : nil },
                                  extra: [Self.pin(at: tPin, east: end.east + 25, north: end.north)])
        var config = S.config(particles: 400, seed: 2)
        config.lateManualFixWindowS = 2
        let inputs = S.inputs(events)
        let inOrder = Self.estimate(inputs, config: config, at: 64.5)
        let late = Self.estimate(Self.delayingPin(inputs, at: tPin, by: 4), config: config, at: 64.5)
        let a = try #require(inOrder.estimate), b = try #require(late.estimate)
        #expect(late.engine.counters.lateManualFixes == 1 && late.engine.counters.lateManualFixesMeanShift == 1)
        #expect(Self.distance(a, b) < 2, "\(Self.distance(a, b)) m from arrival order")
    }

    @Test("lateManualFixWindowS 0 restores the mean shift; the window is clamped and sizes the mean history too")
    func windowZeroAndClamp() throws {
        var config = NavigationConfig()
        #expect(config.lateManualFixWindowS == 5)
        config.lateManualFixWindowS = .infinity
        #expect(config.validated().lateManualFixWindowS == 5)
        config.lateManualFixWindowS = 1e6
        #expect(config.validated().lateManualFixWindowS == NavigationConfig.maxLateManualFixWindowS)
        config.lateManualFixWindowS = -1
        #expect(config.validated().lateManualFixWindowS == 0)

        let (_, inputs) = Self.drive(speed: 15)
        var off = S.config(particles: 400, seed: 1)
        off.lateManualFixWindowS = 0
        let late = Self.estimate(Self.delayingPin(inputs, at: 80, by: 3), config: off, at: 83.5)
        #expect(late.engine.counters.lateManualFixes == 0)
        #expect(late.engine.motionRing.capacity == 0)
        // R14.3-5: the ring and the mean history are both at least the window.
        var long = S.config(particles: 10)
        long.maxFixAgeS = 2
        long.lateManualFixWindowS = 5
        #expect(NavigationEngine(config: long).motionRing.capacity == 51)
    }

    // MARK: Ring consistency

    /// Each particle's motion since `t` according to the ring.
    static func ringMotion(_ engine: NavigationEngine, since t: Double) throws -> (east: [Double], north: [Double]) {
        try #require(engine.lateMotion(since: S.ms(t).nanoseconds, meanShift: (0, 0)))
    }

    /// Pure dead reckoning from 10 s (clean fixes before), 15 m/s with a
    /// slow right turn: no update runs after 10 s, so a particle's motion
    /// since `t` is exactly its displacement since `t`.
    static func deadReckoning(config: NavigationConfig, speed v: Double = 15)
        -> (drive: SyntheticDrive, inputs: [NavigationInput]) {
        let drive = S(initialHeadingDeg: 50, initialSpeed: v, [.straight(seconds: 10, speed: v),
                                                               .turn(degrees: 90, seconds: 60, speed: v)])
        let clean = S.cleanFix()
        let events = drive.events(gyroNoise: 0.002, fix: { t, state, rng in t < 9.5 ? clean(t, state, &rng) : nil })
        return (drive, S.inputs(events))
    }

    @Test("The ring follows a resample in the window: each new particle carries its ancestor's motion since t")
    func ringFollowsResample() throws {
        let config = S.config(particles: 500, seed: 4)
        let (_, inputs) = Self.deadReckoning(config: config)
        var engine = NavigationEngine(config: config)
        var atTap: (east: [Double], north: [Double])?
        var rest = inputs[...]
        while let input = rest.first, input.arrival <= S.ms(32) {
            engine.ingest(input)
            rest = rest.dropFirst()
            if atTap == nil && input.arrival >= S.ms(30) { atTap = (engine.east, engine.north) }
        }
        let tap = try #require(atTap)
        let tapT = 30.0
        // Skew the weights so systematic resampling duplicates and drops.
        let before = (engine.east, engine.north)
        for i in engine.logWeight.indices { engine.logWeight[i] = -0.01 * Double(i) }
        engine.normalizeWeights()
        engine.resampleIfNeeded()
        #expect(engine.counters.resamples >= 1)
        var ancestor = [Int](repeating: -1, count: engine.east.count)
        for i in engine.east.indices {
            ancestor[i] = before.0.indices.first { before.0[$0] == engine.east[i] && before.1[$0] == engine.north[i] } ?? -1
        }
        #expect(!ancestor.contains(-1))
        #expect(Set(ancestor).count < ancestor.count, "the resample should duplicate particles")
        // Two more seconds of prediction after the resample, still in the window.
        while let input = rest.first, input.arrival <= S.ms(34) {
            engine.ingest(input)
            rest = rest.dropFirst()
        }
        let motion = try Self.ringMotion(engine, since: tapT)
        var worst = 0.0
        for i in engine.east.indices {
            let k = ancestor[i]
            let de = engine.east[i] - tap.east[k], dn = engine.north[i] - tap.north[k]
            worst = max(worst, abs(motion.east[i] - de), abs(motion.north[i] - dn))
        }
        #expect(worst < 1e-6, "ring vs displacement since t: \(worst) m")
        #expect(engine.counters.manualFixes == 0 && engine.counters.fixesUsed > 0)
    }

    @Test("The ring follows a re-anchor in the window: motion since t equals the displacement in the new plane")
    func ringFollowsReanchor() throws {
        // Anchored by a parked fix at latitude 60°; a pin 100 km east resets
        // the cloud there (heading unknown: every particle moves its own
        // way); then 20 m/s with no further update. The first 10 s check
        // re-anchors, and the old→new map rotates by about Δλ·sin φ ≈ 1.4°,
        // so motion left in the old plane's axes would be off by metres.
        let lat0 = 60.0, lon0 = 10.0
        let phi = lat0 * .pi / 180
        let a = 6_378_137.0, e2 = 6.694_379_990_14e-3
        let lon1 = lon0 + 100_000 / (a / (1 - e2 * sin(phi) * sin(phi)).squareRoot() * cos(phi)) * 180 / .pi
        var inputs: [NavigationInput] = []
        func obd(_ t: Double, _ kmh: Double) {
            inputs.append(.obd(OBDSample(pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t)))
        }
        for k in 0..<20 { obd(Double(k) * 0.1, 0) }
        inputs.append(.location(LocationSample(latitude: lat0, longitude: lon0, altitude: 0, horizontalAccuracy: 5,
                                               verticalAccuracy: -1, speed: 0, speedAccuracy: 0.3, course: -1,
                                               courseAccuracy: -1, receivedT: S.ms(0.06), ageS: 0), at: S.ms(0.06)))
        inputs.append(.manualFix(ManualFixSample(latitude: lat0, longitude: lon1, pressedT: S.ms(1.005),
                                                 speedSource: "obd"), at: S.ms(1.005)))
        var t = 0.0
        while t < 40 {
            t += 0.01
            inputs.append(.motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                                               rotationRate: Vector3(x: 0, y: 0, z: -0.01), attitude: .identity),
                                  at: S.ms(t)))
            if t > 2, Int((t * 100).rounded()) % 10 == 0 { obd(t, 72) }
        }
        let ordered = inputs.enumerated().sorted { ($0.element.arrival, $0.offset) < ($1.element.arrival, $1.offset) }
            .map(\.element)
        var engine = NavigationEngine(config: S.config(particles: 300, seed: 5))
        var snapshots: [(t: Double, lat: [Double], lon: [Double])] = []
        var reanchoredAt: Double?
        var nextSecond = 3.0
        for input in ordered {
            let reanchors = engine.counters.reanchors
            engine.ingest(input)
            if reanchoredAt == nil, engine.counters.reanchors > reanchors { reanchoredAt = input.arrival.seconds }
            if let r = reanchoredAt, input.arrival.seconds > r + 1 { break }
            if reanchoredAt == nil, input.arrival.seconds >= nextSecond, let plane = engine.tangentPlane {
                let points = engine.east.indices.map { plane.geodetic(east: engine.east[$0], north: engine.north[$0]) }
                snapshots.append((nextSecond, points.map(\.latitude), points.map(\.longitude)))
                if snapshots.count > 3 { snapshots.removeFirst() }
                nextSecond += 1
            }
        }
        let r = try #require(reanchoredAt, "no re-anchor")
        let snapshot = try #require(snapshots.first)
        #expect(r - snapshot.t > 1 && r + 1 - snapshot.t < 5, "tap \(snapshot.t) s, re-anchor \(r) s")
        #expect(engine.counters.manualResets == 1 && engine.counters.fixesUsed == 1)
        let plane = try #require(engine.tangentPlane)
        let motion = try Self.ringMotion(engine, since: snapshot.t)
        var worst = 0.0, largest = 0.0
        for i in engine.east.indices {
            let then = plane.enu(latitude: snapshot.lat[i], longitude: snapshot.lon[i])
            let de = engine.east[i] - then.east, dn = engine.north[i] - then.north
            worst = max(worst, abs(motion.east[i] - de), abs(motion.north[i] - dn))
            largest = max(largest, (de * de + dn * dn).squareRoot())
        }
        #expect(largest > 50, "particles moved \(largest) m since the tap")
        // Exact apart from the Jacobian's linearisation (well under 1 cm).
        #expect(worst < 0.01, "ring vs displacement since t across a re-anchor: \(worst) m")
    }

    @Test("A reseed in the window: a reseeded particle's motion since t is along its own heading, not the cloud's mean")
    func ringAcrossReseed() throws {
        // Initialised by a pin (heading unknown: a ring); one clean fix at
        // 20 s reseeds half the cloud around its course. Straight at 15 m/s
        // with no gyro noise: every particle's motion since 18.5 s is its
        // scale × the OBD distance along its own heading. A reseeded
        // particle given the cloud's mean motion (≈ 0 for a ring) or the
        // ring entries of the particle it replaced would be metres off.
        let v = 15.0
        let drive = S(initialHeadingDeg: 70, initialSpeed: v, [.straight(seconds: 30, speed: v)])
        let clean = S.cleanFix()
        let events = drive.events(fix: { t, state, rng in S.at(t, 20) ? clean(t, state, &rng) : nil },
                                  extra: [Self.pin(at: 0.005, east: 0, north: 0)])
        var engine = NavigationEngine(config: S.config(particles: 600, seed: 6))
        for input in S.inputs(events) where input.arrival <= S.ms(21.5) { engine.ingest(input) }
        #expect(engine.counters.reseeds == 1)
        let motion = try Self.ringMotion(engine, since: 18.5)
        // OBD 54 km/h + 0.5 offset, over 18.5 → 21.5 s on the grid.
        let obdDistance = 54.5 / 3.6 * 3.0
        var worst = 0.0
        for i in engine.east.indices {
            let expected = (obdDistance * engine.scale[i] * sin(engine.heading[i]),
                            obdDistance * engine.scale[i] * cos(engine.heading[i]))
            worst = max(worst, ((motion.east[i] - expected.0) * (motion.east[i] - expected.0)
                                + (motion.north[i] - expected.1) * (motion.north[i] - expected.1)).squareRoot())
        }
        // Heading jitter (resample 0.2°, random walk) over 45 m: < 0.5 m.
        #expect(worst < 0.5, "motion since t off by up to \(worst) m from the particle's own heading")
    }

    @Test("A parked stretch folded in the catch-up leaves the same ring as stepping it")
    func ringAcrossParkedFold() throws {
        let gap = NavigationB0Tests.parkedGap(true), control = NavigationB0Tests.parkedGap(false)
        #expect(gap.catchUp.coalescedSteps > 5_000)
        let a = gap.engine.motionRing.chronological(), b = control.engine.motionRing.chronological()
        #expect(a.count == gap.engine.motionRing.capacity)
        #expect(a.map(\.t) == b.map(\.t))
        #expect(zip(a, b).allSatisfy { $0.east == $1.east && $0.north == $1.north })
    }
}
