import Foundation

/// Constant-offset check of a run of clean GNSS fixes against road packs
/// (`replay_nav --fix-offset`): a fix stream shifted by one constant vector
/// (a spoofer, or an accessory reporting a shifted position) keeps genuine
/// dynamics but sits off the roads, and the one shift that puts it back on
/// them stands out from every other shift of the same track.
///
/// For a window of fixes it reports the distance-to-road distribution of
/// the fixes as recorded, the best constant shift on a grid (coarse, then
/// refined) with its score, and where both stand in the distribution of
/// scores over every grid shift. Analysis only: nothing here feeds the
/// engine. Output is relative metres and bearings, never a position.
public enum FixOffsetScan {
    public struct Options: Hashable, Sendable {
        /// Shifts are searched on a square grid of ± this many metres.
        public var maxShiftM = 400.0
        public var coarseStepM = 10.0
        /// Refinement step around the best coarse shift.
        public var fineStepM = 1.0
        /// Distances to the nearest road are capped here, so a fix with no
        /// road near it (a lake, an unmapped yard) counts as `capM`, not more.
        public var capM = 100.0
        /// The runner-up is the best coarse shift at least this far from the best.
        public var runnerUpSeparationM = 100.0
        /// Fewer fixes than this: no scan.
        public var minFixes = 5
        /// "Off roads": the recorded track's `statistic` is at least
        /// `offRoadMinM` and at least `offRoadMinRank` of the grid shifts do
        /// as well. Set just above the maxima of the on-road windows of the
        /// earlier drives (docs/NAVIGATION.md, "Constant-offset GNSS check"):
        /// 14.2 m mean, 23 % rank (not in the same window).
        public var offRoadMinM = 15.0
        public var offRoadMinRank = 0.2
        /// "Offset found": off roads, the best shift is at least this long,
        /// and its `statistic` is at most `foundRatio` of the recorded track's.
        public var foundMinShiftM = 50.0
        public var foundRatio = 0.5
        /// "Unique": the runner-up's median is at least `uniqueRatio` × the
        /// best's and at least `uniqueMarginM` more.
        public var uniqueRatio = 2.0
        public var uniqueMarginM = 10.0
        /// Which statistic of the capped distances ranks shifts.
        public var statistic = Statistic.mean
        /// A fix with a course, moving at least `courseMinSpeedMps`, counts only
        /// roads within this angle of its course (either direction); nil:
        /// every road counts. A shift that lays the track across streets
        /// is then no longer as good as one that lays it along them.
        public var courseToleranceDeg: Double? = 30
        public var courseMinSpeedMps = 2.0
        /// Hypotheses (e.g. a pin's vector) scored and ranked in every window.
        public var tested: [Shift] = []

        public init() {}
    }

    public enum Statistic: String, CaseIterable, Sendable {
        case mean, median
    }

    /// Which fixes a scan uses, by `LocationSample.accessory`.
    public enum Source: String, CaseIterable, Sendable {
        case any, accessory, phone

        public func admits(_ accessory: Bool?) -> Bool {
            switch self {
            case .any: true
            case .accessory: accessory == true
            case .phone: accessory != true
            }
        }
    }

    public struct Fix: Hashable, Sendable {
        /// Session seconds (the event `t`).
        public var t: Double
        public var latitude: Double
        public var longitude: Double
        public var accuracyM: Double
        public var accessory: Bool?
        /// m/s, negative when unavailable.
        public var speed: Double
        /// Degrees, negative when unavailable.
        public var course: Double

        public init(t: Double, latitude: Double, longitude: Double, accuracyM: Double, accessory: Bool? = nil,
                    speed: Double = -1, course: Double = -1) {
            self.t = t
            self.latitude = latitude
            self.longitude = longitude
            self.accuracyM = accuracyM
            self.accessory = accessory
            self.speed = speed
            self.course = course
        }
    }

    /// A constant shift, east and north metres.
    public struct Shift: Hashable, Sendable {
        public var east: Double
        public var north: Double

        public init(east: Double, north: Double) {
            self.east = east
            self.north = north
        }

        public var lengthM: Double { (east * east + north * north).squareRoot() }
        /// Degrees clockwise from north, [0, 360).
        public var bearingDeg: Double { FixOffsetScan.bearing(east: east, north: north) }
    }

    /// Capped distance-to-road statistics of a track.
    public struct Score: Hashable, Sendable {
        public var meanM: Double
        public var medianM: Double
        public var p90M: Double

        /// The value shifts are ranked by.
        public func value(_ statistic: Statistic) -> Double {
            switch statistic {
            case .mean: meanM
            case .median: medianM
            }
        }
    }

    /// A hypothesis shift's score in a window and its rank: the share of
    /// coarse grid shifts scoring at most as well.
    public struct Tested: Hashable, Sendable {
        public var shift: Shift
        public var score: Score
        public var rank: Double
    }

    public struct Window: Hashable, Sendable {
        public var fromS: Double
        public var toS: Double
        public var fixes: Int
        public var accessoryFixes: Int
        public var minAccuracyM: Double
        public var maxAccuracyM: Double
        /// Largest distance of a fix from the window's first fix.
        public var extentM: Double
        /// The recorded track (zero shift).
        public var recorded: Score
        public var best: Shift
        public var bestScore: Score
        /// The statistic shifts were ranked by.
        public var statistic: Statistic
        /// Over every coarse shift's `statistic`: the 5th percentile and the median.
        public var shiftP5M: Double
        public var shiftMedianM: Double
        /// Share of coarse shifts scoring at most the recorded track's `statistic`.
        public var recordedRank: Double
        public var runnerUp: Shift?
        public var runnerUpScore: Score?
        public var offRoad: Bool
        public var found: Bool
        public var unique: Bool
        public var tested: [Tested] = []
        /// Each fix's capped distance to the nearest road as recorded, in time order.
        public var recordedDistancesM: [Double] = []
    }

    /// A pin against the clean fix nearest it in time: the vector from that
    /// fix to the pin.
    public struct PinCheck: Hashable, Sendable {
        public var t: Double
        public var fixDtS: Double
        public var vector: Shift
    }

    /// Whether a fix stream's dynamics are its own: fix path length against
    /// the OBD distance, GNSS speed against OBD speed, and the net change of
    /// the fixes' course against the gyro's yaw about gravity.
    public struct Dynamics: Hashable, Sendable {
        public var fixPathM: Double
        public var obdDistanceM: Double?
        public var speedDifferenceMedianKmh: Double?
        public var courseChangeDeg: Double?
        public var gyroYawDeg: Double?
    }

    // MARK: Inputs

    /// Fixes with `0 ≤ horizontalAccuracy ≤ maxAccuracyM` (by default the
    /// clean-fix rule, `NavigationReplay.cleanFixTruthAccM`) from `source`,
    /// in time order.
    public static func cleanFixes<S: Sequence>(from events: S, source: Source = .any,
                                               maxAccuracyM: Double = NavigationReplay.cleanFixTruthAccM) -> [Fix]
        where S.Element == LogEvent {
        events.compactMap { event -> Fix? in
            guard case .location(let s) = event.payload, s.horizontalAccuracy >= 0,
                  s.horizontalAccuracy <= maxAccuracyM, source.admits(s.accessory) else { return nil }
            return Fix(t: event.timestamp.seconds, latitude: s.latitude, longitude: s.longitude, accuracyM: s.horizontalAccuracy,
                       accessory: s.accessory, speed: s.hasValidSpeed ? s.speed : -1, course: s.hasValidCourse ? s.course : -1)
        }.sorted { $0.t < $1.t }
    }

    // MARK: Scan

    /// The scan of `fixes` (already windowed), or nil with fewer than
    /// `options.minFixes`.
    public static func scan(_ fixes: [Fix], roads: RoadNetwork, options: Options = Options()) -> Window? {
        guard fixes.count >= max(1, options.minFixes), let first = fixes.first else { return nil }
        let plane = LocalTangentPlane(latitude: first.latitude, longitude: first.longitude)
        let points = fixes.map { plane.enu(latitude: $0.latitude, longitude: $0.longitude) }
        // Unit course vector (east, north) of a directional fix, else nil.
        let courses: [(Double, Double)?] = fixes.map { fix in
            guard options.courseToleranceDeg != nil, fix.course >= 0, fix.speed >= options.courseMinSpeedMps else { return nil }
            let c = fix.course * .pi / 180
            return (sin(c), cos(c))
        }
        let minAbsCos = options.courseToleranceDeg.map { cos($0 * .pi / 180) } ?? 0
        let margin = options.maxShiftM + options.capM + options.fineStepM + options.coarseStepM
        let field = RoadField(roads: roads, plane: plane, points: points, marginM: margin, capM: options.capM)
        var buffer = [Double](repeating: 0, count: points.count)
        func distances(_ shift: Shift) -> [Double] {
            for (i, p) in points.enumerated() {
                buffer[i] = field.distance(east: p.east + shift.east, north: p.north + shift.north,
                                           course: courses[i], minAbsCos: minAbsCos)
            }
            return buffer
        }
        func score(_ shift: Shift) -> Score {
            buffer = distances(shift)
            buffer.sort()
            return Score(meanM: buffer.reduce(0, +) / Double(buffer.count), medianM: quantile(buffer, 0.5),
                         p90M: quantile(buffer, 0.9))
        }
        let recordedDistances = distances(Shift(east: 0, north: 0))
        let recorded = score(Shift(east: 0, north: 0))
        let steps = Int((options.maxShiftM / options.coarseStepM).rounded(.down))
        var coarse: [(shift: Shift, score: Score)] = []
        coarse.reserveCapacity((2 * steps + 1) * (2 * steps + 1))
        for i in -steps...steps {
            for j in -steps...steps {
                let shift = Shift(east: Double(i) * options.coarseStepM, north: Double(j) * options.coarseStepM)
                coarse.append((shift, score(shift)))
            }
        }
        let stat = options.statistic
        func better(_ a: (shift: Shift, score: Score), _ b: (shift: Shift, score: Score)) -> Bool {
            let va = a.score.value(stat), vb = b.score.value(stat)
            if va != vb { return va < vb }
            return a.shift.lengthM < b.shift.lengthM
        }
        var bestCoarse = coarse[0]
        for c in coarse where better(c, bestCoarse) { bestCoarse = c }
        var best = bestCoarse
        let fine = Int((options.coarseStepM / options.fineStepM).rounded(.down))
        for i in -fine...fine {
            for j in -fine...fine {
                let shift = Shift(east: bestCoarse.shift.east + Double(i) * options.fineStepM,
                                  north: bestCoarse.shift.north + Double(j) * options.fineStepM)
                let c = (shift: shift, score: score(shift))
                if better(c, best) { best = c }
            }
        }
        let values = coarse.map { $0.score.value(stat) }.sorted()
        var runnerUp: (shift: Shift, score: Score)?
        for c in coarse {
            let dx = c.shift.east - best.shift.east, dy = c.shift.north - best.shift.north
            guard (dx * dx + dy * dy).squareRoot() >= options.runnerUpSeparationM else { continue }
            if runnerUp.map({ better(c, $0) }) ?? true { runnerUp = c }
        }
        let shiftP5 = quantile(values, 0.05)
        let bestValue = best.score.value(stat)
        let recordedRank = Double(values.filter { $0 <= recorded.value(stat) }.count) / Double(values.count)
        let offRoad = recorded.value(stat) >= options.offRoadMinM && recordedRank >= options.offRoadMinRank
        let found = offRoad && best.shift.lengthM >= options.foundMinShiftM
            && bestValue <= options.foundRatio * recorded.value(stat)
        let unique = runnerUp.map {
            $0.score.value(stat) >= options.uniqueRatio * bestValue && $0.score.value(stat) >= bestValue + options.uniqueMarginM
        } ?? true
        let tested = options.tested.map { shift -> Tested in
            let sc = score(shift)
            return Tested(shift: shift, score: sc,
                          rank: Double(values.filter { $0 <= sc.value(stat) }.count) / Double(values.count))
        }
        let extent = points.map { ($0.east * $0.east + $0.north * $0.north).squareRoot() }.max() ?? 0
        return Window(
            fromS: first.t, toS: fixes[fixes.count - 1].t, fixes: fixes.count,
            accessoryFixes: fixes.filter { $0.accessory == true }.count,
            minAccuracyM: fixes.map(\.accuracyM).min() ?? 0, maxAccuracyM: fixes.map(\.accuracyM).max() ?? 0,
            extentM: extent, recorded: recorded, best: best.shift, bestScore: best.score,
            statistic: stat, shiftP5M: shiftP5, shiftMedianM: quantile(values, 0.5),
            recordedRank: recordedRank,
            runnerUp: runnerUp?.shift, runnerUpScore: runnerUp?.score, offRoad: offRoad, found: found, unique: unique,
            tested: tested, recordedDistancesM: recordedDistances
        )
    }

    /// Windows of `lengthS` every `stepS` over the fixes' time span; a
    /// window holds the fixes with `from ≤ t < from + lengthS`.
    public static func slidingWindows(over fixes: [Fix], lengthS: Double, stepS: Double) -> [(from: Double, to: Double)] {
        guard let first = fixes.first?.t, let last = fixes.last?.t, lengthS > 0, stepS > 0 else { return [] }
        var out: [(Double, Double)] = []
        var from = first
        while from <= last {
            out.append((from, from + lengthS))
            from += stepS
        }
        return out
    }

    /// The fixes with `from ≤ t ≤ to`.
    public static func fixes(_ fixes: [Fix], from: Double, to: Double) -> [Fix] {
        fixes.filter { $0.t >= from && $0.t <= to }
    }

    // MARK: Pins

    /// Each pin against the clean fix nearest it in time, if one is within
    /// `maxGapS`.
    public static func pinChecks(pins: [(t: Double, latitude: Double, longitude: Double)], fixes: [Fix],
                                 maxGapS: Double = 5) -> [PinCheck] {
        pins.compactMap { pin in
            guard let fix = fixes.min(by: { abs($0.t - pin.t) < abs($1.t - pin.t) }), abs(fix.t - pin.t) <= maxGapS else {
                return nil
            }
            let plane = LocalTangentPlane(latitude: fix.latitude, longitude: fix.longitude)
            let v = plane.enu(latitude: pin.latitude, longitude: pin.longitude)
            return PinCheck(t: pin.t, fixDtS: fix.t - pin.t, vector: Shift(east: v.east, north: v.north))
        }
    }

    // MARK: Dynamics

    /// The dynamics of `fixes` (already windowed) against OBD vehicle speed
    /// (`(t, m/s)`, primary ECU, time order) and the gyro's rate about the
    /// up axis (`(t, rad/s)`, counter-clockwise positive, time order).
    public static func dynamics(_ fixes: [Fix], obdSpeed: [(t: Double, mps: Double)],
                                yawRate: [(t: Double, radPerS: Double)]) -> Dynamics {
        var path = 0.0
        for i in fixes.indices.dropFirst() {
            let plane = LocalTangentPlane(latitude: fixes[i - 1].latitude, longitude: fixes[i - 1].longitude)
            let p = plane.enu(latitude: fixes[i].latitude, longitude: fixes[i].longitude)
            path += (p.east * p.east + p.north * p.north).squareRoot()
        }
        var result = Dynamics(fixPathM: path)
        guard let from = fixes.first?.t, let to = fixes.last?.t, to > from else { return result }
        // OBD distance: each reply's speed held until the next one, at most 2 s.
        let maxHoldS = 2.0
        if let firstIndex = obdSpeed.firstIndex(where: { $0.t >= from - maxHoldS }), obdSpeed[firstIndex].t <= to {
            var distance = 0.0
            for k in firstIndex..<obdSpeed.count {
                let start = max(from, obdSpeed[k].t)
                guard start < to else { break }
                let next = k + 1 < obdSpeed.count ? obdSpeed[k + 1].t : .infinity
                let end = min(to, next, obdSpeed[k].t + maxHoldS)
                if end > start { distance += obdSpeed[k].mps * (end - start) }
            }
            result.obdDistanceM = distance
            var differences: [Double] = []
            for fix in fixes where fix.speed >= 0 {
                guard let reply = nearest(obdSpeed, to: fix.t, maxGapS: 1) else { continue }
                differences.append(abs(fix.speed - reply.mps) * 3.6)
            }
            if !differences.isEmpty { result.speedDifferenceMedianKmh = quantile(differences.sorted(), 0.5) }
        }
        let coursed = fixes.filter { $0.course >= 0 }
        if let a = coursed.first, let b = coursed.last, b.t > a.t {
            var change = 0.0
            for i in coursed.indices.dropFirst() {
                var d = coursed[i].course - coursed[i - 1].course
                d = d - 360 * (d / 360).rounded()
                change += d
            }
            result.courseChangeDeg = change
            let inside = yawRate.filter { $0.t >= a.t && $0.t <= b.t }
            if inside.count >= 2 {
                var yaw = 0.0
                for k in inside.indices.dropFirst() {
                    yaw += 0.5 * (inside[k].radPerS + inside[k - 1].radPerS) * (inside[k].t - inside[k - 1].t)
                }
                // Course is clockwise; the up-axis rate is counter-clockwise.
                result.gyroYawDeg = -yaw * 180 / .pi
            }
        }
        return result
    }

    /// OBD vehicle speed of the primary ECU (or none named), m/s, time order.
    public static func obdSpeed<S: Sequence>(from events: S) -> [(t: Double, mps: Double)] where S.Element == LogEvent {
        events.compactMap { event -> (t: Double, mps: Double)? in
            guard case .obd(let s) = event.payload, s.pid == .vehicleSpeed,
                  s.ecu == nil || s.ecu == NavigationEngine.primaryECU, s.value.isFinite, s.value >= 0 else { return nil }
            return (event.timestamp.seconds, s.value / 3.6)
        }.sorted { $0.t < $1.t }
    }

    /// The rotation rate about the up axis (against gravity), rad/s,
    /// counter-clockwise positive, time order.
    public static func yawRate<S: Sequence>(from events: S) -> [(t: Double, radPerS: Double)] where S.Element == LogEvent {
        events.compactMap { event -> (t: Double, radPerS: Double)? in
            guard case .motion(let m) = event.payload else { return nil }
            let g = m.gravity
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            guard norm > 0.5 else { return nil }
            let r = m.rotationRate
            return (event.timestamp.seconds, -(r.x * g.x + r.y * g.y + r.z * g.z) / norm)
        }.sorted { $0.t < $1.t }
    }

    // MARK: Helpers

    /// Degrees clockwise from north, [0, 360).
    public static func bearing(east: Double, north: Double) -> Double {
        let b = atan2(east, north) * 180 / .pi
        return b < 0 ? b + 360 : b
    }

    /// Nearest-rank quantile of a sorted, non-empty array.
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }

    static func nearest(_ series: [(t: Double, mps: Double)], to t: Double, maxGapS: Double) -> (t: Double, mps: Double)? {
        var lo = 0, hi = series.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if series[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { $0 >= 0 && $0 < series.count }.map { series[$0] }
        guard let best = candidates.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(best.t - t) <= maxGapS else { return nil }
        return best
    }
}

/// Every road segment near a set of plane points, hashed in square cells of
/// `capM`, for capped nearest-road distances.
struct RoadField {
    struct Segment {
        var ax: Double, ay: Double, ux: Double, uy: Double, length: Double
    }

    let capM: Double
    private(set) var segments: [Segment] = []
    private var cells: [UInt64: [Int32]] = [:]

    init(roads: RoadNetwork, plane: LocalTangentPlane, points: [(east: Double, north: Double)], marginM: Double, capM: Double) {
        self.capM = capM
        guard !points.isEmpty else { return }
        let minE = points.map(\.east).min()! - marginM, maxE = points.map(\.east).max()! + marginM
        let minN = points.map(\.north).min()! - marginM, maxN = points.map(\.north).max()! + marginM
        let corners = [(minE, minN), (minE, maxN), (maxE, minN), (maxE, maxN)].map {
            roads.grid.cell(latitude: plane.geodetic(east: $0.0, north: $0.1).latitude,
                            longitude: plane.geodetic(east: $0.0, north: $0.1).longitude)
        }
        var seen = Set<RoadNetwork.SegmentRef>()
        var refs: [RoadNetwork.SegmentRef] = []
        for cx in corners.map(\.cx).min()!...corners.map(\.cx).max()! {
            for cy in corners.map(\.cy).min()!...corners.map(\.cy).max()! {
                roads.forEachSegment(inCellX: cx, y: cy) { ref in
                    if seen.insert(ref).inserted { refs.append(ref) }
                }
            }
        }
        refs.sort()
        for ref in refs {
            let s = roads.segment(ref)
            let a = plane.enu(latitude: s.a.latitude, longitude: s.a.longitude)
            let b = plane.enu(latitude: s.b.latitude, longitude: s.b.longitude)
            let dx = b.east - a.east, dy = b.north - a.north
            let length = (dx * dx + dy * dy).squareRoot()
            let index = Int32(segments.count)
            segments.append(Segment(ax: a.east, ay: a.north, ux: length > 0 ? dx / length : 0,
                                    uy: length > 0 ? dy / length : 1, length: length))
            let x0 = cell(min(a.east, b.east)), x1 = cell(max(a.east, b.east))
            let y0 = cell(min(a.north, b.north)), y1 = cell(max(a.north, b.north))
            for x in x0...x1 {
                for y in y0...y1 { cells[key(x, y), default: []].append(index) }
            }
        }
    }

    private func cell(_ v: Double) -> Int32 { Int32((v / capM).rounded(.down)) }
    private func key(_ x: Int32, _ y: Int32) -> UInt64 { UInt64(UInt32(bitPattern: x)) << 32 | UInt64(UInt32(bitPattern: y)) }

    /// Distance from (east, north) to the nearest segment, capped at `capM`;
    /// with a unit `course`, only segments whose direction has
    /// |cos(angle to course)| ≥ `minAbsCos` count. A segment within `capM`
    /// has its nearest point in the point's cell or a neighbour, and is
    /// listed in that cell.
    func distance(east: Double, north: Double, course: (Double, Double)? = nil, minAbsCos: Double = 0) -> Double {
        let cx = cell(east), cy = cell(north)
        var best = capM * capM
        for x in (cx - 1)...(cx + 1) {
            for y in (cy - 1)...(cy + 1) {
                guard let list = cells[key(x, y)] else { continue }
                for k in list {
                    let s = segments[Int(k)]
                    if let c = course, s.length > 0, abs(s.ux * c.0 + s.uy * c.1) < minAbsCos { continue }
                    let d2 = RoadMatcher.nearest(px: east, py: north, ax: s.ax, ay: s.ay, ux: s.ux, uy: s.uy, length: s.length)
                        .distanceSquared
                    if d2 < best { best = d2 }
                }
            }
        }
        return best.squareRoot()
    }
}

// MARK: Text (replay_nav --fix-offset)

extension FixOffsetScan {
    static func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    static func f1(_ v: Double) -> String { String(format: "%.1f", v) }

    public static let windowHeader =
        "window s        fixes acc  acc m      extent  recorded mean/p50/p90  best shift      best mean/p50/p90  shifts p5/p50  rank   runner-up            verdict"

    /// One table line for a window: no position, only metres and bearings.
    public static func text(_ w: Window) -> String {
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
        let runner = w.runnerUp.map { "\(f0($0.lengthM)) m @\(f0($0.bearingDeg))° (\(f1(w.runnerUpScore!.value(w.statistic))))" } ?? "-"
        func score(_ s: Score) -> String { "\(f1(s.meanM))/\(f1(s.medianM))/\(f1(s.p90M))" }
        let verdict = !w.offRoad ? "on roads" : !w.found ? "OFF ROADS, no shift fits" : w.unique ? "OFF ROADS, shift fits, unique" : "OFF ROADS, shift fits, not unique"
        return pad("\(f1(w.fromS))–\(f1(w.toS))", 16) + pad("\(w.fixes)", 6) + pad("\(w.accessoryFixes)", 5)
            + pad("\(f1(w.minAccuracyM))–\(f1(w.maxAccuracyM))", 11) + pad("\(f0(w.extentM)) m", 8)
            + pad(score(w.recorded), 23)
            + pad("\(f0(w.best.lengthM)) m @\(f0(w.best.bearingDeg))°", 16)
            + pad(score(w.bestScore), 19)
            + pad("\(f1(w.shiftP5M))/\(f1(w.shiftMedianM))", 15) + pad(String(format: "%.0f %%", w.recordedRank * 100), 7)
            + pad(runner, 21) + verdict
    }

    /// The hypothesis lines of a window.
    public static func testedText(_ w: Window) -> [String] {
        w.tested.map { t in
            "  tested \(f0(t.shift.lengthM)) m @\(f0(t.shift.bearingDeg))°: mean/p50/p90 "
                + "\(f1(t.score.meanM))/\(f1(t.score.medianM))/\(f1(t.score.p90M)), rank "
                + String(format: "%.2f %%", t.rank * 100) + " of grid shifts"
        }
    }

    public static func text(_ d: Dynamics) -> String {
        var parts = ["fix path \(f0(d.fixPathM)) m"]
        if let obd = d.obdDistanceM {
            parts.append("OBD \(f0(obd)) m" + (obd > 0 ? String(format: " (%+.1f %%)", (d.fixPathM / obd - 1) * 100) : ""))
        } else {
            parts.append("no OBD speed")
        }
        if let s = d.speedDifferenceMedianKmh { parts.append("|GNSS − OBD speed| p50 \(f1(s)) km/h") }
        if let c = d.courseChangeDeg {
            parts.append("course change \(f0(c))°" + (d.gyroYawDeg.map { ", gyro yaw \(f0($0))°" } ?? ", no gyro"))
        }
        return parts.joined(separator: "; ")
    }

    public static func text(_ p: PinCheck) -> String {
        "pin at \(f1(p.t)) s: \(f0(p.vector.lengthM)) m @\(f0(p.vector.bearingDeg))° from the fix at "
            + String(format: "%+.1f s", p.fixDtS)
    }
}
