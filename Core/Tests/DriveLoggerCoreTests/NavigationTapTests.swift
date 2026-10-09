import Foundation
import Testing

@testable import DriveLoggerCore

/// Collects what a tap closure was handed. Lock-guarded (the project's NSLock
/// convention), because the sink calls the tap from whichever thread records.
final class TapRecorder: Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var seen: [LogEvent] = []

    var tap: @Sendable (LogEvent) -> Void {
        { [self] event in lock.withLock { seen.append(event) } }
    }

    var events: [LogEvent] { lock.withLock { seen } }
}

enum TapFixtures {
    static func t(_ index: Int) -> MonotonicTimestamp {
        MonotonicTimestamp(nanoseconds: Int64(index) * 1_000_000)
    }

    /// A mix in which 4 of every 7 events are navigation inputs (motion, obd,
    /// location, manualFix) and 3 are not (accel, marker, lifecycle).
    static func mixed(_ range: Range<Int>) -> [LogEvent] {
        range.map { i in
            let t = t(i)
            switch i % 7 {
            case 0:
                return .motion(LogFixtures.motion, at: t)
            case 1:
                return .obd(OBDSample(pid: .vehicleSpeed, value: Double(i % 120), unit: .kilometersPerHour, raw: "410D00"), at: t)
            case 2:
                return .location(LogFixtures.location, at: t)
            case 3:
                return LogEvent(timestamp: t, payload: .accelerometer(Vector3(x: Double(i), y: 0, z: -1)))
            case 4:
                return .marker("m\(i)", at: t)
            case 5:
                return LogEvent(timestamp: t, payload: .manualFix(ManualFixSample(
                    latitude: 0.001, longitude: Double(i) * 1e-6, pressedT: t, speedSource: "unknown")))
            default:
                return LogEvent(timestamp: t, payload: .lifecycle(LifecycleSample(.memoryWarning)))
            }
        }
    }

    /// One event of `kind`. Exhaustive: a new kind fails to compile here
    /// until someone decides whether navigation should see it.
    static func event(of kind: LogEventKind, at t: MonotonicTimestamp) -> LogEvent {
        let payload: LogEvent.Payload = switch kind {
        case .motion: .motion(LogFixtures.motion)
        case .location: .location(LogFixtures.location)
        case .obd: .obd(OBDSample(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour, raw: "410D32"))
        case .marker: .marker("m")
        case .accelerometer: .accelerometer(Vector3(x: 0, y: -1, z: 0))
        case .gyroscope: .gyroscope(Vector3(x: 0.01, y: 0, z: 0))
        case .magnetometer: .magnetometer(Vector3(x: 12, y: -34, z: 56))
        case .barometer: .barometer(BarometerSample(pressureKPa: 101.3, relativeAltitude: 0))
        case .elm: .elm(ELMTrafficSample(seq: 1, phase: "poll", tx: "010D", requestT: t, rx: "410D32", outcome: "ok"))
        case .adapter: .adapter(AdapterEventSample(adapter: AdapterRecord(name: "IOS-Vlink", identifier: "X")))
        case .link: .link(LinkSample(layer: "ble", from: "idle", to: "scanning"))
        case .lifecycle: .lifecycle(LifecycleSample(.start))
        case .stats: .stats(StatsSample(
            windowS: 10, counts: [:], obdHz: 0, motionHz: 0, gaps: [:], maxGapMs: [:],
            timeouts: 0, queueDepthMax: 0, dropped: 0, bytesWritten: 0))
        case .manualFix: .manualFix(ManualFixSample(latitude: 0, longitude: 0, pressedT: t, speedSource: "unknown"))
        }
        return LogEvent(timestamp: t, payload: payload)
    }

    static let navigationKinds: Set<LogEventKind> = [.motion, .location, .obd, .manualFix]

    static func writer(
        _ scratch: ScratchDirectory,
        _ name: String,
        tap: (@Sendable (LogEvent) -> Void)?
    ) throws -> LogFileWriter {
        try LogFileWriter(
            url: scratch.file(name),
            header: WriterFixtures.header,
            flushInterval: .seconds(3_600),
            diskSpace: FakeDiskSpace(WriterFixtures.roomy),
            tap: tap
        )
    }

    /// Records `events`, flushing every `flushEvery`, and finishes.
    static func write(_ events: [LogEvent], to writer: LogFileWriter, flushEvery: Int = 2_000) async throws -> LogFileSummary {
        for (index, event) in events.enumerated() {
            writer.sink.record(event)
            if (index + 1) % flushEvery == 0 { try await writer.flush() }
        }
        return await writer.finish()
    }

    static func inputs(_ events: [LogEvent]) -> [NavigationInput] {
        events.compactMap(NavigationInput.init)
    }
}

@Suite("LogSink tap and NavigationTap")
struct NavigationTapTests {
    typealias F = TapFixtures

    @Test("A tap that is never drained leaves the file byte-identical, and droppedInputs counts the overflow exactly")
    func undrainedTapChangesNothingInTheLog() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        // 10_500 events, 6_000 of them navigation inputs: 1_904 over the buffer.
        let events = F.mixed(0..<10_500)
        let navigationEvents = events.filter { LogSink.isTapped($0.payload) }
        #expect(navigationEvents.count == 6_000)

        let plain = try F.writer(scratch, "plain.jsonl.gz", tap: nil)
        let plainSummary = try await F.write(events, to: plain)

        let nav = NavigationTap()
        let tapped = try F.writer(scratch, "tapped.jsonl.gz", tap: nav.tap)
        let tappedSummary = try await F.write(events, to: tapped)
        nav.finish()

        // The log: same bytes, same rows, same order, nothing dropped.
        let plainBytes = try Data(contentsOf: plainSummary.url)
        let tappedBytes = try Data(contentsOf: tappedSummary.url)
        #expect(tappedBytes == plainBytes)
        #expect(tappedSummary.eventCount == events.count)
        #expect(tappedSummary.members == plainSummary.members)
        #expect(tappedSummary.unwrittenEvents == 0)
        #expect(tapped.sink.dropped == 0)
        let read = try WriterFixtures.read(tappedSummary.url, recovery: .strict)
        #expect(read.events == events)

        // Navigation: exactly the overflow dropped, the newest kept, in file order.
        #expect(nav.droppedInputs == 6_000 - NavigationTap.defaultBufferLimit)
        let kept = await WriterFixtures.collect(nav.inputs)
        #expect(kept == Array(F.inputs(read.events).suffix(NavigationTap.defaultBufferLimit)))
    }

    @Test("A nil tap has no effect: same file as a writer created without one, every counter unchanged")
    func nilTapHasNoEffect() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let events = F.mixed(0..<700)

        let defaulted = try LogFileWriter(
            url: scratch.file("default.jsonl.gz"),
            header: WriterFixtures.header,
            flushInterval: .seconds(3_600),
            diskSpace: FakeDiskSpace(WriterFixtures.roomy)
        )
        let explicitNil = try F.writer(scratch, "nil.jsonl.gz", tap: nil)
        for event in events {
            defaulted.sink.record(event)
            explicitNil.sink.record(event)
        }
        #expect(explicitNil.sink.totalEnqueued == defaulted.sink.totalEnqueued)
        let a = await defaulted.finish()
        let b = await explicitNil.finish()
        #expect(try Data(contentsOf: b.url) == Data(contentsOf: a.url))
        #expect(b.eventCount == a.eventCount)
        #expect(explicitNil.sink.dropped == 0)
        #expect(explicitNil.sink.queueDepth == 0)
        #expect(try WriterFixtures.read(b.url, recovery: .strict).events == events)
    }

    @Test("Only motion, location, obd and manualFix are tapped; every other kind, unknown kinds included, never is")
    func onlyNavigationKindsAreTapped() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        var events = LogEventKind.allCases.enumerated().map { F.event(of: $0.element, at: F.t($0.offset)) }
        events.append(LogEvent(timestamp: F.t(100), payload: .unrecognized(kind: "future", data: .object(["x": .int(1)]))))
        let recorder = TapRecorder()
        let writer = try F.writer(scratch, "kinds.jsonl.gz", tap: recorder.tap)
        let summary = try await F.write(events, to: writer)

        let expected = events.filter { event in F.navigationKinds.contains { $0.rawValue == event.payload.kind } }
        #expect(expected.count == 4)
        #expect(recorder.events == expected)
        for event in events {
            let kind = event.payload.kind
            #expect(LogSink.isTapped(event.payload) == F.navigationKinds.contains { $0.rawValue == kind }, "\(kind)")
        }
        // Everything still reached the file.
        #expect(summary.eventCount == events.count)
    }

    @Test("Live order is file order, with producers recording concurrently from many threads")
    func tapSeesFileOrder() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let nav = NavigationTap()
        let writer = try F.writer(scratch, "order.jsonl.gz", tap: nav.tap)
        let consumer = Task { await WriterFixtures.collect(nav.inputs) }

        let sink = writer.sink
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for event in F.mixed((producer * 1_000)..<(producer * 1_000 + 1_000)) {
                        sink.record(event)
                    }
                }
            }
        }
        let summary = await writer.finish()
        nav.finish()
        let live = await consumer.value

        let fileEvents = try WriterFixtures.read(summary.url, recovery: .strict).events
        #expect(fileEvents.count == 4_000)
        #expect(nav.droppedInputs == 0)
        #expect(live.count == F.inputs(fileEvents).count)
        #expect(live == F.inputs(fileEvents))
    }

    @Test("An event the sink refuses after finish() is never tapped")
    func refusedEventsAreNotTapped() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let recorder = TapRecorder()
        let writer = try F.writer(scratch, "late.jsonl.gz", tap: recorder.tap)
        let before = F.event(of: .motion, at: F.t(1))
        writer.sink.record(before)
        _ = await writer.finish()
        writer.sink.record(F.event(of: .motion, at: F.t(2)))
        #expect(writer.sink.dropped == 1)
        #expect(recorder.events == [before])
    }

    @Test("NavigationTap converts with NavigationInput, ignores other kinds and counts only buffer overflow")
    func navigationTapDirect() async {
        let nav = NavigationTap(bufferLimit: 3)
        let events = (0..<10).map { F.event(of: .obd, at: F.t($0)) }
        nav.record(F.event(of: .marker, at: F.t(-1)))
        for event in events { nav.record(event) }
        #expect(nav.droppedInputs == 7)
        nav.finish()
        nav.record(F.event(of: .motion, at: F.t(20)))  // after finish: ignored, not a drop
        #expect(nav.droppedInputs == 7)
        let kept = await WriterFixtures.collect(nav.inputs)
        #expect(kept == F.inputs(Array(events.suffix(3))))
    }

    @Test("The sidecar sits next to its recording: same folder, .jsonl.gz replaced by .nav.jsonl")
    func sidecarURL() {
        let folder = URL(fileURLWithPath: "/var/mobile/Documents/logs", isDirectory: true)
        let recording = folder.appendingPathComponent("Drive_20261010-091500.jsonl.gz")
        let sidecar = NavSidecarFile.url(forRecording: recording)
        #expect(sidecar.lastPathComponent == "Drive_20261010-091500.nav.jsonl")
        #expect(sidecar.deletingLastPathComponent().path == folder.path)
        #expect(NavSidecarFile.url(forRecording: folder.appendingPathComponent("Drive_20261010-091500_2.jsonl.gz")).lastPathComponent
            == "Drive_20261010-091500_2.nav.jsonl")
        #expect(NavSidecarFile.url(forRecording: folder.appendingPathComponent("odd.jsonl")).lastPathComponent == "odd.jsonl.nav.jsonl")
        #expect(NavSidecarFile.isSidecar(sidecar))
        #expect(!NavSidecarFile.isSidecar(recording))
        // Not a recording name, so nothing that lists recordings picks it up.
        #expect(!sidecar.lastPathComponent.hasSuffix("." + LogFileName.fileExtension))
    }
}
