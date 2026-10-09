import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// The N4 A seam: a recording started through `RecordingSession` hands its
// navigation feed to `onNavigationFeed`, and the feed's stream carries the
// recording's navigation inputs in file order. Simulated sources only; what
// real CoreMotion/CoreLocation timing does to it is docs/PLAN.md §6.

/// Takes every feed the session hands over and drains each one off the main
/// actor, as the NavigationService (N4 B) will.
@MainActor
final class FeedCollector {
    private(set) var feeds: [RecordingNavigationFeed] = []
    private var consumers: [Task<[NavigationInput], Never>] = []

    func take(_ feed: RecordingNavigationFeed) {
        feeds.append(feed)
        let inputs = feed.inputs
        consumers.append(Task.detached {
            var collected: [NavigationInput] = []
            for await input in inputs { collected.append(input) }
            return collected
        })
    }

    /// Everything feed `index` delivered; returns once its stream has ended.
    func inputs(of index: Int) async -> [NavigationInput] {
        await consumers[index].value
    }
}

@Suite("Navigation feed", .serialized)
@MainActor
struct NavigationFeedTests {
    static func sources() -> [any SensorSource] {
        [SimulatedMotionSource(rateHz: 100), SimulatedLocationSource(interval: .milliseconds(100)), FakeSource()]
    }

    @Test("A recording hands one feed at Start; its stream gets the recording's navigation inputs in file order and ends at stop")
    func feedCarriesTheRecordingsInputs() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(sources: Self.sources(), store: scratch.store)
        let collector = FeedCollector()
        session.onNavigationFeed = { collector.take($0) }

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(collector.feeds.count == 1)
        let feed = try #require(collector.feeds.first)
        let url = try #require(session.currentFile)
        #expect(feed.recordingURL == url)
        #expect(feed.sidecarURL == LogStore.navSidecarURL(for: url))
        #expect(feed.generation == session.currentGeneration)
        try await Task.sleep(for: .milliseconds(600))
        await session.stop()

        let live = await collector.inputs(of: 0)   // returns only because the stream ended
        let (header, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil && !report.truncatedTail)
        // The feed's header is the one the writer encoded: the same line once
        // encoded (in memory `startedAt` has sub-second precision that the
        // file's ISO 8601 date drops), the same sessionID exactly.
        let codec = LogCodec()
        #expect(try codec.header(from: codec.line(for: feed.header)) == header)
        #expect(feed.header.sessionID == header.sessionID)
        #expect(feed.clock.referenceUptimeSeconds == header.referenceUptimeSeconds)

        let fileInputs = events.compactMap(NavigationInput.init)
        #expect(live.contains { if case .motion = $0 { true } else { false } })
        #expect(live.contains { if case .location = $0 { true } else { false } })
        #expect(live.count > 40)
        #expect(live == fileInputs)
        #expect(feed.droppedInputs == 0)
        // The tap took nothing from the file: accel rows and every other kind are still there.
        #expect(RecordingFixtures.kinds(events, .accelerometer).count > 30)
        #expect(RecordingFixtures.index(of: .stop, in: events) != nil)
        // A is the seam only: nothing writes the sidecar yet.
        #expect(!FileManager.default.fileExists(atPath: feed.sidecarURL.path))
    }

    @Test("Each recording gets a fresh feed; a write failure ends the feed too")
    func freshFeedPerRecordingAndFailureEndsIt() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(sources: Self.sources(), store: scratch.store)
        let collector = FeedCollector()
        session.onNavigationFeed = { collector.take($0) }

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        try await Task.sleep(for: .milliseconds(200))
        let first = try #require(collector.feeds.first)
        await session.handleWriteFailure(.diskFull, generation: first.generation)
        #expect(session.state == .failed(reason: "disk full", unwrittenEvents: 0))
        let firstInputs = await collector.inputs(of: 0)
        #expect(!firstInputs.isEmpty)

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(collector.feeds.count == 2)
        let second = collector.feeds[1]
        #expect(second.generation != first.generation)
        #expect(second.recordingURL != first.recordingURL)
        #expect(second.tap !== first.tap)
        try await Task.sleep(for: .milliseconds(200))
        await session.stop()
        let secondInputs = await collector.inputs(of: 1)
        let (_, events, _) = try RecordingFixtures.read(second.recordingURL)
        #expect(secondInputs == events.compactMap(NavigationInput.init))
        // Nothing from the first recording leaks into the second feed.
        #expect(secondInputs.first.map { $0.timestamp.seconds < 1 } == true)
    }

    @Test("Without a listener the recording is unchanged and complete")
    func noListener() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(sources: Self.sources(), store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        try await Task.sleep(for: .milliseconds(300))
        await session.stop()
        #expect(session.state == .idle)
        let (_, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil)
        #expect(RecordingFixtures.kinds(events, .motion).count > 10)
        #expect(RecordingFixtures.lifecycle(events).first?.sample.event == "start")
    }
}
