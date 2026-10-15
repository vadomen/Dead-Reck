import Foundation
import Testing

@testable import DriveLoggerCore

/// Speedless course (N3 candidate, `NavigationConfig.speedlessCourse`): the
/// course of a fix without a valid speed is used when fresh OBD says the car
/// is moving. Synthetic drives around (0, 0) only.
@Suite("Navigation speedless course")
struct NavigationSpeedlessCourseTests {
    typealias S = SyntheticDrive

    /// The car drives east (90°) at 10 m/s for the whole drive.
    static let drive = S(initialHeadingDeg: 90, initialSpeed: 10, [.straight(seconds: 200, speed: 10)])

    /// What the fix generator emits at one whole second.
    enum FixKind {
        /// A tower fix: no speed, no course; it initialises the engine with
        /// headings uniform over the circle.
        case tower
        /// A network fix with no speed and no course, at `accuracy`.
        case courseless(accuracy: Double)
        /// A network fix (speed −1) carrying a course.
        case speedless(course: Double, courseAccuracy: Double, accuracy: Double)
        /// A GNSS fix with a valid speed and course.
        case gnss(course: Double, accuracy: Double)
    }

    /// Fixes at the truth position (no noise), keyed by whole second.
    static func events(_ fixes: [Int: FixKind], obd: ((Double) -> Double?)? = nil) -> [LogEvent] {
        drive.events(
            obdSpeed: obd.map { f in { t, _ in f(t) } },
            fix: { t, state, _ in
                let second = Int(t.rounded())
                guard abs(t - Double(second)) < S.motionDt / 2, let kind = fixes[second] else { return nil }
                switch kind {
                case .tower:
                    return S.Fix(east: state.east, north: state.north, accuracy: 1_000)
                case .courseless(let accuracy):
                    return S.Fix(east: state.east, north: state.north, accuracy: accuracy)
                case .speedless(let course, let courseAccuracy, let accuracy):
                    return S.Fix(east: state.east, north: state.north, accuracy: accuracy,
                                 course: course, courseAccuracy: courseAccuracy)
                case .gnss(let course, let accuracy):
                    return S.Fix(east: state.east, north: state.north, accuracy: accuracy,
                                 speed: state.speed, speedAccuracy: 0.3, course: course, courseAccuracy: 2)
                }
            }
        )
    }

    static func config(speedless: Bool, particles: Int = 400) -> NavigationConfig {
        var config = S.config(particles: particles)
        config.speedlessCourse = speedless ? 1 : 0
        return config
    }

    /// Heading std (degrees) at each sample time, key on and key off, plus
    /// both engines.
    static func run(_ events: [LogEvent], at times: [Double])
        -> (on: [Double], off: [Double], engineOn: NavigationEngine, engineOff: NavigationEngine) {
        let (on, samplesOn) = S.run(events, config: config(speedless: true), sampleTimes: times)
        let (off, samplesOff) = S.run(events, config: config(speedless: false), sampleTimes: times)
        return (samplesOn.map { $0?.headingStdDeg ?? .nan }, samplesOff.map { $0?.headingStdDeg ?? .nan }, on, off)
    }

    /// A course of 90° ± 30° at 20 s on a tower-initialised engine.
    static let oneCourse: [Int: FixKind] = [0: .tower, 20: .speedless(course: 90, courseAccuracy: 30, accuracy: 1_000)]

    // MARK: Acceptance

    @Test("A speedless course with fresh OBD at 36 km/h narrows heading; key off it does not")
    func freshMovingNarrows() throws {
        let r = Self.run(Self.events(Self.oneCourse), at: [19.9, 20.2])
        #expect(r.engineOn.counters.speedlessCourseUpdates == 1)
        #expect(r.engineOn.counters.courseUpdates == 0)
        #expect(r.engineOff.counters.speedlessCourseUpdates == 0)
        // Uniform before (no heading information at all).
        #expect(r.on[0] > 60 && r.on[0] == r.off[0])
        #expect(r.on[1] < 45, "heading std \(r.on[1])° after the course")
        #expect(r.off[1] > 60, "key off: heading std \(r.off[1])°")
    }

    /// Key on, but the course must not be used: the estimate is the same as
    /// key off at every sample, and no speedless course is counted.
    static func expectIgnored(_ events: [LogEvent], _ what: Comment) throws {
        let times = [19.9, 20.2, 25]
        let (on, samplesOn) = S.run(events, config: config(speedless: true), sampleTimes: times)
        let (_, samplesOff) = S.run(events, config: config(speedless: false), sampleTimes: times)
        #expect(on.counters.speedlessCourseUpdates == 0, what)
        for (a, b) in zip(samplesOn, samplesOff) {
            let a = try #require(a), b = try #require(b)
            #expect(a.headingStdDeg == b.headingStdDeg && a.latitude == b.latitude && a.longitude == b.longitude, what)
        }
        #expect(try #require(samplesOn[1]).headingStdDeg > 60, what)
    }

    @Test("Key on: OBD 0 at the fix (fresh) vetoes a speedless course")
    func obdZeroVetoes() throws {
        try Self.expectIgnored(Self.events(Self.oneCourse, obd: { _ in 0 }), "OBD 0")
    }

    @Test("Key on: stale moving OBD (the link dropped while driving) does not admit a speedless course")
    func staleMovingVetoes() throws {
        try Self.expectIgnored(Self.events(Self.oneCourse, obd: { t in t < 10 ? 36 : nil }), "stale moving OBD")
    }

    @Test("Key on: stale OBD 0 does not admit a speedless course")
    func staleZeroVetoes() throws {
        try Self.expectIgnored(Self.events(Self.oneCourse, obd: { t in t < 10 ? 0 : nil }), "stale OBD 0")
    }

    @Test("Key on: no OBD reply at all does not admit a speedless course")
    func noOBDVetoes() throws {
        try Self.expectIgnored(Self.events(Self.oneCourse, obd: { _ in nil }), "no OBD")
    }

    @Test("Key on: OBD under courseMinSpeedMps (2 m/s with the offset) does not admit a speedless course")
    func slowOBDVetoes() throws {
        try Self.expectIgnored(Self.events(Self.oneCourse, obd: { _ in 7 }), "OBD 7 km/h")
    }

    @Test("Key on: courseAccuracy above speedlessCourseMaxAccDeg is not used; at the cap it is")
    func accuracyCap() throws {
        let over: [Int: FixKind] = [0: .tower, 20: .speedless(course: 90, courseAccuracy: 45.5, accuracy: 1_000)]
        try Self.expectIgnored(Self.events(over), "courseAccuracy 45.5°")
        let at: [Int: FixKind] = [0: .tower, 20: .speedless(course: 90, courseAccuracy: 45, accuracy: 1_000)]
        let r = Self.run(Self.events(at), at: [20.2])
        #expect(r.engineOn.counters.speedlessCourseUpdates == 1)
        #expect(r.on[0] < r.off[0])
    }

    // MARK: Never clean

    @Test("A speedless fix under cleanFixAccM never initialises heading, even with fresh moving OBD")
    func neverInitialisesHeading() throws {
        // The first fix of all: 10 m, course 90° ± 5°, OBD 36 km/h fresh.
        let fixes: [Int: FixKind] = [5: .speedless(course: 90, courseAccuracy: 5, accuracy: 10)]
        let r = Self.run(Self.events(fixes), at: [5.2])
        #expect(r.engineOn.isInitialized)
        #expect(r.on[0] > 60, "heading std \(r.on[0])° after a speedless initialising fix")
        #expect(r.on[0] == r.off[0])
        #expect(r.engineOn.counters.reseeds == 0 && r.engineOn.counters.speedlessCourseUpdates == 0)
    }

    @Test("A speedless fix under cleanFixAccM never reseeds; the same fix with a valid speed does")
    func neverReseeds() throws {
        let speedless: [Int: FixKind] = [0: .tower, 20: .speedless(course: 90, courseAccuracy: 5, accuracy: 10)]
        let r = Self.run(Self.events(speedless), at: [20.2])
        #expect(r.engineOn.counters.speedlessCourseUpdates == 1)
        #expect(r.engineOn.counters.reseeds == 0)
        // Control: a clean GNSS fix at the same instant reseeds (heading std
        // above reseedHeadingStdDeg), so the scenario would reseed if the
        // speedless fix counted as clean.
        let gnss: [Int: FixKind] = [0: .tower, 20: .gnss(course: 90, accuracy: 10)]
        let control = Self.run(Self.events(gnss), at: [20.2])
        #expect(control.engineOn.counters.reseeds == 1 && control.engineOn.counters.courseUpdates == 1)
    }

    @Test("A speedless course with no support in a converged cloud does not reseed")
    func noSupportNoReseed() throws {
        // Clean GNSS converges heading on 90°; a speedless course of 270°
        // ± 5° later has no particle within 4 σ: a clean fix would reseed.
        var fixes: [Int: FixKind] = [0: .tower]
        for s in 5...15 { fixes[s] = .gnss(course: 90, accuracy: 5) }
        fixes[40] = .speedless(course: 270, courseAccuracy: 5, accuracy: 10)
        let r = Self.run(Self.events(fixes), at: [39.9, 40.2])
        let reseedsBefore = r.engineOff.counters.reseeds
        #expect(r.engineOn.counters.speedlessCourseUpdates == 1)
        #expect(r.engineOn.counters.reseeds == reseedsBefore)
    }

    // MARK: Correlation

    /// Heading std (key on) just after the last of `seconds`, each a 90° ±
    /// 30° speedless course, on a tower-initialised engine; plus the engine.
    /// The course fixes claim 50 km, so their position term is negligible
    /// and only the course term narrows heading.
    static func courses(_ seconds: [Int], extra: [Int: FixKind] = [:]) -> (std: Double, engine: NavigationEngine) {
        var fixes: [Int: FixKind] = [0: .tower]
        for s in seconds { fixes[s] = .speedless(course: 90, courseAccuracy: 30, accuracy: 50_000) }
        fixes.merge(extra) { a, _ in a }
        let (engine, samples) = S.run(Self.events(fixes), config: config(speedless: true),
                                      sampleTimes: [Double(seconds.max()!) + 0.2])
        return (samples[0]?.headingStdDeg ?? .nan, engine)
    }

    @Test("Three identical courses within networkFixCorrelationS narrow heading less than three spaced beyond it")
    func correlatedCoursesTempered() {
        let close = Self.courses([10, 11, 12])
        let spaced = Self.courses([10, 75, 140])
        let one = Self.courses([10])
        #expect(close.engine.counters.speedlessCourseUpdates == 3 && spaced.engine.counters.speedlessCourseUpdates == 3)
        // Weights 1, 1/60, 1/60 against 1, 1, 1: close ≈ one course, spaced
        // ≈ σ/√3.
        #expect(spaced.std < 0.75 * close.std, "spaced \(spaced.std)°, close \(close.std)°")
        #expect(abs(close.std - one.std) < 0.1 * one.std, "close \(close.std)°, one \(one.std)°")
    }

    @Test("A courseless network fix between two courses does not lower the second course's weight")
    func courselessFixDoesNotTemperCourse() {
        let plain = Self.courses([10, 75])
        let withTower = Self.courses([10, 75], extra: [74: .courseless(accuracy: 50_000)])
        let first = Self.courses([10])
        #expect(withTower.engine.counters.networkFixesUsed == plain.engine.counters.networkFixesUsed + 1)
        // Full weight: the second course narrows the first course's std by
        // about √2 in both. Measured from the courseless fix (1 s before),
        // it would weigh 1/60 and leave the std near the first course's.
        #expect(withTower.std < 0.85 * first.std, "with tower \(withTower.std)°, first \(first.std)°")
        #expect(abs(withTower.std - plain.std) < 0.05 * plain.std, "with tower \(withTower.std)°, plain \(plain.std)°")
    }

    // MARK: Key on without speedless courses

    @Test("Key on, no speedless course in the input: bit-identical to key off")
    func keyOnWithoutSpeedlessCourseIsIdentical() throws {
        // Tower fixes, a speedless fix without a course, GNSS fixes with
        // valid speed and course: nothing for the new rule to take.
        var fixes: [Int: FixKind] = [0: .tower, 30: .tower, 60: .tower]
        for s in 70...90 { fixes[s] = .gnss(course: 90, accuracy: 8) }
        let p = S.plane.geodetic(east: Self.drive.truth(at: 45).east, north: 0)
        let events = Self.events(fixes) + [.location(LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1,
            speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
            receivedT: S.ms(45.05), ageS: 0.05), at: S.ms(45))]
        let times = stride(from: 1.0, through: 120, by: 7).map { $0 }
        let (on, samplesOn) = S.run(events, config: Self.config(speedless: true), sampleTimes: times)
        let (off, samplesOff) = S.run(events, config: Self.config(speedless: false), sampleTimes: times)
        #expect(on.counters == off.counters)
        #expect(on.counters.speedlessCourseUpdates == 0 && on.counters.courseUpdates > 0)
        for (a, b) in zip(samplesOn, samplesOff) { #expect(a == b) }
        #expect(on.weight == off.weight && on.heading == off.heading)
    }

    @Test("speedlessCourse other than 0 or 1 is an invalid config")
    func switchValues() {
        var config = NavigationConfig()
        #expect(config.speedlessCourse == 0 && config.invalidReason == nil)
        config.speedlessCourse = 1
        #expect(config.invalidReason == nil)
        config.speedlessCourse = 2
        #expect(config.invalidReason != nil)
    }
}
