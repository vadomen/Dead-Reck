import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-1 Navigate: `LogSink.tapOnly(_:)`, the sink with no writer. It must tap
/// exactly what a writer's sink taps, in the same order, keep nothing, and
/// stop at `finish()`.
@Suite("LogSink tap-only (Navigate)")
struct TapOnlySinkTests {
    typealias F = TapFixtures

    /// Every kind once, an unknown kind, then a long mix: the input both
    /// sinks get.
    static func script() -> [LogEvent] {
        var events = LogEventKind.allCases.enumerated().map { F.event(of: $0.element, at: F.t($0.offset)) }
        events.append(LogEvent(timestamp: F.t(100), payload: .unrecognized(kind: "future", data: .object(["x": .int(1)]))))
        events += F.mixed(200..<900)
        return events
    }

    @Test("Taps the same events, in the same order, as a writer's sink fed the same input")
    func tapsLikeAWritersSink() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let events = Self.script()

        let viaWriter = TapRecorder()
        let writer = try F.writer(scratch, "writer.jsonl.gz", tap: viaWriter.tap)
        let viaTapOnly = TapRecorder()
        let sink = LogSink.tapOnly(viaTapOnly.tap)
        for event in events {
            writer.sink.record(event)
            sink.record(event)
        }
        let summary = await writer.finish()
        sink.finish()

        #expect(sink.isTapOnly && !writer.sink.isTapOnly)
        #expect(viaTapOnly.events == viaWriter.events)
        #expect(viaTapOnly.events == events.filter { LogSink.isTapped($0.payload) })
        #expect(viaTapOnly.events.count == 405, "5 kinds of the 16 + 400 of the 700 mixed")
        // The writer's side is untouched by the other sink: every row written.
        #expect(summary.eventCount == events.count)
        #expect(try WriterFixtures.read(summary.url, recovery: .strict).events == events)
    }

    @Test("A NavigationTap behind a tap-only sink gets the same inputs as behind a writer")
    func navigationTapInputsMatch() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let events = F.mixed(0..<2_000)
        let recordNav = NavigationTap()
        let writer = try F.writer(scratch, "nav.jsonl.gz", tap: recordNav.tap)
        let navigateNav = NavigationTap()
        let sink = LogSink.tapOnly(navigateNav.tap)
        for event in events {
            writer.sink.record(event)
            sink.record(event)
        }
        _ = await writer.finish()
        recordNav.finish()
        sink.finish()
        navigateNav.finish()
        let recorded = await WriterFixtures.collect(recordNav.inputs)
        let navigated = await WriterFixtures.collect(navigateNav.inputs)
        #expect(navigated == recorded)
        #expect(navigated == F.inputs(events))
    }

    @Test("Nothing is kept: no queue depth, nothing enqueued, the event stream is empty and ended; no drops before finish")
    func keepsNothing() async {
        let recorder = TapRecorder()
        let sink = LogSink.tapOnly(recorder.tap)
        let others = [LogEventKind.accelerometer, .gyroscope, .magnetometer, .barometer, .elm, .adapter, .link,
                      .lifecycle, .stats, .marker]
        for round in 0..<500 {
            for (index, kind) in others.enumerated() {
                sink.record(F.event(of: kind, at: F.t(round * 100 + index)))
            }
            #expect(sink.queueDepth == 0)
        }
        #expect(recorder.events.isEmpty, "no non-navigation kind is tapped")
        #expect(sink.totalEnqueued == 0)
        #expect(sink.queueDepth == 0)
        #expect(sink.takePeakQueueDepth() == 0)
        #expect(sink.dropped == 0, "discarding non-tapped kinds is by design, not a drop")
        // The stream a writer would drain holds nothing and has already ended.
        var drained = 0
        for await _ in sink.events { drained += 1 }
        #expect(drained == 0)
    }

    @Test("finish() stops it: nothing tapped after, every later event counted in dropped; idempotent")
    func finishStopsTapping() {
        let recorder = TapRecorder()
        let sink = LogSink.tapOnly(recorder.tap)
        let before = [F.event(of: .motion, at: F.t(1)), F.event(of: .lifecycle, at: F.t(2)),
                      F.event(of: .obd, at: F.t(3))]
        for event in before { sink.record(event) }
        sink.finish()
        sink.finish()
        sink.record(F.event(of: .motion, at: F.t(4)))
        sink.record(F.event(of: .manualFix, at: F.t(5)))
        sink.record(F.event(of: .stats, at: F.t(6)))
        #expect(recorder.events == [before[0], before[2]])
        #expect(sink.dropped == 3)
        #expect(sink.queueDepth == 0)
    }

    @Test("Tap order is record order with producers recording concurrently from many threads")
    func concurrentOrder() async {
        let nav = NavigationTap(bufferLimit: 10_000)
        let recorder = TapRecorder()
        // The recorder sees the order the sink called the tap in; the
        // NavigationTap must see the same.
        let sink = LogSink.tapOnly { event in
            recorder.tap(event)
            nav.record(event)
        }
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for event in F.mixed((producer * 1_000)..<(producer * 1_000 + 1_000)) { sink.record(event) }
                }
            }
        }
        sink.finish()
        nav.finish()
        let inputs = await WriterFixtures.collect(nav.inputs)
        let expected = (0..<4_000).map { F.mixed($0..<($0 + 1))[0] }.filter { LogSink.isTapped($0.payload) }
        #expect(recorder.events.count == expected.count)
        #expect(Set(recorder.events.map(\.timestamp)) == Set(expected.map(\.timestamp)))
        #expect(inputs == F.inputs(recorder.events))
    }
}
