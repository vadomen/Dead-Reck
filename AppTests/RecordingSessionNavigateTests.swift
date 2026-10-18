import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// UX-1 Navigate, recorder side: the mode state machine and the tap-only
// sink. Fakes from RecordingTestSupport.swift; link scripts from
// StartupInitRecordingTests.swift (`InitScript`); drive shapes and the
// file-system footprint from NavigationServiceNavigateTests.swift. No
// hardware: what CoreLocation, CoreMotion and suspension really do is in
// docs/PLAN.md §6.

/// An uptime the test sets, so two sessions get clocks with the same
/// reference and `clock.now()` is the script's time.
final class FakeUptime: UptimeSource {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var value: Double

    init(_ value: Double) { self.value = value }

    func set(_ seconds: Double) { lock.withLock { value = seconds } }

    var uptimeSeconds: Double { lock.withLock { value } }
}

/// A source that records exactly what the test hands it, into whichever
/// sink it was started with; and, like `ReferenceLocationSource`, is told
/// before each start whether to hold background location.
@MainActor
final class ScriptedSource: SensorSource, BackgroundLocationConfigurable {
    let name = "scripted"
    let availability = SensorAvailability.available
    var holdsBackgroundLocation = true
    /// `holdsBackgroundLocation` at each `start`, in order.
    private(set) var startedWithBackgroundLocation: [Bool] = []
    private(set) var stops = 0
    private(set) var clock: SessionClock?
    private var sink: LogSink?

    var isRunning: Bool { sink != nil }

    func start(clock: SessionClock, sink: LogSink) throws {
        startedWithBackgroundLocation.append(holdsBackgroundLocation)
        self.clock = clock
        self.sink = sink
    }

    func stop() {
        if sink != nil { stops += 1 }
        sink = nil
    }

    func emit(_ events: [LogEvent]) {
        for event in events { sink?.record(event) }
    }
}

extension LogEvent {
    /// The row a navigation input came from.
    init(_ input: NavigationInput) {
        switch input {
        case .motion(let sample, let t): self.init(timestamp: t, payload: .motion(sample))
        case .obd(let sample, let t): self.init(timestamp: t, payload: .obd(sample))
        case .location(let sample, let t): self.init(timestamp: t, payload: .location(sample))
        case .manualFix(let sample, let t): self.init(timestamp: t, payload: .manualFix(sample))
        }
    }
}

/// `onNavigationFeed` for tests: keeps every feed, collects each feed's
/// inputs in order, and passes them on unchanged (same order, same values)
/// to a `NavigationService` through a proxy tap.
@MainActor
final class FeedTee {
    let service: NavigationService
    private(set) var feeds: [RecordingNavigationFeed] = []
    private(set) var inputs: [Int: [NavigationInput]] = [:]
    /// Generations whose feed has ended and whose service run finished.
    private(set) var ended: Set<Int> = []

    init(service: NavigationService = NavigationService()) {
        self.service = service
    }

    func handle(_ feed: RecordingNavigationFeed) {
        feeds.append(feed)
        let proxy = NavigationTap()
        let run = service.start(RecordingNavigationFeed(
            generation: feed.generation, header: feed.header, clock: feed.clock, output: feed.output, tap: proxy))
        let generation = feed.generation
        inputs[generation] = []
        Task { @MainActor in
            for await input in feed.inputs {
                self.inputs[generation, default: []].append(input)
                proxy.record(LogEvent(input))
            }
            proxy.finish()
            await run.value
            self.ended.insert(generation)
        }
    }

    func feed(_ generation: Int) -> RecordingNavigationFeed? {
        feeds.first { $0.generation == generation }
    }
}

/// What `mapFixOnArrival` saw from inside a recording's Stop.
@MainActor
final class LateFixProbe {
    var state: RecordingState?
    var fix: LocationSample?
}

/// One session on a `FakeLink` and a `ScriptedSource`, its uptime on the
/// script's clock, and the drive the test feeds it.
@MainActor
final class NavigateRig {
    static let base = 1_000.0

    let link = FakeLink()
    let source = ScriptedSource()
    let uptime = FakeUptime(NavigateRig.base)
    let idle = IdleTimerSpy()
    let tee: FeedTee
    let session: RecordingSession
    /// Navigation inputs the script produced after the session started
    /// (motion, fixes, speed readings, committed pins).
    private(set) var inputsSent = 0
    private var seq = 100

    /// - Parameter idNamespace: the first group of every `sessionID` this
    ///   session makes (then 1, 2, … per session); two rigs with the same
    ///   namespace seed their engines alike. Random by default, so files a
    ///   test looks for by `sessionID` are its own.
    init(store: LogStore, service: NavigationService = NavigationService(), extraSources: [any SensorSource] = [],
         displayLocation: (any DisplayLocationProviding)? = nil,
         disk: FakeDisk = FakeDisk(RecordingFixtures.roomy), undoWindow: Duration = .milliseconds(150),
         idNamespace: UInt32 = .random(in: 1...UInt32.max)) {
        tee = FeedTee(service: service)
        var counter = 0
        let idle = idle
        session = RecordingSession(
            link: link,
            sources: [source] + extraSources,
            displayLocation: displayLocation,
            store: store,
            uptime: uptime,
            diskSpace: disk,
            sensorConfiguration: RecordingFixtures.sensors,
            notes: "test",
            app: RecordingFixtures.app,
            device: RecordingFixtures.device,
            flushInterval: .milliseconds(100),
            statsInterval: .milliseconds(300),
            diskRefreshInterval: .seconds(3_600),
            manualFixUndoWindow: undoWindow,
            setIdleTimerDisabled: { idle.set($0) },
            beginBackgroundTask: { _ in {} },
            makeSessionID: {
                counter += 1
                return Self.sessionID(idNamespace, counter)
            }
        )
        let tee = tee
        session.onNavigationFeed = { tee.handle($0) }
    }

    static func sessionID(_ namespace: UInt32, _ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-%012d", namespace, n))!
    }

    /// The link connected and initialised before anything starts, as the
    /// real one does: `→ connected`, a full init, one poll at `speed` (nil:
    /// none), all consumed by the session; `lastInitEvents` as the link
    /// keeps it.
    func connect(speed: Double? = 0) async {
        let connection = InitScript.connection(at: Self.base - 10)
        let initialisation = InitScript.initialisation(firstSeq: 1) { Self.base - 9 + Double($0) * 0.05 }
        let polls = speed.map { InitScript.poll(seq: 20, speed: $0, at: Self.base - 1) } ?? []
        let events = connection + initialisation + polls
        let consumed = session.consumedLinkEvents
        for event in events { link.send(event) }
        link.lastInitEvents = [connection[2]] + initialisation
        #expect(await eventually(5) { self.session.consumedLinkEvents == consumed + events.count })
    }

    /// Sends link events and waits until the session has handled them.
    func send(_ events: [LinkEvent]) async {
        let consumed = session.consumedLinkEvents
        for event in events { link.send(event) }
        #expect(await eventually(5) { self.session.consumedLinkEvents == consumed + events.count })
    }

    /// 0.2 s of driving from `t0` (script seconds, on the session clock):
    /// motion at 50 Hz from the source, one poll (exchange + speed reading)
    /// over the link in the middle, a fix on whole seconds while
    /// `t0 <= fixesUntil`. In time order; the poll is handled before the
    /// rest is recorded, so the tap order is the same every run.
    func step(_ t0: Double, kmh: Double = 36, fixesUntil: Double = 6) async {
        typealias S = NavigationServiceNavigateTests
        var first: [LogEvent] = []
        for k in 0..<5 { first.append(S.motion(t0 + Double(k) * 0.02, yawRate: 0.002)) }
        let whole = (t0 * 5).rounded() / 5
        if t0 > 0, t0 <= fixesUntil, abs(whole - whole.rounded()) < 1e-9 { first.insert(S.fix(t0), at: 0) }
        uptime.set(Self.base + t0 + 0.09)
        source.emit(first)
        await send(InitScript.poll(seq: seq, speed: kmh, at: Self.base + t0 + 0.09))
        seq += 1
        let second = (5..<10).map { S.motion(t0 + Double($0) * 0.02, yawRate: 0.002) }
        uptime.set(Self.base + t0 + 0.2)
        source.emit(second)
        inputsSent += first.count + 1 + second.count
    }

    /// `step`s covering `range` (start inclusive, end exclusive).
    func drive(_ range: Range<Double>, kmh: Double = 36, fixesUntil: Double = 6) async {
        var t = range.lowerBound
        while t < range.upperBound - 1e-9 {
            await step(t, kmh: kmh, fixesUntil: fixesUntil)
            t = ((t + 0.2) * 5).rounded() / 5
        }
    }

    /// Stages a pin at the script's position at `t` (span 200 m) and waits
    /// for its undo window to close: the pin is committed.
    func pin(at t: Double) async throws -> MonotonicTimestamp {
        let p = NavigationServiceNavigateTests.position(t)
        let tapT = try #require(session.manualFixTapTime())
        _ = try #require(session.stageManualFix(latitude: p.latitude, longitude: p.longitude, tapT: tapT, mapSpanM: 200))
        #expect(await eventually(5) { self.session.pendingManualFixes.isEmpty })
        inputsSent += 1
        return tapT
    }

    /// Waits until the tee has `count` inputs of `generation` and the
    /// service's current run has ingested them all.
    func settled(_ generation: Int, _ count: Int) async -> Bool {
        guard await eventually(30, { self.tee.inputs[generation]?.count == count }) else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if await tee.service.snapshot(at: .zero).stats.inputs == count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func snapshots(at times: [Double]) async -> [NavigationSnapshot] {
        await NavigationServiceNavigateTests.snapshots(tee.service, at: times)
    }
}

@Suite("RecordingSession Navigate mode (UX-1)", .serialized)
@MainActor
struct RecordingSessionNavigateTests {
    static let quick = NavigateConfiguration(stillCalibration: .milliseconds(200), autoStopAfter: .seconds(600))

    static func kinds(_ inputs: [NavigationInput]) -> [String: Int] {
        var out: [String: Int] = [:]
        for input in inputs { out[LogEvent(input).payload.kind, default: 0] += 1 }
        return out
    }

    /// The same session clock: same reference uptime and wall-clock start
    /// (`SessionClock` is a value).
    static func same(_ a: SessionClock?, _ b: SessionClock) -> Bool {
        a?.referenceUptimeSeconds == b.referenceUptimeSeconds && a?.wallClockStart == b.wallClockStart
    }

    /// A store whose directory does not exist; Navigate must never create it.
    static func absentStore() -> LogStore {
        LogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-navigate-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: Equivalence

    @Test("The same sources and link events through Navigate and through Record: identical inputs and bit-identical estimates")
    func navigateEqualsRecord() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let times = [12.0, 12.5, 15]

        struct Run {
            var inputs: [NavigationInput]
            var snapshots: [NavigationSnapshot]
            var header: LogHeader
            var output: RecordingNavigationFeed.Output
        }
        var runs: [Run] = []
        let namespace = UInt32.random(in: 1...UInt32.max)
        for mode in ["record", "navigate"] {
            let rig = NavigateRig(store: scratch.store, idNamespace: namespace)
            await rig.connect(speed: 0)
            if mode == "record" {
                try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
            } else {
                rig.session.enableNavigate(Self.quick)
                #expect(rig.session.navigateState == .calibrating)
                #expect(rig.session.state == .idle && rig.session.currentFile == nil)
            }
            let feed = try #require(rig.tee.feeds.last)
            await rig.drive(0..<8)
            _ = try await rig.pin(at: 7.9)
            await rig.drive(8..<12, fixesUntil: 0)
            #expect(await rig.settled(feed.generation, rig.inputsSent))
            runs.append(Run(inputs: rig.tee.inputs[feed.generation] ?? [], snapshots: await rig.snapshots(at: times),
                            header: feed.header, output: feed.output))
            if mode == "record" { await rig.session.stop() } else { rig.session.disableNavigate() }
            #expect(await eventually(10) { rig.tee.ended.contains(feed.generation) })
        }
        let (record, navigate) = (runs[0], runs[1])
        #expect(navigate.output == .navigateOnly)
        #expect(record.output != .navigateOnly)
        #expect(navigate.header.sessionID == record.header.sessionID, "same seed")
        #expect(navigate.header.referenceUptimeSeconds == record.header.referenceUptimeSeconds)
        #expect(navigate.header.adapter == record.header.adapter && navigate.header.polling == record.header.polling)
        let kinds = Self.kinds(record.inputs)
        #expect(kinds["motion"] == 600 && kinds["obd"] == 60 && kinds["location"] == 6 && kinds["manualFix"] == 1,
                "\(kinds)")
        #expect(navigate.inputs == record.inputs)
        #expect(record.snapshots.allSatisfy { $0.initialized && $0.estimate != nil })
        #expect(navigate.snapshots == record.snapshots)
    }

    // MARK: Nothing written

    @Test("A Navigate drive with pins, a link drop and a roads attach writes nothing anywhere but the packs' verification cache")
    func navigateWritesNothing() async throws {
        typealias S = NavigationServiceNavigateTests
        await FootprintLock.shared.acquire()
        defer { FootprintLock.shared.release() }
        let packs = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: packs) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: packs)
        // The app's real verification cache, as `makeDefault()` uses it, set
        // aside (removed) so the run's rescan must write it: the one file a
        // Navigate run may write, and it may hold nothing of the drive.
        let cache = try S.SetAsideCache()
        defer { cache.restore() }
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
        let service = NavigationService(
            flushInterval: .milliseconds(1),
            library: RoadPackLibrary(source: RoadPackLibrary.directorySource(packs), cacheURL: cache.url))
        let store = Self.absentStore()
        let tempBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        let before = NavigationServiceNavigateTests.Footprint()

        let rig = NavigateRig(store: store, service: service)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.quick)
        let feed = try #require(rig.tee.feeds.last)
        #expect(feed.output == .navigateOnly && feed.recordingURL == nil && feed.sidecarURL == nil)
        await rig.drive(0..<6)
        #expect(await eventually(30) {
            // Roads attach once the library scan is in and the engine asks.
            rig.tee.inputs[feed.generation]?.count == rig.inputsSent
        })
        let attached = await {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if await service.roadsStatus().inUse { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }()
        #expect(attached, "roads attached in Navigate")
        _ = try await rig.pin(at: 5.9)
        rig.session.handleScenePhase(.background)
        rig.session.handleScenePhase(.active)
        rig.link.state = .reconnecting(attempt: 1)
        #expect(await eventually(5) { if case .waitingForOBD = rig.session.navigateState { true } else { false } })
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { rig.session.navigateState == .running })
        await rig.drive(6..<10, fixesUntil: 0)
        _ = try await rig.pin(at: 9.9)
        #expect(await rig.settled(feed.generation, rig.inputsSent))
        rig.session.handleWillTerminate()
        #expect(await eventually(10) { rig.tee.ended.contains(feed.generation) })

        let finished = try #require(await service.finished.first { $0.generation == feed.generation })
        #expect(finished.sidecarURL == nil && finished.sidecarBytes == 0)
        #expect(finished.roadPackNames == ["fixture.roadpack"])
        #expect(Self.kinds(rig.tee.inputs[feed.generation] ?? [])["manualFix"] == 2)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "no recordings directory")
        // One change in Documents and Application Support, the cache the
        // scan rewrote; no new or modified file anywhere names the session.
        #expect(before.writtenSince(sessionID: feed.header.sessionID)
                == ["Application Support/" + RoadPackLibrary.cacheFileName])
        // It holds the pack and nothing of the drive: fixes at 1…5 s (6 too,
        // to spare), the pins at 5.9 and 9.9 s.
        S.expectCacheIsPacksOnly(
            cache.url, packs: packs, names: ["fixture.roadpack"], sessionID: feed.header.sessionID,
            coordinates: S.coordinates(((1...6).map { Double($0) } + [5.9, 9.9]).map { S.position($0) }))
        // Nothing of ours in temp either (other suites write there, never
        // under these names).
        let tempAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        #expect(tempAfter.subtracting(tempBefore).filter { $0.hasPrefix("drivelogger-navigate-") || $0.hasPrefix("Drive_") } == [])
    }

    // MARK: Mode transitions

    @Test("Navigate → Record → Navigate: each its own session; the file starts at Record's own Start; the screen never sleeps in between")
    func navigateRecordNavigate() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let rig = NavigateRig(store: scratch.store, undoWindow: .seconds(30))
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.quick)
        let first = try #require(rig.session.navigateGeneration)
        #expect(rig.idle.values == [true])
        #expect(rig.session.startBlocker == nil && rig.session.canStart, "Navigate never blocks Record")
        #expect(rig.session.state == .idle && rig.session.currentGeneration == nil)
        await rig.drive(0..<2)
        // A pin in its (long) undo window when Record starts: it reaches
        // Navigate's engine, never the recording.
        let tapT = try #require(rig.session.manualFixTapTime())
        _ = try #require(rig.session.stageManualFix(latitude: 0.0001, longitude: 0.0001, tapT: tapT, mapSpanM: 100))

        rig.uptime.set(NavigateRig.base + 50)
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let recordGeneration = try #require(rig.session.currentGeneration)
        let url = try #require(rig.session.currentFile)
        #expect(rig.session.navigateState == .off && rig.session.navigateGeneration == nil)
        #expect(recordGeneration > first)
        #expect(await eventually(10) { rig.tee.ended.contains(first) }, "Navigate's feed ended")
        #expect(Self.kinds(rig.tee.inputs[first] ?? [])["manualFix"] == 1)
        #expect(rig.session.pendingManualFixes.isEmpty)
        // Record's own samples, on its own clock.
        let recordClock = try #require(rig.source.clock)
        rig.uptime.set(NavigateRig.base + 51)
        rig.source.emit([NavigationServiceNavigateTests.motion(recordClock.now().seconds)])
        await rig.send(InitScript.poll(seq: 500, speed: 20, at: NavigateRig.base + 51))
        await rig.session.stop()

        let second = try #require(rig.session.navigateGeneration, "back to Navigate: the link still polls")
        #expect(second > recordGeneration)
        #expect(rig.session.navigateState == .running, "moving at 20 km/h when Record stopped: no still phase")
        #expect(rig.idle.values == [true], "never off between the modes")
        #expect(rig.source.startedWithBackgroundLocation == [false, true, false])
        let feeds = rig.tee.feeds
        #expect(feeds.map(\.generation) == [first, recordGeneration, second])
        #expect(feeds.map(\.output) == [.navigateOnly, .recording(recordingURL: url, sidecarURL: LogStore.navSidecarURL(for: url)),
                                        .navigateOnly])
        #expect(Set(feeds.map(\.header.sessionID)).count == 3)

        // The file: the start row first, its own clock, its own replay.
        let (header, events, _) = try RecordingFixtures.read(url)
        #expect(header.sessionID == feeds[1].header.sessionID)
        #expect(header.referenceUptimeSeconds == NavigateRig.base + 50)
        let first3 = RecordingFixtures.lifecycle(events).first
        #expect(first3?.index == 0 && first3?.sample.event == "start" && first3?.sample.detail == nil)
        let replay = events.dropFirst().prefix { $0.timestamp.nanoseconds < 0 }
        #expect(replay.count == 17, "→ connected and the 16-event init's rows: \(replay.count)")
        #expect(replay.allSatisfy { ["link", "elm", "adapter"].contains($0.payload.kind) })
        #expect(events.filter { $0.timestamp.nanoseconds < 0 }.count == replay.count, "nothing else before Start")
        #expect(RecordingFixtures.kinds(events, .manualFix).isEmpty, "Navigate's pin is not in the recording")
        #expect(RecordingFixtures.kinds(events, .motion).count == 1)
        #expect(events.contains { if case .obd(let s) = $0.payload { s.value == 20 } else { false } })

        rig.session.disableNavigate()
        #expect(rig.idle.values == [true, false])
        #expect(await eventually(10) { rig.tee.ended.contains(second) })
    }

    @Test("currentRunGeneration follows the live run; the run clock ages in Navigate while live.elapsed does not tick")
    func runGenerationAndClock() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let rig = NavigateRig(store: scratch.store, undoWindow: .seconds(30))
        await rig.connect(speed: 0)
        #expect(rig.session.currentRunGeneration == nil)
        rig.session.enableNavigate(Self.quick)
        let first = try #require(rig.session.navigateGeneration)
        #expect(rig.session.currentRunGeneration == first)
        let t0 = try #require(rig.session.manualFixTapTime()).seconds
        rig.uptime.set(NavigateRig.base + 40)
        let t1 = try #require(rig.session.manualFixTapTime()).seconds
        #expect(t1 - t0 >= 39, "the run clock advances")
        #expect(rig.session.live.elapsed == 0, "live.elapsed is Record-only")
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let rec = try #require(rig.session.currentGeneration)
        #expect(rig.session.currentRunGeneration == rec && rec != first)
        await rig.session.stop()
        let second = try #require(rig.session.navigateGeneration)
        #expect(rig.session.currentRunGeneration == second && second != rec)
        rig.session.disableNavigate()
        #expect(rig.session.currentRunGeneration == nil)
    }

    @Test("Record failure and a Start that throws after ending Navigate both return to a fresh Navigate session")
    func failurePathsReturnToNavigate() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let rig = NavigateRig(store: scratch.store)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.quick)
        let first = try #require(rig.session.navigateGeneration)

        // A write failure ends the recording in `failed`; Navigate resumes.
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let recording = try #require(rig.session.currentGeneration)
        await rig.session.handleWriteFailure(.diskFull, generation: recording)
        if case .failed = rig.session.state {} else { Issue.record("failed: \(rig.session.state)") }
        let second = try #require(rig.session.navigateGeneration)
        #expect(second > recording && recording > first)

        // A Start that throws after Navigate ended (the store can't be
        // created: its parent is a file) starts a fresh session.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("drivelogger-nav-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let broken = NavigateRig(store: LogStore(directory: blocker.appendingPathComponent("logs", isDirectory: true)))
        await broken.connect(speed: 0)
        broken.session.enableNavigate(Self.quick)
        let before = try #require(broken.session.navigateGeneration)
        await #expect(throws: (any Error).self) {
            try await broken.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        }
        let after = try #require(broken.session.navigateGeneration)
        #expect(after > before)
        #expect(broken.session.state == .idle && broken.session.currentFile == nil)
        #expect(broken.idle.values == [true], "the screen stayed awake throughout")
        #expect(broken.tee.feeds.map(\.output) == [.navigateOnly, .navigateOnly])

        // Refused before anything is touched: Navigate just goes on.
        rig.link.state = .idle
        #expect(await eventually(5) { if case .waitingForOBD = rig.session.navigateState { true } else { false } })
        await #expect(throws: RecordingStartBlocker.obdNotReady) {
            try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        }
        #expect(rig.session.navigateGeneration == second)
        rig.session.disableNavigate()
        broken.session.disableNavigate()
    }

    @Test("OBD lost for less than the auto-stop keeps the engine; for longer it stops; a later polling starts a fresh one")
    func reconnectAndAutoStop() async throws {
        let rig = NavigateRig(store: Self.absentStore())
        await rig.connect(speed: 0)
        rig.session.enableNavigate(NavigateConfiguration(stillCalibration: .zero, autoStopAfter: .milliseconds(1_500)))
        #expect(rig.session.navigateState == .running)
        let generation = try #require(rig.session.navigateGeneration)
        let clock = try #require(rig.source.clock)
        await rig.drive(0..<2)
        #expect(await rig.settled(generation, rig.inputsSent))
        let early = await rig.tee.service.snapshot(at: MonotonicTimestamp(seconds: 2))

        // A short drop: same session, same clock, same feed; the reconnect's
        // init arrives live, and nothing is replayed again.
        var replayedAgain = false
        rig.link.onNextInitSnapshot = { replayedAgain = true }
        rig.link.state = .reconnecting(attempt: 1)
        #expect(await eventually(5) { if case .waitingForOBD = rig.session.navigateState { true } else { false } })
        await rig.send([.ble(from: .connected, to: .disconnected, reason: "lost", uptime: NavigateRig.base + 2.1)])
        try await Task.sleep(for: .milliseconds(300))
        await rig.send(InitScript.connection(at: NavigateRig.base + 2.4)
            + InitScript.initialisation(firstSeq: 300) { NavigateRig.base + 2.5 + Double($0) * 0.001 })
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { rig.session.navigateState == .running })
        try await Task.sleep(for: .milliseconds(1_400))   // past the first drop's deadline
        #expect(rig.session.navigateGeneration == generation, "reconnect keeps the engine")
        #expect(Self.same(rig.source.clock, clock) && rig.source.isRunning && rig.source.stops == 0)
        #expect(!replayedAgain, "no second start-up replay")
        #expect(!rig.tee.ended.contains(generation))
        await rig.drive(2..<4)
        #expect(await rig.settled(generation, rig.inputsSent), "the estimate stream continues in the same run")
        let late = await rig.tee.service.snapshot(at: MonotonicTimestamp(seconds: 4))
        #expect(late.sessionID == early.sessionID && late.stats.inputs > early.stats.inputs)
        #expect(rig.idle.values == [true])

        // A long drop: stopped after the auto-stop, fully.
        rig.link.state = .idle
        #expect(await eventually(5) { if case .waitingForOBD = rig.session.navigateState { true } else { false } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.session.navigateGeneration == generation, "not yet")
        #expect(await eventually(5) { rig.session.navigateState == .off })
        #expect(rig.session.navigateGeneration == nil)
        #expect(!rig.source.isRunning && rig.source.stops == 1)
        #expect(await eventually(10) { rig.tee.ended.contains(generation) }, "the service's run ended")
        #expect(rig.idle.values == [true, false])
        #expect(rig.session.manualFixTapTime() == nil, "no pins without a session")

        // Polling again: a fresh session.
        rig.uptime.set(NavigateRig.base + 100)
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { rig.session.navigateGeneration != nil })
        let fresh = try #require(rig.session.navigateGeneration)
        #expect(fresh > generation)
        #expect(!Self.same(rig.source.clock, clock) && rig.source.clock?.referenceUptimeSeconds == NavigateRig.base + 100)
        #expect(rig.tee.feeds.last?.header.sessionID != rig.tee.feed(generation)?.header.sessionID)
        #expect(rig.idle.values == [true, false, true])
        rig.session.disableNavigate()
    }

    @Test("Auto-stop counts time the app was suspended: a deadline already past on becoming active stops at once")
    func autoStopOnActive() async throws {
        let rig = NavigateRig(store: Self.absentStore())
        await rig.connect(speed: 0)
        rig.session.enableNavigate(NavigateConfiguration(stillCalibration: .zero, autoStopAfter: .milliseconds(200)))
        rig.link.state = .idle
        #expect(await eventually(5) { if case .waitingForOBD = rig.session.navigateState { true } else { false } })
        // The main actor is blocked past the deadline (as if suspended): the
        // first thing to run after is becoming active.
        blockMainActor(seconds: 0.3)
        rig.session.handleScenePhase(.active)
        #expect(rig.session.navigateState == .off)
    }

    // MARK: Calibration (a)

    @Test("Still calibration: 5 s phase at speed 0, skipped when moving, decided by the first reading when none yet")
    func stillCalibration() async throws {
        let config = NavigateConfiguration(stillCalibration: .seconds(1), autoStopAfter: .seconds(600))

        // Stopped at connect: the still phase, then running.
        let still = NavigateRig(store: Self.absentStore())
        await still.connect(speed: 0)
        still.session.enableNavigate(config)
        #expect(still.session.navigateState == .calibrating)
        try await Task.sleep(for: .milliseconds(150))
        #expect(still.session.navigateState == .calibrating)
        await still.send(InitScript.poll(seq: 40, speed: 12, at: NavigateRig.base + 0.1))
        #expect(still.session.navigateState == .calibrating, "only the speed at connect decides")
        #expect(await eventually(5) { still.session.navigateState == .running })

        // Moving at connect: no still phase.
        let moving = NavigateRig(store: Self.absentStore())
        await moving.connect(speed: 30)
        moving.session.enableNavigate(config)
        #expect(moving.session.navigateState == .running)

        // No reading yet: the first one decides.
        let unknown = NavigateRig(store: Self.absentStore())
        await unknown.connect(speed: nil)
        unknown.session.enableNavigate(config)
        #expect(unknown.session.navigateState == .calibrating)
        await unknown.send(InitScript.poll(seq: 41, speed: 25, at: NavigateRig.base + 0.1))
        #expect(unknown.session.navigateState == .running)

        // No reading at all: the phase just ends.
        let silent = NavigateRig(store: Self.absentStore())
        await silent.connect(speed: nil)
        silent.session.enableNavigate(config)
        #expect(silent.session.navigateState == .calibrating)
        #expect(await eventually(5) { silent.session.navigateState == .running })

        // A drop during the still phase ends it; the reconnect is `running`.
        let dropped = NavigateRig(store: Self.absentStore())
        await dropped.connect(speed: 0)
        dropped.session.enableNavigate(NavigateConfiguration(stillCalibration: .seconds(30), autoStopAfter: .seconds(600)))
        dropped.link.state = .idle
        #expect(await eventually(5) { if case .waitingForOBD = dropped.session.navigateState { true } else { false } })
        dropped.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { dropped.session.navigateState == .running })

        for rig in [still, moving, unknown, silent, dropped] { rig.session.disableNavigate() }
    }

    // MARK: Pins, lifecycle, screen

    @Test("Pins in Navigate: same undo window, undo drops it, a committed one reaches the engine at the tap time; background commits")
    func pinsInNavigate() async throws {
        let store = Self.absentStore()
        let rig = NavigateRig(store: store, undoWindow: .seconds(1))
        await rig.connect(speed: 0)
        #expect(rig.session.manualFixTapTime() == nil, "nothing runs yet")
        rig.session.enableNavigate(Self.quick)
        let generation = try #require(rig.session.navigateGeneration)
        await rig.drive(0..<1)
        #expect(rig.session.manualFixUndoWindow == .seconds(1))

        let undoneT = try #require(rig.session.manualFixTapTime())
        let undone = try #require(rig.session.stageManualFix(latitude: 0.01, longitude: 0.01, tapT: undoneT, mapSpanM: 100))
        #expect(rig.session.pendingManualFixes.map(\.id) == [undone])
        #expect(rig.session.cancelPendingManualFix(undone))

        rig.uptime.set(NavigateRig.base + 1.5)
        let keptT = try #require(rig.session.manualFixTapTime())
        #expect(keptT == MonotonicTimestamp(seconds: 1.5))
        _ = try #require(rig.session.stageManualFix(latitude: 0.02, longitude: 0.02, tapT: keptT, mapSpanM: 100))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.session.pendingManualFixes.count == 1, "still in its window")
        #expect(await eventually(5) { rig.session.pendingManualFixes.isEmpty })

        // Entering the background commits a pending one at once.
        let lateT = try #require(rig.session.manualFixTapTime())
        _ = try #require(rig.session.stageManualFix(latitude: 0.03, longitude: 0.03, tapT: lateT, mapSpanM: 100))
        rig.session.handleScenePhase(.background)
        #expect(rig.session.pendingManualFixes.isEmpty)
        rig.session.handleScenePhase(.active)

        #expect(await eventually(5) { (rig.tee.inputs[generation] ?? []).filter { LogEvent($0).payload.kind == "manualFix" }.count == 2 })
        let pins = (rig.tee.inputs[generation] ?? []).compactMap { input -> (ManualFixSample, MonotonicTimestamp)? in
            if case .manualFix(let sample, let t) = input { (sample, t) } else { nil }
        }
        #expect(pins.map(\.0.latitude) == [0.02, 0.03], "the undone one never reached the engine")
        #expect(pins[0].1 == keptT && pins[0].0.pressedT == keptT)
        #expect(pins[0].0.obdSpeedKmh == 36, "the session's own reading")
        #expect(rig.session.droppedManualFixIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        rig.session.disableNavigate()
    }

    @Test("Background and foreground reset nothing in Navigate; willTerminate ends it; idle timer on, then off")
    func lifecycle() async throws {
        let rig = NavigateRig(store: Self.absentStore())
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.quick)
        let generation = try #require(rig.session.navigateGeneration)
        let clock = try #require(rig.source.clock)
        #expect(await eventually(5) { rig.session.navigateState == .running })
        rig.session.handleScenePhase(.inactive)
        rig.session.handleScenePhase(.background)
        rig.session.handleScenePhase(.active)
        #expect(rig.session.navigateState == .running && rig.session.navigateGeneration == generation)
        #expect(Self.same(rig.source.clock, clock) && rig.source.stops == 0)
        #expect(rig.session.backgroundRiskWarning == nil)
        #expect(rig.idle.values == [true])

        rig.session.handleWillTerminate()
        #expect(rig.session.navigateState == .off && rig.session.navigateGeneration == nil)
        #expect(rig.source.stops == 1)
        #expect(rig.idle.values == [true, false])
        #expect(await eventually(10) { rig.tee.ended.contains(generation) })
    }

    @Test("Navigate starts its location source without background location; Record still holds it")
    func noBackgroundLocationInNavigate() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = ScriptedSource()
        let rig = NavigateRig(store: scratch.store, extraSources: [location])
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.quick)
        #expect(location.startedWithBackgroundLocation == [false])
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(location.startedWithBackgroundLocation == [false, true])
        await rig.session.stop()
        #expect(location.startedWithBackgroundLocation == [false, true, false])
        rig.session.disableNavigate()
    }

    @Test("Map fix on arrival (R24.1-1): latestFix takes each fix as the source shows it, in Navigate and Record, without the 1 s live tick; never a fix of an ended run")
    func mapFixOnArrival() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = FakeReferenceFixSource(name: "fakeLocation")
        let rig = NavigateRig(store: scratch.store, extraSources: [location])
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.quick)
        #expect(rig.session.latestFix == nil)

        // No suspension between the fix and the checks: the live timer
        // cannot run, so only on-arrival delivery can set `latestFix`.
        let first = location.fix(speed: 14)
        location.show(first)
        #expect(rig.session.latestFix == first)
        #expect(rig.session.live.referenceFix == nil, "not via the live tick")
        let second = location.fix(speed: 15)
        location.show(second)
        #expect(rig.session.latestFix == second)
        // The 1 s copy for the manual-fix gate still comes from the tick.
        #expect(await eventually(3) { rig.session.live.referenceFix == second })

        // Record: the same path; its start clears what Navigate showed.
        let navigateCallback = try #require(location.onReferenceFix)
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(rig.session.latestFix == nil)
        navigateCallback(first)
        #expect(rig.session.latestFix == nil, "a late fix of the ended Navigate run")
        let recorded = location.fix(speed: 16)
        location.show(recorded)
        #expect(rig.session.latestFix == recorded)
        let recordCallback = try #require(location.onReferenceFix)
        // A fix shown while Stop is in progress (sources stopped, the
        // recording not yet finished) is not taken either.
        let late = location.fix(speed: 30)
        let seen = LateFixProbe()
        location.onStop = { [session = rig.session] in
            Task { @MainActor in
                recordCallback(late)
                seen.state = session.state
                seen.fix = session.latestFix
            }
        }
        await rig.session.stop()
        location.onStop = nil
        #expect(seen.state == .stopping)
        #expect(seen.fix == recorded, "the late fix is dropped during Stop")
        #expect(rig.session.latestFix == nil)
        recordCallback(recorded)
        #expect(rig.session.latestFix == nil, "a late fix of the ended recording")

        // Back in Navigate: delivered again; nothing once Navigate is off.
        let again = location.fix(speed: 17)
        location.show(again)
        #expect(rig.session.latestFix == again)
        let lastCallback = try #require(location.onReferenceFix)
        rig.session.disableNavigate()
        #expect(rig.session.latestFix == nil)
        lastCallback(again)
        #expect(rig.session.latestFix == nil, "no run is live")
    }

    @Test("Without enableNavigate the session is Record-only: polling starts nothing")
    func offByDefault() async throws {
        let rig = NavigateRig(store: Self.absentStore())
        await rig.connect(speed: 0)
        rig.link.state = .idle
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.session.navigateState == .off && rig.tee.feeds.isEmpty)
        #expect(rig.source.startedWithBackgroundLocation.isEmpty && rig.idle.values.isEmpty)
    }
}
