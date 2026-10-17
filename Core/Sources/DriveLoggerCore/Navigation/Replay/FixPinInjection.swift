import Foundation

/// Sensitivity and specificity of the N3-FIXPIN arbiters by injection
/// (`replay_nav --fixpin-inject`; docs/NAVIGATION.md "Pin against a GNSS
/// source"). Replay only: a recording's own inputs are fed to an unchanged
/// `NavigationEngine`, with two kinds of edit, and the engine's own
/// `lastFixPinDecision` at the injected pin is the result.
///
/// - **Sensitivity:** every GNSS fix (valid speed, any source) with `t` in
///   [t0, t0 + window] is shifted by a constant vector; a pin at the
///   unshifted position (the genuine fixes interpolated at the pin's `t`)
///   is inserted at t0 + `preS`. Expected verdict: pin.
/// - **Specificity:** genuine fixes; a pin displaced from that position.
///   Expected verdict: fixes or none; pin is a false trigger.
/// - **Two pins** (for `fixPinTwoPinCheck`): a second pin at the first
///   time with enough OBD path and gyro turn after the first (both with
///   the same displacement under specificity, the worst case), the shift
///   window extended to cover it.
///
/// The engine is a value type: one run per configuration reaches each
/// case's t0 on the genuine inputs, and every case continues from a copy
/// of it, so a case is bit-identical to a full replay of the edited
/// recording up to its end. Nothing is written into a recording, and the
/// output carries only relative metres, bearings and session seconds.
public enum FixPinInjection {
    public struct Options: Hashable, Sendable {
        /// Sensitivity shifts and specificity displacements, metres.
        public var shiftsM: [Double] = [100, 200, 335, 500]
        public var displacementsM: [Double] = [30, 75, 150, 300]
        public var bearings = 8
        /// The pin is at t0 + `preS`; shifted fixes run to t0 + `windowS`.
        public var preS = 90.0
        public var windowS = 120.0
        /// Pin times per recording, at least `minSeparationS` apart.
        public var pinsPerLog = 6
        public var minSeparationS = 60.0
        /// Candidate grid, s.
        public var candidateStepS = 5.0
        /// A candidate needs, in [t − preS, t], this many genuine fixes of
        /// one GNSS source, this much fix path, and this many fixes inside
        /// pack coverage (margins over the arbiter's 20 fixes and 200 m).
        public var minRingFixes = 25
        public var minRingPathM = 250.0
        public var minCoveredFixes = 22
        /// The fixes bracketing the pin's `t` are at most this far apart,
        /// and at most this inaccurate (the clean-fix rule).
        public var maxBracketGapS = 3.0
        public var maxTruthAccuracyM = NavigationReplay.cleanFixTruthAccM
        /// No recorded pin within this many seconds before t0 or after the
        /// shift window ends.
        public var pinClearanceS = 30.0
        /// Second pin: OBD path and net gyro turn after the first, with
        /// margins over `fixPinTwoPinMinPathM` / `MinTurnDeg` (300 m, 45°),
        /// at least `twoPinMinGapS` and at most `twoPinMaxGapS` later.
        public var twoPinMinPathM = 330.0
        public var twoPinMinTurnDeg = 55.0
        public var twoPinMinGapS = 20.0
        public var twoPinMaxGapS = 300.0
        public var thirdPinAfterS = 60.0
        /// Road context of a pin time (`Context`).
        public var junctionRadiusM = 25.0
        public var junctionMinAngleDeg = 45.0
        public var parallelMinM = 15.0
        public var parallelMaxM = 80.0
        public var parallelMaxAngleDeg = 20.0
        /// The injected pin's map span (its σ as the engine derives it from
        /// a real pin), and `obd` speed at the tap from the recording.
        public var pinMapSpanM = 250.0

        public init() {}
    }

    /// Where a pin time lies on the road map, from the genuine position
    /// and course: a crossing or branching road within `junctionRadiusM`
    /// (junction), else a road alongside at `parallelMinM`–`parallelMaxM`
    /// (parallel), else straight.
    public enum Context: String, Hashable, Sendable, Codable, CaseIterable {
        case straight, junction, parallel
    }

    public struct PinTime: Hashable, Sendable, Codable {
        /// Pin `t`, session seconds; the second pin's, when one exists.
        public var t: Double
        public var secondT: Double?
        /// Two-pin sensitivity: a third genuine pin `thirdPinAfterS` after
        /// the second, for the prior after the verdict; nil without one.
        public var thirdT: Double? = nil
        public var context: Context
        /// Junction and parallel flags (a junction can also be parallel).
        public var junction: Bool
        public var parallel: Bool
        /// The source whose ring qualifies, its fixes and path in the ring.
        public var source: String
        public var ringFixes: Int
        public var ringPathM: Double
        public var speedMps: Double
    }

    public enum Kind: String, Hashable, Sendable, Codable {
        case sensitivity, specificity
    }

    public struct Case: Hashable, Sendable, Codable {
        public var kind: Kind
        /// Shift (sensitivity) or displacement (specificity), metres, and
        /// its bearing, degrees clockwise from north.
        public var magnitudeM: Double
        public var bearingDeg: Double
        public var twoPins: Bool
        /// Two-pin specificity, pin 2: displaced like pin 1 on the map (a
        /// user consistently mis-tapping; indistinguishable from a shifted
        /// source), displaced like pin 1 in the car's frame (turned by the
        /// net gyro heading change, e.g. a tapping lag), or at the genuine
        /// position. Sensitivity: always genuine.
        public var secondPin: SecondPin = .genuine
    }

    public enum SecondPin: String, Hashable, Sendable, Codable {
        case sameOnMap, sameInCarFrame, genuine
    }

    /// One case's outcome: the engine's decision at each injected pin,
    /// the prior error at the first (estimate before the pin against the
    /// genuine position) and the error at the end of the shift window.
    public struct Outcome: Hashable, Sendable, Codable {
        public var pin: PinTime
        public var `case`: Case
        public var decision: FixPinDecision?
        public var secondDecision: FixPinDecision?
        public var priorErrorM: Double?
        public var endErrorM: Double?
        /// Every injected pin's decision and prior error (estimate before
        /// it against the genuine position), in time order.
        public var decisions: [FixPinDecision?] = []
        public var priorErrorsM: [Double?] = []
    }

    // MARK: Genuine track

    struct GNSSFix {
        var t: Double
        var latitude: Double
        var longitude: Double
        var accuracyM: Double
        var speed: Double
        var course: Double?
        var source: FixPinSource.Kind
    }

    static func gnssFixes(_ inputs: [NavigationInput]) -> [GNSSFix] {
        inputs.compactMap { input -> GNSSFix? in
            guard case .location(let s, let t) = input, s.hasValidPosition, s.hasValidSpeed else { return nil }
            return GNSSFix(t: t.seconds, latitude: s.latitude, longitude: s.longitude, accuracyM: s.horizontalAccuracy,
                           speed: s.speed, course: s.hasValidCourse ? s.course : nil,
                           source: FixPinSource.Kind(accessory: s.accessory))
        }.sorted { $0.t < $1.t }
    }

    /// The genuine position at `t`: the bracketing fixes of `fixes` (one
    /// source, time order), linearly by `t`, if both are close and clean.
    static func position(at t: Double, in fixes: [GNSSFix], options: Options) -> (latitude: Double, longitude: Double)? {
        var lo = 0, hi = fixes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if fixes[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo < fixes.count, fixes[lo].t == t {
            return fixes[lo].accuracyM <= options.maxTruthAccuracyM ? (fixes[lo].latitude, fixes[lo].longitude) : nil
        }
        guard lo > 0, lo < fixes.count else { return nil }
        let a = fixes[lo - 1], b = fixes[lo]
        guard b.t - a.t <= options.maxBracketGapS, a.accuracyM <= options.maxTruthAccuracyM,
              b.accuracyM <= options.maxTruthAccuracyM else { return nil }
        let u = (t - a.t) / (b.t - a.t)
        return (a.latitude + u * (b.latitude - a.latitude), a.longitude + u * (b.longitude - a.longitude))
    }

    // MARK: Pin times

    /// Pin times for a recording: candidates on a `candidateStepS` grid
    /// that satisfy the ring, truth and clearance rules, classified by road
    /// context, then picked round-robin over the contexts (straight,
    /// junction, parallel), each time the qualifying candidate farthest in
    /// time from those already picked, at least `minSeparationS` apart.
    /// Deterministic. `excluded`: fix ranges that are never truth (the
    /// truth file's `excludeFixes`); no ring or window may touch one.
    public static func pinTimes(_ inputs: [NavigationInput], roads: RoadNetwork, options: Options = Options(),
                                excluded: [TruthFile.ExcludedFixRange] = []) -> [PinTime] {
        let all = gnssFixes(inputs)
        guard let first = all.first?.t, let last = all.last?.t else { return [] }
        let pins = inputs.compactMap { input -> Double? in
            guard case .manualFix(_, let t) = input else { return nil }
            return t.seconds
        }
        let obd = cumulativeOBD(inputs)
        let yaw = cumulativeYaw(inputs)
        func touchesExcluded(_ from: Double, _ to: Double) -> Bool {
            excluded.contains { $0.fromT <= to && $0.toT >= from }
        }
        func pinNear(_ from: Double, _ to: Double) -> Bool { pins.contains { $0 >= from && $0 <= to } }

        var candidates: [PinTime] = []
        var t = (first + options.preS).rounded(.up)
        while t <= last - (options.windowS - options.preS) {
            defer { t += options.candidateStepS }
            let t0 = t - options.preS, tEnd = t0 + options.windowS
            guard !touchesExcluded(t0, tEnd), !pinNear(t0 - options.pinClearanceS, tEnd + options.pinClearanceS) else { continue }
            var best: (kind: FixPinSource.Kind, fixes: [GNSSFix], path: Double)?
            for kind in FixPinSource.Kind.allCases {
                let ring = all.filter { $0.source == kind && $0.t >= t0 && $0.t <= t }
                guard ring.count >= options.minRingFixes else { continue }
                let path = Self.path(ring)
                guard path >= options.minRingPathM else { continue }
                if best == nil || ring.count > best!.fixes.count { best = (kind, ring, path) }
            }
            guard let best else { continue }
            let covered = best.fixes.filter { roads.covers(latitude: $0.latitude, longitude: $0.longitude) }.count
            guard covered >= options.minCoveredFixes else { continue }
            let sourceFixes = all.filter { $0.source == best.kind }
            guard let p = position(at: t, in: sourceFixes, options: options) else { continue }
            let near = sourceFixes.min { abs($0.t - t) < abs($1.t - t) }!
            let flags = context(latitude: p.latitude, longitude: p.longitude, course: near.course, speed: near.speed,
                                roads: roads, options: options)
            var secondT: Double?
            if let o0 = value(obd, at: t), let y0 = value(yaw, at: t) {
                var s = t + options.twoPinMinGapS
                while s <= min(t + options.twoPinMaxGapS, last) {
                    if let o = value(obd, at: s), let y = value(yaw, at: s), o - o0 >= options.twoPinMinPathM,
                       abs(y - y0) * 180 / .pi >= options.twoPinMinTurnDeg {
                        let end = s + (options.windowS - options.preS)
                        let ring2 = sourceFixes.filter { $0.t >= s - options.preS && $0.t <= s }
                        if position(at: s, in: sourceFixes, options: options) != nil, ring2.count >= options.minRingFixes / 2,
                           !touchesExcluded(t0, end), !pinNear(t0 - options.pinClearanceS, end + options.pinClearanceS) {
                            secondT = s
                        }
                        break
                    }
                    s += 1
                }
            }
            var thirdT: Double?
            if let s2 = secondT {
                let s3 = s2 + options.thirdPinAfterS
                let end = s3 + (options.windowS - options.preS)
                if end <= last, position(at: s3, in: sourceFixes, options: options) != nil,
                   !touchesExcluded(t0, end), !pinNear(t0 - options.pinClearanceS, end + options.pinClearanceS) {
                    thirdT = s3
                }
            }
            candidates.append(PinTime(
                t: t, secondT: secondT, thirdT: thirdT, context: flags.junction ? .junction : flags.parallel ? .parallel : .straight,
                junction: flags.junction, parallel: flags.parallel, source: best.kind.name, ringFixes: best.fixes.count,
                ringPathM: best.path, speedMps: near.speed))
        }

        var picked: [PinTime] = []
        var exhausted = Set<Context>()
        while picked.count < options.pinsPerLog && exhausted.count < Context.allCases.count {
            for context in Context.allCases where picked.count < options.pinsPerLog && !exhausted.contains(context) {
                let pool = candidates.filter { c in
                    c.context == context && picked.allSatisfy { abs($0.t - c.t) >= options.minSeparationS }
                }
                // Farthest from those picked (from the start of the drive when
                // none is): a deterministic spread; ties keep the earlier time.
                let choice = pool.max { a, b in
                    let da = picked.map { abs($0.t - a.t) }.min() ?? a.t - first
                    let db = picked.map { abs($0.t - b.t) }.min() ?? b.t - first
                    return da != db ? da < db : a.t > b.t
                }
                if let choice { picked.append(choice) } else { exhausted.insert(context) }
            }
        }
        return picked.sorted { $0.t < $1.t }
    }

    static func path(_ fixes: [GNSSFix]) -> Double {
        guard let first = fixes.first else { return 0 }
        let plane = LocalTangentPlane(latitude: first.latitude, longitude: first.longitude)
        var total = 0.0
        var previous: (east: Double, north: Double)?
        for f in fixes {
            let p = plane.enu(latitude: f.latitude, longitude: f.longitude)
            if let q = previous { total += ((p.east - q.east) * (p.east - q.east) + (p.north - q.north) * (p.north - q.north)).squareRoot() }
            previous = p
        }
        return total
    }

    /// Road context flags at a position with a course (degrees, nil when
    /// unknown: then only "parallel to the nearest road" can be judged and
    /// the nearest road's direction stands in for it).
    static func context(latitude: Double, longitude: Double, course: Double?, speed: Double, roads: RoadNetwork,
                        options: Options) -> (junction: Bool, parallel: Bool) {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        let field = RoadField(roads: roads, plane: plane, points: [(0, 0)], marginM: options.parallelMaxM + 20,
                              capM: options.parallelMaxM + 20)
        struct Near { var d: Double; var ux: Double; var uy: Double; var interior: Bool }
        let near: [Near] = field.segments.compactMap { s in
            guard s.length > 0 else { return nil }
            let n = RoadMatcher.nearest(px: 0, py: 0, ax: s.ax, ay: s.ay, ux: s.ux, uy: s.uy, length: s.length)
            let along = -(s.ax * s.ux + s.ay * s.uy)
            return Near(d: n.distanceSquared.squareRoot(), ux: s.ux, uy: s.uy, interior: along > 0 && along < s.length)
        }
        guard let nearest = near.min(by: { $0.d < $1.d }) else { return (false, false) }
        let direction: (Double, Double)
        if let c = course, speed >= 2 {
            direction = (sin(c * .pi / 180), cos(c * .pi / 180))
        } else {
            direction = (nearest.ux, nearest.uy)
        }
        func absCos(_ n: Near) -> Double { abs(n.ux * direction.0 + n.uy * direction.1) }
        let junctionCos = cos(options.junctionMinAngleDeg * .pi / 180)
        let parallelCos = cos(options.parallelMaxAngleDeg * .pi / 180)
        let junction = near.contains { $0.d <= options.junctionRadiusM && absCos($0) < junctionCos }
        let parallel = near.contains {
            $0.interior && $0.d >= max(options.parallelMinM, nearest.d + options.parallelMinM) && $0.d <= options.parallelMaxM
                && absCos($0) >= parallelCos
        }
        return (junction, parallel)
    }

    /// Cumulative OBD distance (primary ECU speed, held to the next reply,
    /// at most 2 s) and gyro yaw (gaps over 0.5 s add nothing), by `t`.
    static func cumulativeOBD(_ inputs: [NavigationInput]) -> [(t: Double, v: Double)] {
        var out: [(t: Double, v: Double)] = []
        var total = 0.0
        var previous: (t: Double, mps: Double)?
        for input in inputs {
            guard case .obd(let s, let t) = input, s.pid == .vehicleSpeed,
                  s.ecu == nil || s.ecu == NavigationEngine.primaryECU, s.value.isFinite, s.value >= 0 else { continue }
            if let p = previous { total += p.mps * min(2, max(0, t.seconds - p.t)) }
            previous = (t.seconds, s.value / 3.6)
            out.append((t.seconds, total))
        }
        return out
    }

    static func cumulativeYaw(_ inputs: [NavigationInput]) -> [(t: Double, v: Double)] {
        var out: [(t: Double, v: Double)] = []
        var total = 0.0
        var previous: (t: Double, rate: Double)?
        for input in inputs {
            guard case .motion(let m, let t) = input else { continue }
            let g = m.gravity
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            guard norm > 0.5 else { continue }
            let r = m.rotationRate
            let rate = -(r.x * g.x + r.y * g.y + r.z * g.z) / norm
            if let p = previous, t.seconds - p.t <= 0.5, t.seconds > p.t { total += p.rate * (t.seconds - p.t) }
            previous = (t.seconds, rate)
            out.append((t.seconds, total))
        }
        return out
    }

    /// The series value at the last sample at or before `t`.
    static func value(_ series: [(t: Double, v: Double)], at t: Double) -> Double? {
        var lo = 0, hi = series.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if series[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? series[lo - 1].v : nil
    }

    // MARK: Cases

    public static func cases(_ options: Options, twoPins: Bool) -> [Case] {
        var out: [Case] = []
        for (kind, magnitudes) in [(Kind.sensitivity, options.shiftsM), (.specificity, options.displacementsM)] {
            for m in magnitudes {
                for k in 0..<options.bearings {
                    let b = 360 * Double(k) / Double(options.bearings)
                    if twoPins && kind == .specificity {
                        for second in [SecondPin.sameOnMap, .sameInCarFrame, .genuine] {
                            out.append(Case(kind: kind, magnitudeM: m, bearingDeg: b, twoPins: true, secondPin: second))
                        }
                    } else {
                        out.append(Case(kind: kind, magnitudeM: m, bearingDeg: b, twoPins: twoPins))
                    }
                }
            }
        }
        return out
    }

    /// Runs every case at every pin time with one configuration: inputs in
    /// arrival order (`NavigationReplay.inputs`), all given to the engine
    /// (`--gps use`), roads from the first input. `twoPins` cases skip pin
    /// times without a second pin. `progress` gets each outcome.
    public static func run(inputs: [NavigationInput], config: NavigationConfig, roads: RoadNetwork?, pinTimes: [PinTime],
                           cases: [Case], options: Options = Options(), progress: (Outcome) -> Void = { _ in }) -> [Outcome] {
        let all = gnssFixes(inputs)
        var bySource: [FixPinSource.Kind: [GNSSFix]] = [:]
        for kind in FixPinSource.Kind.allCases { bySource[kind] = all.filter { $0.source == kind } }
        let obdKmh = obdSpeeds(inputs)
        let yaw = cumulativeYaw(inputs)
        var engine = NavigationEngine(config: config, roads: roads)
        var next = 0
        var outcomes: [Outcome] = []
        for pin in pinTimes.sorted(by: { $0.t < $1.t }) {
            let t0 = pin.t - options.preS
            let t0Ns = MonotonicTimestamp(seconds: t0).nanoseconds
            while next < inputs.count && inputs[next].arrival.nanoseconds < t0Ns {
                engine.ingest(inputs[next])
                next += 1
            }
            let kind: FixPinSource.Kind = pin.source == FixPinSource.Kind.accessory.name ? .accessory : .phone
            let truthFixes = bySource[kind] ?? []
            for c in cases {
                if c.twoPins && pin.secondT == nil { continue }
                let pinTs = Self.pinTs(pin, c)
                let tEnd = pinTs.last! + (options.windowS - options.preS)
                let outcome = runCase(engine: engine, inputs: inputs, from: next, t0: t0, tEnd: tEnd, pinTs: pinTs,
                                      pin: pin, case: c, truthFixes: truthFixes, obdKmh: obdKmh, yaw: yaw,
                                      options: options)
                progress(outcome)
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// The injected pins' times of a case: one, or two plus the third
    /// (sensitivity, when one exists).
    static func pinTs(_ pin: PinTime, _ c: Case) -> [Double] {
        guard c.twoPins, let second = pin.secondT else { return [pin.t] }
        if c.kind == .sensitivity, let third = pin.thirdT { return [pin.t, second, third] }
        return [pin.t, second]
    }

    static func obdSpeeds(_ inputs: [NavigationInput]) -> [(t: Double, v: Double)] {
        inputs.compactMap { input -> (t: Double, v: Double)? in
            guard case .obd(let s, let t) = input, s.pid == .vehicleSpeed,
                  s.ecu == nil || s.ecu == NavigationEngine.primaryECU, s.value.isFinite, s.value >= 0 else { return nil }
            return (t.seconds, s.value)
        }
    }

    static func shifted(latitude: Double, longitude: Double, magnitudeM: Double, bearingDeg: Double) -> (Double, Double) {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        let b = bearingDeg * .pi / 180
        let g = plane.geodetic(east: magnitudeM * sin(b), north: magnitudeM * cos(b))
        return (g.latitude, g.longitude)
    }

    /// The injected pins of a case, in time order: each at the genuine
    /// position at its `t` (sensitivity) or displaced from it
    /// (specificity), with the map span of `options` and the recorded OBD
    /// speed at the tap. A time without a genuine position gets no pin.
    static func pinInputs(_ pinTs: [Double], case c: Case, truthFixes: [GNSSFix], obdKmh: [(t: Double, v: Double)],
                          yaw: [(t: Double, v: Double)] = [], options: Options) -> [(ns: Int64, input: NavigationInput)] {
        pinTs.enumerated().compactMap { k, t in
            guard var p = position(at: t, in: truthFixes, options: options) else { return nil }
            if c.kind == .specificity && (k == 0 || c.secondPin != .genuine) {
                var bearing = c.bearingDeg
                // Yaw is counter-clockwise, bearings clockwise.
                if k > 0, c.secondPin == .sameInCarFrame, let y0 = value(yaw, at: pinTs[0]), let y = value(yaw, at: t) {
                    bearing -= (y - y0) * 180 / .pi
                }
                p = shifted(latitude: p.latitude, longitude: p.longitude, magnitudeM: c.magnitudeM, bearingDeg: bearing)
            }
            let at = MonotonicTimestamp(seconds: t)
            let kmh = value(obdKmh, at: t)
            let sample = ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: at, mapSpanM: options.pinMapSpanM,
                                         obdSpeedKmh: kmh, obdSpeedT: kmh == nil ? nil : at,
                                         speedSource: kmh == nil ? ManualFixSample.SpeedSource.unknown.rawValue
                                             : ManualFixSample.SpeedSource.obd.rawValue,
                                         gateSpeedKmh: kmh)
            return (at.nanoseconds, .manualFix(sample, at: at))
        }
    }

    /// `input` as the case gives it: under sensitivity a GNSS fix (valid
    /// speed, any source) with `t` in [t0, tEnd] is shifted; anything else
    /// is unchanged.
    static func edited(_ input: NavigationInput, case c: Case, t0: Double, tEnd: Double) -> NavigationInput {
        guard c.kind == .sensitivity, case .location(var s, let t) = input, s.hasValidPosition, s.hasValidSpeed,
              t.seconds >= t0, t.seconds <= tEnd else { return input }
        (s.latitude, s.longitude) = shifted(latitude: s.latitude, longitude: s.longitude, magnitudeM: c.magnitudeM,
                                            bearingDeg: c.bearingDeg)
        return .location(s, at: t)
    }

    static func runCase(engine start: NavigationEngine, inputs: [NavigationInput], from index: Int, t0: Double, tEnd: Double,
                        pinTs: [Double], pin: PinTime, case c: Case, truthFixes: [GNSSFix],
                        obdKmh: [(t: Double, v: Double)], yaw: [(t: Double, v: Double)], options: Options) -> Outcome {
        var engine = start
        let endNs = MonotonicTimestamp(seconds: tEnd).nanoseconds
        var pending = pinInputs(pinTs, case: c, truthFixes: truthFixes, obdKmh: obdKmh, yaw: yaw, options: options)
        var decisions: [FixPinDecision?] = []
        var priorErrors: [Double?] = []
        func ingestPin() {
            let (ns, input) = pending.removeFirst()
            var priorError: Double?
            if let truth = position(at: Double(ns) / 1e9, in: truthFixes, options: options),
               let e = engine.estimate(at: MonotonicTimestamp(nanoseconds: ns)) {
                let plane = LocalTangentPlane(latitude: truth.latitude, longitude: truth.longitude)
                let d = plane.enu(latitude: e.latitude, longitude: e.longitude)
                priorError = (d.east * d.east + d.north * d.north).squareRoot()
            }
            priorErrors.append(priorError)
            engine.ingest(input)
            decisions.append(engine.lastFixPinDecision)
        }
        var k = index
        while k < inputs.count && inputs[k].arrival.nanoseconds <= endNs {
            // Inputs keep arrival order; a manual fix arrives at its `t`, after
            // every input of the same arrival (`NavigationReplay.inputs` keeps
            // file order on ties, and the pin is appended last).
            while let p = pending.first, p.ns < inputs[k].arrival.nanoseconds { ingestPin() }
            engine.ingest(edited(inputs[k], case: c, t0: t0, tEnd: tEnd))
            k += 1
        }
        while !pending.isEmpty { ingestPin() }
        var endError: Double?
        if let truth = position(at: tEnd, in: truthFixes, options: options),
           let e = engine.estimate(at: MonotonicTimestamp(seconds: tEnd)) {
            let plane = LocalTangentPlane(latitude: truth.latitude, longitude: truth.longitude)
            let d = plane.enu(latitude: e.latitude, longitude: e.longitude)
            endError = (d.east * d.east + d.north * d.north).squareRoot()
        }
        return Outcome(pin: pin, case: c, decision: decisions.first ?? nil,
                       secondDecision: decisions.count > 1 ? decisions[1] : nil, priorErrorM: priorErrors.first ?? nil,
                       endErrorM: endError, decisions: decisions, priorErrorsM: priorErrors)
    }
}
