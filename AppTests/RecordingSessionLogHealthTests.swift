import DriveLoggerCore
import Foundation
import Testing
import UIKit

@testable import DriveLogger

// What the recorder writes about its own health and ends (backlog R4.1-8,
// R4.1-4) and what a manual fix may claim as its OBD speed (M8.1-3), against
// the real `LogFileWriter` in a scratch directory.

@Suite("RecordingSession writer queue alarm and willTerminate", .serialized)
@MainActor
struct RecordingSessionWriterHealthTests {
    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    @Test("A burst the writer can't keep up with: the stats row, then right after it the writer-queue error row, before stop; none for a quiet window (R4.1-8)")
    func writerQueueAlarmRow() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        // 30 000 rows handed over in one main-actor step at Start, in a 5 s
        // window with nothing else: 2 s of data is ~12 000 events, so the
        // peak is above it unless the writer encoded 60 % of the burst while
        // it was being handed over.
        let burst = BurstSource(count: 30_000)
        let session = RecordingFixtures.session(sources: [burst], store: scratch.store, statsInterval: .seconds(5))
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        try await Task.sleep(for: .milliseconds(6_000))
        await session.stop()

        let (_, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil && !report.truncatedTail)
        let statsRows = RecordingFixtures.kinds(events, .stats)
        #expect(statsRows.count == 2, "one periodic window, then the final one")
        let first = try #require(statsRows.first)
        guard case .stats(let window) = events[first].payload else { Issue.record("not a stats row"); return }
        #expect(window.counts["accel"] == 30_000)
        let twoSeconds = try #require(WriterQueueAlarm.twoSecondsOfData(window))
        #expect(window.queueDepthMax > max(twoSeconds, WriterQueueAlarm.floor), "the burst was seen at its peak")

        let alarms = RecordingFixtures.lifecycle(events).filter {
            $0.sample.event == "error" && $0.sample.detail?.hasPrefix("writer queue peaked at ") == true
        }
        #expect(alarms.count == 1, "only the burst's window")
        let alarm = try #require(alarms.first)
        #expect(alarm.index == first + 1, "right after its stats row: no source ticks between them")
        #expect(alarm.sample.detail == "writer queue peaked at \(window.queueDepthMax) events, more than 2 s of data (\(twoSeconds))")
        let stop = try #require(RecordingFixtures.index(of: .stop, in: events))
        #expect(alarm.index < stop)
        #expect(statsRows.last == events.count - 1, "the final stats row is the last row, with no alarm after it")
    }

    @Test("willTerminate flushes what was recorded before it returns, and writes no row (R4.1-4)")
    func willTerminateFlushes() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        // The flush timer is an hour: only the terminate path can write.
        let session = RecordingFixtures.session(store: scratch.store, flushInterval: .seconds(3_600))
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        try await Task.sleep(for: .milliseconds(300))
        session.mark("before terminate")
        let headerOnly = Self.fileSize(url)

        // As UIKit delivers it: posted on the main thread, the process may
        // end as soon as `post` returns.
        NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
        #expect(Self.fileSize(url) > headerOnly, "flushed before post returned")

        let flushed = try RecordingFixtures.read(url)
        #expect(flushed.report.failure == nil && !flushed.report.truncatedTail)
        #expect(flushed.events.contains { $0.payload == .marker("before terminate") })
        #expect(RecordingFixtures.kinds(flushed.events, .accelerometer).count > 10)
        #expect(RecordingFixtures.lifecycle(flushed.events).map(\.sample.event) == ["start", "calibrationStart", "calibrationEnd"])
        #expect(session.state == .recording, "flush only: the recording goes on")

        await session.stop()
        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(RecordingFixtures.lifecycle(events).map(\.sample.event) == ["start", "calibrationStart", "calibrationEnd", "stop"])
    }

    @Test("willTerminate while not recording does nothing")
    func willTerminateIdle() throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        session.handleWillTerminate()
        #expect(session.state == .idle)
        #expect(scratch.files.isEmpty)
    }
}

@Suite("RecordingSession manual fix OBD speed at Start (M8.1-3)", .serialized)
@MainActor
struct RecordingSessionFixSpeedAtStartTests {
    typealias M = RecordingSessionManualFixTests

    /// Every `obdSpeedT` in the file is the `t` of an `obd` row in it.
    static func expectSpeedTimesHaveRows(_ events: [LogEvent], sourceLocation: SourceLocation = #_sourceLocation) {
        let obdTimes = Set(events.compactMap { if case .obd = $0.payload { $0.timestamp } else { nil } })
        for (_, fix) in M.manualFixes(events) {
            if let obdSpeedT = fix.obdSpeedT {
                #expect(obdTimes.contains(obdSpeedT), "obdSpeedT \(obdSpeedT) has no obd row", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("A speed read before Start is not carried over: a fix before the recording's first reading has no OBD speed; the next reading is used")
    func notCarriedOver() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store, manualFixUndoWindow: .milliseconds(100))
        link.send(M.reading(42))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 42 })

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(session.live.obdSpeedKmh == nil && session.obdSpeedReplyUptime == nil)
        _ = try M.stage(session, latitude: 0)
        link.send(M.reading(50))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 50 })
        _ = try M.stage(session, latitude: 1)
        #expect(await eventually(3) { session.pendingManualFixes.isEmpty })
        await session.stop()

        let (_, events, _) = try RecordingFixtures.read(url)
        let fixes = M.manualFixes(events).map(\.sample)
        #expect(fixes.count == 2)
        #expect(fixes[0].obdSpeedKmh == nil && fixes[0].obdSpeedT == nil && fixes[0].speedSource == "unknown")
        #expect(fixes[1].obdSpeedKmh == 50 && fixes[1].speedSource == "obd" && fixes[1].gateSpeedKmh == 50)
        #expect((fixes[1].obdSpeedT?.nanoseconds ?? -1) >= 0)
        Self.expectSpeedTimesHaveRows(events)
    }

    @Test("A reading delivered before Start but handled after it (skipped, not written) does not become the fix's speed")
    func skippedReadingNotUsed() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store, manualFixUndoWindow: .milliseconds(100))
        // Delivered while the recorder takes its Start snapshot: it sits in
        // the stream unconsumed, so the loop handles it after Start and skips it.
        link.onNextInitSnapshot = { link.send(M.reading(42)) }
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(await eventually(2) { session.consumedLinkEvents == 1 })
        #expect(session.live.obdSpeedKmh == nil && session.obdSpeedReplyUptime == nil)
        _ = try M.stage(session, latitude: 0)
        #expect(await eventually(3) { session.pendingManualFixes.isEmpty })
        await session.stop()

        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(!events.contains { if case .obd = $0.payload { true } else { false } }, "the skipped reading is not written")
        let fix = try #require(M.manualFixes(events).first?.sample)
        #expect(fix.obdSpeedKmh == nil && fix.obdSpeedT == nil && fix.speedSource == "unknown")
        Self.expectSpeedTimesHaveRows(events)
    }
}

/// Hands `count` `accel` rows to the sink in one go when started, on the
/// caller's thread (the main actor at Start): a burst the writer can't
/// encode as fast as it arrives.
@MainActor
private final class BurstSource: SensorSource {
    let name = "burstIMU"
    let availability = SensorAvailability.available
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        let t = clock.now()
        for _ in 0..<count {
            sink.record(LogEvent(timestamp: t, payload: .accelerometer(Vector3(x: 0, y: -1, z: 0))))
        }
    }

    func stop() {}
}
