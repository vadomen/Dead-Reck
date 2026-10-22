import Foundation
import Testing

@testable import DriveLoggerCore

/// `NavPriorSample` (format v5): conversions to and from the engine's
/// `NavigationPrior` and a Navigate `capture`, validation, and a reader
/// that survives a bad row. Coordinates are small offsets from (0, 0).
@Suite("NavPrior sample")
struct NavPriorSampleTests {
    static let sample = NavPriorSample(
        latitude: 0.0125, longitude: -0.025, covEE: 25, covEN: -2.5, covNN: 36,
        headingDeg: 271.5, headingStdDeg: 3.25, converged: true, speedMps: 22.25, obdSpeedKmh: 80,
        restoreClass: "moving", source: "navigate", estimateT: MonotonicTimestamp(nanoseconds: -850_000_000))

    /// A Navigate capture at uptime `uptime` (validated like a save).
    static func state(uptime: Double, restoreClass: NavigationRestoreClass = .standingStop,
                      obd: Double? = 0) -> NavigationRestoreState {
        NavigationRestoreState(
            savedAt: Date(timeIntervalSince1970: 1_000_000_000), bootSessionID: "boot-a", uptimeSeconds: uptime,
            latitude: -0.0125, longitude: 0.025, covEE: 16, covEN: 1, covNN: 9,
            headingDeg: 12.5, headingStdDeg: 2, converged: true, restoreClass: restoreClass, speedMps: 0.5,
            lastOBDSpeedKmh: obd, lastOBDAgeS: obd.map { _ in 0.3 })
    }

    @Test("A row converts to the engine's prior field for field, savedT = estimateT, always a hand-over")
    func toPrior() throws {
        let prior = try #require(Self.sample.navigationPrior)
        #expect(prior.latitude == 0.0125 && prior.longitude == -0.025)
        #expect(prior.covEE == 25 && prior.covEN == -2.5 && prior.covNN == 36)
        #expect(prior.headingDeg == 271.5 && prior.headingStdDeg == 3.25)
        #expect(prior.savedT == MonotonicTimestamp(nanoseconds: -850_000_000))
        #expect(prior.lastSpeedMps == 22.25)
        #expect(prior.restoreClass == .moving)
        #expect(prior.converged)
        #expect(prior.handOver)

        var other = Self.sample
        other.source = "auto"
        #expect(other.navigationPrior == prior, "any source converts the same way")
        other.converged = false
        #expect(other.navigationPrior?.converged == false)
        for restoreClass in NavigationRestoreClass.allCases {
            other.restoreClass = restoreClass.rawValue
            #expect(other.navigationPrior?.restoreClass == restoreClass)
        }
    }

    @Test("Prior -> row -> prior is the identity with handOver set; the row keeps the OBD speed and source")
    func roundTrip() throws {
        for handOver in [false, true] {
            let prior = NavigationPrior(
                latitude: -0.0125, longitude: 0.025, covEE: 9, covEN: 0.5, covNN: 4, headingDeg: 359.5,
                headingStdDeg: 40, savedT: MonotonicTimestamp(nanoseconds: -1_234_567_891), lastSpeedMps: 0,
                restoreClass: .parked, converged: false, handOver: handOver)
            let row = NavPriorSample(prior, obdSpeedKmh: nil)
            #expect(row.source == "navigate")
            #expect(row.restoreClass == "parked")
            #expect(row.estimateT == prior.savedT)
            #expect(row.obdSpeedKmh == nil)
            var expected = prior
            expected.handOver = true
            #expect(row.navigationPrior == expected)
            #expect(NavPriorSample(prior, obdSpeedKmh: 3).obdSpeedKmh == 3)
        }
    }

    @Test("A Navigate capture becomes a row on the recording's clock: estimateT = uptime − reference, negative, unclamped")
    func fromCapture() throws {
        // The recording started at uptime 5 000; the estimate is from 1.25 s
        // earlier.
        let clock = SessionClock(referenceUptimeSeconds: 5_000, wallClockStart: Date(timeIntervalSince1970: 2_000_000_000))
        let state = Self.state(uptime: 4_998.75)
        let row = try #require(NavPriorSample(handOver: state, clock: clock))
        #expect(row.estimateT == MonotonicTimestamp(nanoseconds: -1_250_000_000))
        #expect(row.estimateT == clock.timestamp(uptimeSeconds: state.uptimeSeconds))
        #expect(row == NavPriorSample(
            latitude: -0.0125, longitude: 0.025, covEE: 16, covEN: 1, covNN: 9, headingDeg: 12.5, headingStdDeg: 2,
            converged: true, speedMps: 0.5, obdSpeedKmh: 0, restoreClass: "standingStop", source: "navigate",
            estimateT: MonotonicTimestamp(nanoseconds: -1_250_000_000)))
        // The wall clock plays no part: a capture whose savedAt is a day
        // off gives the same row.
        var skewed = state
        skewed.savedAt = state.savedAt.addingTimeInterval(86_400)
        #expect(NavPriorSample(handOver: skewed, clock: clock) == row)
        // Long before the recording: still not clamped.
        let old = try #require(NavPriorSample(handOver: Self.state(uptime: 1_000), clock: clock))
        #expect(old.estimateT == MonotonicTimestamp(nanoseconds: -4_000_000_000_000))
        // Without an OBD reply the row has none.
        #expect(NavPriorSample(handOver: Self.state(uptime: 4_999, obd: nil), clock: clock)?.obdSpeedKmh == nil)
        // The capture's prior on the recording clock is the row's prior.
        let prior = try #require(row.navigationPrior)
        #expect(prior.savedT == row.estimateT && prior.handOver && prior.restoreClass == .standingStop)
    }

    @Test("An invalid capture gives no row")
    func invalidCapture() {
        let clock = SessionClock(referenceUptimeSeconds: 5_000, wallClockStart: Date(timeIntervalSince1970: 0))
        var state = Self.state(uptime: 4_999)
        state.headingDeg = 360
        #expect(NavPriorSample(handOver: state, clock: clock) == nil)
        state = Self.state(uptime: 4_999)
        state.covEE = .nan
        #expect(NavPriorSample(handOver: state, clock: clock) == nil)
        state = Self.state(uptime: 4_999)
        state.uptimeSeconds = 1e300
        #expect(NavPriorSample(handOver: state, clock: clock) == nil, "no trap on an absurd uptime")
    }

    /// `sample` with one bad value; the case name is the field it breaks.
    static func broken(_ name: String) -> (field: String, sample: NavPriorSample) {
        var s = sample
        switch name {
        case "latitude": s.latitude = 90.5
        case "longitude": s.longitude = -.infinity
        case "covEE": s.covEE = -1
        case "covNN": s.covNN = .nan
        case "covEN": s.covEN = 31
        case "headingDeg360": s.headingDeg = 360
        case "headingDegNegative": s.headingDeg = -0.5
        case "headingStdDeg": s.headingStdDeg = -1
        case "speedMps": s.speedMps = -0.1
        case "obdSpeedKmh": s.obdSpeedKmh = -1
        case "restoreClass": s.restoreClass = "towed"
        default: Issue.record("unknown case \(name)")
        }
        return (name.hasPrefix("headingDeg") && name != "headingStdDeg" ? "headingDeg" : name, s)
    }

    @Test("invalidField names the first field a row cannot seed from; such a row converts to nil",
          arguments: ["latitude", "longitude", "covEE", "covNN", "covEN", "headingDeg360", "headingDegNegative",
                      "headingStdDeg", "speedMps", "obdSpeedKmh", "restoreClass"])
    func invalidFields(name: String) {
        let (field, sample) = Self.broken(name)
        #expect(sample.invalidField == field)
        #expect(sample.navigationPrior == nil)
    }

    @Test("Edge values that are legal: heading 0, zero covariance and speed, no OBD speed, any source, positive estimateT")
    func legalEdges() {
        var sample = Self.sample
        sample.headingDeg = 0
        sample.covEE = 0; sample.covEN = 0; sample.covNN = 0
        sample.speedMps = 0
        sample.obdSpeedKmh = nil
        sample.source = "something new"
        sample.latitude = -90; sample.longitude = 180
        sample.estimateT = MonotonicTimestamp(nanoseconds: 1)
        #expect(sample.invalidField == nil)
        #expect(sample.navigationPrior != nil)
    }

    @Test("A row with a non-finite or out-of-range value does not crash the reader: skipped as malformed, or decoded and refused")
    func badRowsDoNotCrash() throws {
        let codec = LogCodec()
        let header = String(decoding: try codec.line(for: LogHeader(
            sessionID: LogFixtures.sessionID, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            referenceUptimeSeconds: 10, app: LogFixtures.app, device: LogFixtures.device)), as: UTF8.self)
        let good = String(decoding: try codec.line(for: LogEvent(timestamp: .zero, payload: .navPrior(Self.sample))), as: UTF8.self)
        let nonFinite = good.replacingOccurrences(of: #""covEE":25"#, with: #""covEE":1e999"#)
        let nan = good.replacingOccurrences(of: #""covNN":36"#, with: #""covNN":NaN"#)
        let missing = good.replacingOccurrences(of: #""estimateT":-850000000,"#, with: "")
        let overflow = good.replacingOccurrences(of: #""estimateT":-850000000"#, with: #""estimateT":99999999999999999999"#)
        let outOfRange = good.replacingOccurrences(of: #""headingDeg":271.5"#, with: #""headingDeg":720"#)
        #expect(nonFinite != good && nan != good && missing != good && overflow != good && outOfRange != good)
        let file = header + nonFinite + nan + missing + overflow + outOfRange + good

        let document = try codec.document(from: Data(file.utf8), recovery: .skipMalformedLines)
        #expect(document.skippedLineIndices == [1, 2, 3, 4])
        #expect(document.events.count == 2)
        guard case .navPrior(let kept) = document.events[0].payload else {
            Issue.record("expected the out-of-range row to decode")
            return
        }
        #expect(kept.headingDeg == 720, "kept as written")
        #expect(kept.invalidField == "headingDeg")
        #expect(kept.navigationPrior == nil)
        #expect(document.events[1].payload == .navPrior(Self.sample))

        #expect(throws: LogDecodingError.self) {
            try codec.document(from: Data(file.utf8), recovery: .strict)
        }
    }

    @Test("A non-finite row handed to the writer becomes a lifecycle error row, not a failure")
    func writerReplacesUnencodableRow() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        var bad = Self.sample
        bad.covEE = .nan
        writer.sink.record(LogEvent(timestamp: .zero, payload: .navPrior(bad)))
        writer.sink.record(LogEvent(timestamp: .zero, payload: .navPrior(Self.sample)))
        try await writer.flush()
        let summary = await writer.finish()
        #expect(summary.failure == nil)
        let read = try WriterFixtures.read(summary.url)
        #expect(read.events.count == 2)
        guard case .lifecycle(let row) = read.events.first?.payload else {
            Issue.record("expected a lifecycle row")
            return
        }
        #expect(row.event == "error")
        #expect(row.detail?.hasPrefix("encodingFailed navPrior:") == true)
        #expect(read.events.last?.payload == .navPrior(Self.sample))
    }

    @Test("navPrior is not a navigation input: the sink does not tap it")
    func notTapped() {
        #expect(!LogSink.isTapped(.navPrior(Self.sample)))
    }
}
