import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Format v5 `navPrior`, recorder side (prompt 40): `navPriorProvider` is
// asked once per recording at Start, on the recording's clock, after
// Navigate has ended; its sample is written right after the `start` row,
// before the start-up init replay and every engine input, and handed to the
// navigation feed. No provider, or nil: no row and the file as before.
// Engine seeding is the navigation service's (not tested here). Fakes from
// RecordingTestSupport.swift, `NavigateRig` from
// RecordingSessionNavigateTests.swift. Coordinates are small offsets from
// (0, 0).

/// What the provider saw each time it was asked.
@MainActor
final class NavPriorProbe {
    struct Ask {
        let clock: SessionClock
        let navigateState: NavigateState
    }

    private(set) var asks: [Ask] = []
    /// Built from the clock it is asked with; nil: start fresh.
    var answer: (SessionClock) -> NavPriorSample?

    init(answer: @escaping (SessionClock) -> NavPriorSample?) {
        self.answer = answer
    }

    func install(on session: RecordingSession) {
        session.navPriorProvider = { [unowned self, unowned session] clock in
            self.asks.append(Ask(clock: clock, navigateState: session.navigateState))
            return self.answer(clock)
        }
    }
}

@Suite("RecordingSession navPrior (v5)", .serialized)
@MainActor
struct RecordingNavPriorTests {
    /// A converged moving estimate whose time is `uptime`, on `clock`.
    static func sample(on clock: SessionClock, uptime: Double, headingDeg: Double = 90) -> NavPriorSample {
        NavPriorSample(
            latitude: 0.0125, longitude: -0.025, covEE: 25, covEN: -2.5, covNN: 36,
            headingDeg: headingDeg, headingStdDeg: 3.25, converged: true, speedMps: 10, obdSpeedKmh: 36,
            restoreClass: NavigationRestoreClass.moving.rawValue, source: NavPriorSample.Source.navigate.rawValue,
            estimateT: clock.timestamp(uptimeSeconds: uptime))
    }

    static func navPriors(_ events: [LogEvent]) -> [(index: Int, t: MonotonicTimestamp, sample: NavPriorSample)] {
        events.enumerated().compactMap { offset, event in
            if case .navPrior(let sample) = event.payload { (offset, event.timestamp, sample) } else { nil }
        }
    }

    static func firstEngineInput(_ events: [LogEvent]) -> Int? {
        events.firstIndex { ["motion", "location", "obd"].contains($0.payload.kind) }
    }

    @Test("Navigate → Record with a provider: asked once after Navigate ended, on the recording's clock; one navPrior row right after start, before the init replay (with its obd row) and every input; the feed carries it")
    func handOverRow() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let rig = NavigateRig(store: scratch.store, undoWindow: .milliseconds(50))
        let probe = NavPriorProbe { clock in Self.sample(on: clock, uptime: NavigateRig.base + 49.25) }
        probe.install(on: rig.session)
        await rig.connect(speed: 0)
        // The replay carries an `obd` row too: the prior must precede it.
        rig.link.lastInitEvents += InitScript.poll(seq: 20, speed: 30, at: NavigateRig.base - 1)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let navigate = try #require(rig.session.navigateGeneration)
        await rig.drive(0..<1)
        #expect(probe.asks.isEmpty, "a Navigate run never asks")

        rig.uptime.set(NavigateRig.base + 50)
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        let url = try #require(rig.session.currentFile)
        #expect(probe.asks.count == 1)
        let ask = try #require(probe.asks.first)
        #expect(ask.navigateState == .off, "Navigate had ended when the provider was asked")
        #expect(ask.clock.referenceUptimeSeconds == NavigateRig.base + 50)
        let expected = Self.sample(on: ask.clock, uptime: NavigateRig.base + 49.25)
        #expect(expected.estimateT == MonotonicTimestamp(nanoseconds: -750_000_000))

        // Record's own inputs.
        let clock = try #require(rig.source.clock)
        rig.uptime.set(NavigateRig.base + 51)
        rig.source.emit([NavigationServiceNavigateTests.motion(clock.now().seconds),
                         NavigationServiceNavigateTests.fix(clock.now().seconds)])
        await rig.send(InitScript.poll(seq: 500, speed: 20, at: NavigateRig.base + 51))
        await rig.session.stop()
        #expect(probe.asks.count == 1, "asked once per recording; the Navigate run after it never asks")

        // The feed: Record's carries the row as written, Navigate's none.
        let feeds = rig.tee.feeds
        let recordFeed = try #require(feeds.first { $0.generation == record })
        #expect(recordFeed.navPrior == expected)
        #expect(feeds.filter { $0.generation != record }.allSatisfy { $0.navPrior == nil })
        #expect(feeds.first?.generation == navigate)

        let (header, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil && !report.truncatedTail)
        #expect(header.formatVersion == .v5)
        #expect(header.referenceUptimeSeconds == ask.clock.referenceUptimeSeconds, "the clock the provider got is the file's")
        let rows = Self.navPriors(events)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.index == 1, "right after the start row")
        #expect(row.sample == expected, "written field for field; estimateT negative and not clamped")
        #expect(row.t == .zero, "stamped clock.now() at Start")
        #expect(events[0].payload == .lifecycle(LifecycleSample(.start)))
        let replay = events.dropFirst(2).prefix { $0.timestamp.nanoseconds < 0 }
        #expect(replay.contains { $0.payload.kind == "obd" }, "the replay's obd row follows the prior")
        #expect(replay.count == 19, "→ connected, the 16-event init and the poll's two rows: \(replay.count)")
        let firstInput = try #require(Self.firstEngineInput(events))
        #expect(row.index < firstInput)
        for kind in [LogEventKind.motion, .location, .obd] {
            #expect(RecordingFixtures.kinds(events, kind).allSatisfy { $0 > row.index }, "\(kind)")
        }
        // No error row.
        #expect(!RecordingFixtures.lifecycle(events).contains { $0.sample.event == "error" })
        // The analysis sees one healthy prior.
        var analyzer = RecordingAnalyzer(header: header)
        for event in events { analyzer.observe(event) }
        let summary = analyzer.summary(report: LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: []))
        #expect(summary.navPriors.count == 1 && summary.navPriors.first?.afterFirstInput == false)
        #expect(!summary.healthWarnings.contains { $0.contains("navPrior") })

        rig.session.disableNavigate()
    }

    /// Records a short session on a `FakeLink` with a start-up init in its
    /// replay, `configure`d before Start; returns the file's events and the
    /// recording's feed.
    static func record(scratch: ScratchStore,
                       configure: (RecordingSession) -> Void) async throws -> (events: [LogEvent], feed: RecordingNavigationFeed) {
        let link = FakeLink()
        let base = ProcessInfo.processInfo.systemUptime
        link.lastInitEvents = [InitScript.connection(at: base - 10)[2]]
            + InitScript.initialisation(firstSeq: 1) { base - 9 + Double($0) * 0.05 }
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        var feeds: [RecordingNavigationFeed] = []
        session.onNavigationFeed = { feeds.append($0) }
        configure(session)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(await eventually(2) { (try? RecordingFixtures.read(url).events.contains { $0.payload.kind == "accel" }) == true })
        await session.stop()
        let feed = try #require(feeds.last)
        #expect(feeds.count == 1)
        return (try RecordingFixtures.read(url).events, feed)
    }

    /// Kinds of the rows up to the first source sample: the start-up part.
    static func startKinds(_ events: [LogEvent]) -> [String] {
        Array(events.prefix { !["accel", "gyro", "mag", "baro", "motion", "location", "obd"].contains($0.payload.kind) }
            .map(\.payload.kind))
    }

    @Test("No provider, or a provider that returns nil: no navPrior row, the start of the file as before, nil in the feed")
    func noPrior() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let none = try await Self.record(scratch: scratch) { _ in }
        #expect(Self.navPriors(none.events).isEmpty)
        #expect(none.feed.navPrior == nil)
        let start = Self.startKinds(none.events)
        #expect(start.first == "lifecycle" && start.dropFirst().first == "link", "the init replay right after start: \(start)")
        #expect(!none.events.contains { $0.payload.kind == "navPrior" })

        let probe = NavPriorProbe { _ in nil }
        let fresh = try await Self.record(scratch: scratch) { probe.install(on: $0) }
        #expect(probe.asks.count == 1)
        #expect(Self.navPriors(fresh.events).isEmpty)
        #expect(fresh.feed.navPrior == nil)
        #expect(Self.startKinds(fresh.events) == start, "nil changes nothing")
        #expect(!RecordingFixtures.lifecycle(fresh.events).contains { $0.sample.event == "error" })
    }

    @Test("An invalid sample is neither written nor handed over: an error row names the field, the run starts fresh")
    func invalidPrior() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let probe = NavPriorProbe { clock in
            Self.sample(on: clock, uptime: clock.referenceUptimeSeconds - 1, headingDeg: 360)
        }
        let result = try await Self.record(scratch: scratch) { probe.install(on: $0) }
        #expect(probe.asks.count == 1)
        #expect(Self.navPriors(result.events).isEmpty)
        #expect(result.feed.navPrior == nil)
        let lifecycle = RecordingFixtures.lifecycle(result.events)
        let error = try #require(lifecycle.first { $0.sample.event == "error" })
        #expect(error.index == 1, "where the row would have been")
        #expect(error.sample.detail == "navPrior invalid: headingDeg")
    }

    @Test("A valid sample on a plain recording (no Navigate run): the row at index 1 with the feed's sample")
    func plainRecording() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        var given: NavPriorSample?
        let probe = NavPriorProbe { clock in
            let sample = Self.sample(on: clock, uptime: clock.referenceUptimeSeconds - 3_600)
            given = sample
            return sample
        }
        let result = try await Self.record(scratch: scratch) { probe.install(on: $0) }
        let rows = Self.navPriors(result.events)
        #expect(rows.map(\.index) == [1])
        let sample = try #require(given)
        #expect(rows.first?.sample == sample)
        #expect(sample.estimateT.nanoseconds <= -3_600_000_000_000 + 1_000, "an hour old, not clamped")
        #expect(result.feed.navPrior == sample)
        let firstSample = try #require(result.events.firstIndex { $0.payload.kind == "accel" })
        #expect(1 < firstSample)
        #expect(Self.startKinds(result.events).prefix(3) == ["lifecycle", "navPrior", "link"])
    }
}
