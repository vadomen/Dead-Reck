import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// N4 B: the NavigationService consumes each recording's navigation feed,
// runs a fresh engine per recording and writes the sidecar. Simulated
// sources and synthetic feeds only; real sensor timing, ms/step on an iPhone
// and Mac-vs-iPhone bit equality are docs/PLAN.md §6.

/// Starts the service on every feed, as `AppServices` does, and keeps the
/// consuming tasks so a test can wait for a feed to be fully processed.
@MainActor
final class ServiceHarness {
    let service: NavigationService
    private(set) var feeds: [RecordingNavigationFeed] = []
    private var tasks: [Task<Void, Never>] = []

    init(service: NavigationService = NavigationService()) {
        self.service = service
    }

    func take(_ feed: RecordingNavigationFeed) {
        feeds.append(feed)
        tasks.append(service.start(feed))
    }

    /// Returns once feed `index` has ended and its sidecar is closed.
    func finished(_ index: Int) async {
        await tasks[index].value
    }
}

@Suite("Navigation service", .serialized)
@MainActor
struct NavigationServiceTests {
    static func sources() -> [any SensorSource] {
        [SimulatedMotionSource(rateHz: 100), SimulatedLocationSource(interval: .milliseconds(200)), FakeSource()]
    }

    /// What `replay_nav --as-live --compare` does with a recording and its
    /// sidecar: the Core loop over the file's inputs in file order, with
    /// the header's seed and the default config.
    static func asLiveComparison(recording: URL, sidecar: URL) throws -> (SidecarComparison, NavSidecar.Contents) {
        let (header, events, _) = try RecordingFixtures.read(recording)
        let contents = try NavSidecar.read(contentsOf: sidecar)
        let config = NavigationConfig(seed: NavigationSeed.derive(header: header))
        let lines = NavigationReplay.liveLines(inputs: NavigationReplay.fileOrderInputs(from: events),
                                               sessionID: header.sessionID, config: config)
        return (SidecarComparison(sidecar: contents, replay: lines, replayConfig: config,
                                  encodingFailures: NavigationReplay.encodingFailures(in: events).count), contents)
    }

    @Test("A fresh engine per recording: two recordings, two runs, each sidecar what a fresh engine gives on its own file")
    func freshEnginePerRecording() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(sources: Self.sources(), store: scratch.store)
        let harness = ServiceHarness()
        session.onNavigationFeed = { harness.take($0) }

        for index in 0..<2 {
            try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
            let generation = harness.feeds[index].generation
            try await Task.sleep(for: .milliseconds(1_800))
            let live = await harness.service.snapshot()
            #expect(live.sessionID == harness.feeds[index].header.sessionID)
            #expect(live.initialized, "simulated fixes initialise the engine")
            #expect(await harness.service.currentGeneration == generation)
            await session.stop()
            await harness.finished(index)
        }

        let service = harness.service
        #expect(await service.runsStarted == 2)
        let finished = await service.finished
        #expect(finished.count == 2)
        #expect(finished.map(\.generation) == harness.feeds.map(\.generation))
        #expect(Set(finished.map(\.sessionID)).count == 2)
        #expect(await service.snapshot(at: .zero) == .idle(at: .zero), "no recording: idle")

        for (index, feed) in harness.feeds.enumerated() {
            let (comparison, contents) = try Self.asLiveComparison(recording: feed.recordingURL, sidecar: feed.sidecarURL)
            #expect(contents.header.seed == NavigationSeed.derive(header: feed.header))
            #expect(contents.header.sessionID == feed.header.sessionID)
            #expect(contents.header.configHash == NavigationConfig(seed: contents.header.seed).hashHex)
            #expect(contents.header.appBuild == feed.header.app.build)
            #expect(contents.estimates.count >= 1, "recording \(index)")
            // A carried-over engine would not reproduce a fresh one's output.
            #expect(comparison.exact, "recording \(index): \(comparison.report(tolerance: .default))")
            #expect(finished[index].sidecarFailure == nil && finished[index].sidecarLinesLost == 0)
        }
    }

    @Test("The sidecar is written and closed on stop: header, 1 Hz estimates and the pin at the confirmed manual fix")
    func sidecarWrittenAndClosedOnStop() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, sources: Self.sources(), store: scratch.store)
        let harness = ServiceHarness()
        session.onNavigationFeed = { harness.take($0) }

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let feed = try #require(harness.feeds.first)
        try await Task.sleep(for: .milliseconds(1_300))
        link.send(RecordingSessionManualFixTests.reading(5))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 5 })
        // Pin next to the simulated track (no literal coordinates here).
        let near = try #require(session.live.referenceFix)
        let pinLatitude = near.latitude + 0.000_1, pinLongitude = near.longitude + 0.000_2
        let press = try #require(session.manualFixPressTime())
        #expect(session.recordManualFix(latitude: pinLatitude, longitude: pinLongitude, pressedAt: press, mapSpanM: 240, note: nil))
        try await Task.sleep(for: .milliseconds(1_200))
        // Mid-recording the sidecar holds at least the header (flushed at start).
        let early = try NavSidecar.read(contentsOf: feed.sidecarURL)
        #expect(early.header.sessionID == feed.header.sessionID)
        await session.stop()
        await harness.finished(0)

        let data = try Data(contentsOf: feed.sidecarURL)
        #expect(data.last == 0x0A, "closed after a whole line")
        let (comparison, contents) = try Self.asLiveComparison(recording: feed.recordingURL, sidecar: feed.sidecarURL)
        #expect(!contents.truncatedLastLine && contents.unrecognizedLines == 0)
        #expect(contents.estimates.count >= 2)
        #expect(contents.estimates.allSatisfy { $0.t.nanoseconds % 1_000_000_000 == 0 && $0.msPerStep != nil })
        let pin = try #require(contents.pins.first)
        #expect(contents.pins.count == 1)
        #expect(pin.latitude == pinLatitude && pin.longitude == pinLongitude && pin.mapSpanM == 240)
        #expect(pin.prior != nil, "the engine was initialised by fixes before the pin")
        let (_, events, _) = try RecordingFixtures.read(feed.recordingURL)
        let fixT = events.first { if case .manualFix = $0.payload { true } else { false } }?.timestamp
        #expect(pin.t == fixT)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        #expect(comparison.pins.matched == 1)
        let summary = try #require(await harness.service.finished.first)
        #expect(summary.sidecarFailure == nil && summary.sidecarBytes == data.count)
        #expect(summary.estimates == contents.estimates.count)
    }

    // MARK: Drops

    static let header = LogHeader(
        sessionID: UUID(uuidString: "00000000-0000-4000-8000-0000000000B4")!,
        startedAt: Date(timeIntervalSince1970: 0),
        referenceUptimeSeconds: 100,
        app: AppIdentity(name: "DriveLogger", version: "0.0", build: "7"),
        device: DeviceIdentity(model: "test", systemName: "iOS", systemVersion: "17")
    )

    static func motion(_ t: Double) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .motion(MotionSample(
            userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1), rotationRate: .zero, attitude: .identity)))
    }

    static func fix(_ t: Double) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .location(LocationSample(
            latitude: 0.001, longitude: 0.002, altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1,
            speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
            receivedT: MonotonicTimestamp(seconds: t), ageS: 0)))
    }

    @Test("Drops are surfaced: the snapshot and every sidecar estimate carry the feed's droppedInputs")
    func dropsAreSurfaced() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        // A feed whose consumer starts 100 inputs late with room for 8: the
        // oldest 92 are dropped; the newest 8 are a fix and 7 motion samples.
        let tap = NavigationTap(bufferLimit: 8)
        for k in 0..<92 { tap.record(Self.motion(Double(k) * 0.01)) }
        tap.record(Self.fix(1.0))
        for k in 1...7 { tap.record(Self.motion(1.0 + Double(k) * 0.5)) }
        #expect(tap.droppedInputs == 92)
        let recording = scratch.store.directory.appendingPathComponent("Drive_synthetic.jsonl.gz")
        let feed = RecordingNavigationFeed(
            generation: 1, header: Self.header, clock: SessionClock(header: Self.header),
            recordingURL: recording, sidecarURL: LogStore.navSidecarURL(for: recording), tap: tap)

        let harness = ServiceHarness()
        harness.take(feed)
        var snapshot = await harness.service.snapshot(at: MonotonicTimestamp(seconds: 4.5))
        let deadline = ContinuousClock.now + .seconds(5)
        while snapshot.stats.inputs < 8 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = await harness.service.snapshot(at: MonotonicTimestamp(seconds: 4.5))
        }
        #expect(snapshot.stats.inputs == 8)
        #expect(snapshot.stats.droppedInputs == 92)
        #expect(snapshot.initialized && snapshot.latitude != nil && snapshot.ellipse != nil)
        #expect(snapshot.sessionID == Self.header.sessionID)
        #expect(snapshot.stats.steps > 0 && snapshot.stats.effectiveSampleSize != nil)
        #expect(!snapshot.converged, "a network fix gives no heading")

        tap.finish()
        await harness.finished(0)
        let contents = try NavSidecar.read(contentsOf: feed.sidecarURL)
        #expect(contents.estimates.map(\.t.seconds) == [2, 3, 4])
        #expect(contents.estimates.allSatisfy { $0.droppedInputs == 92 })
        #expect(contents.droppedInputs == 92)
        #expect(await harness.service.finished.first?.droppedInputs == 92)
        #expect(await harness.service.snapshot(at: .zero).sessionID == nil)
    }
}
