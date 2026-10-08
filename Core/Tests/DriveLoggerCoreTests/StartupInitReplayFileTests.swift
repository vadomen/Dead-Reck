import Foundation
import Testing

@testable import DriveLoggerCore

// M4 (docs/BENCH_TEST_2026-10-08.md): the recorder writes the link's
// start-up init at Start, right after the `start` row, stamped from the
// events' own uptimes, so those rows have negative `t`. These tests pin that
// such a file is healthy to `inspect_log` (the `RecordingAnalyzer` behind
// it), read strictly, and that the new `locationAuthorization` lifecycle
// value is a stable on-disk string.

@Suite("Start-up init replay in a file (M4)")
struct StartupInitReplayFileTests {
    /// Reference uptime 1 000 s; `now()` reads 1 000 s too, so `t = 0` is
    /// Start.
    static let clock = SessionClock(
        referenceUptimeSeconds: 1_000,
        wallClockStart: Date(timeIntervalSince1970: 1_790_000_000),
        source: FixedUptimeSource(uptimeSeconds: 1_000)
    )

    static func exchange(_ seq: Int, _ tx: String, _ rx: String, phase: ELMPhase, at uptime: Double) -> LinkEvent {
        .session(.exchange(ELMExchange(
            seq: seq, phase: phase, tx: tx, requestUptime: uptime - 0.05, rx: rx,
            completedUptime: uptime, outcome: .ok
        )))
    }

    /// The link's `lastInitEvents` for a connect 40 s before Start: BLE
    /// connect, `ATZ` … `ATSH7E0`, a probe, the `adapter` event, `polling`.
    static func startupInit() -> [LinkEvent] {
        let base = 960.0
        var events: [LinkEvent] = [
            .ble(from: .idle, to: .connecting, reason: nil, uptime: base),
            .ble(from: .connecting, to: .discovering, reason: nil, uptime: base + 0.4),
            .ble(from: .discovering, to: .connected, reason: "vgate", uptime: base + 0.9),
            .session(.state(from: .idle, to: .resetting, reason: nil, uptime: base + 1.0)),
        ]
        let handshake = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0"]
        for (seq, tx) in handshake.enumerated() {
            events.append(exchange(seq, tx, tx == "ATZ" ? "ELM327 v2.3" : "OK", phase: .initialisation, at: base + 1.5 + Double(seq) * 0.1))
        }
        events.append(.session(.state(from: .initialising, to: .probing, reason: nil, uptime: base + 2.6)))
        events.append(exchange(10, "010D0C1", "7E8064110D000C0A6C", phase: .probe, at: base + 2.7))
        events.append(.session(.adapter(MappingFixtures.info, uptime: base + 2.8)))
        events.append(.session(.state(from: .probing, to: .ready, reason: nil, uptime: base + 2.8)))
        events.append(.session(.state(from: .ready, to: .polling, reason: nil, uptime: base + 2.9)))
        return events
    }

    @Test("start row, negative-t replayed link/elm/adapter rows, then live rows: read strictly, no health warning")
    func replayedInitIsHealthy() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        // `INSPECT_LOG_SAMPLE_DIR` keeps the file for a manual
        // `inspect_log --strict` run (as `RecordingPipelineTests` does).
        let directory = ProcessInfo.processInfo.environment["INSPECT_LOG_SAMPLE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? scratch.url
        let clock = Self.clock
        let header = LogHeader(
            clock: clock, app: LogFixtures.app, device: LogFixtures.device, notes: "M4 start-up init replay",
            adapter: MappingFixtures.bleAdapter.with(MappingFixtures.info),
            polling: PollingRecord(MappingFixtures.multiPlan), timeZone: "UTC"
        )
        let url = directory.appendingPathComponent("Drive_M4-replay-\(UUID().uuidString.prefix(8)).jsonl.gz")
        let writer = try LogFileWriter(url: url, header: header, flushInterval: .milliseconds(100), diskSpace: FakeDiskSpace(WriterFixtures.roomy))
        let sink = writer.sink

        // The recorder's start sequence: `start`, the replay, calibration.
        sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(LifecycleSample(.start))))
        let replay = Self.startupInit().flatMap { LogEvent.rows(for: $0, adapter: MappingFixtures.bleAdapter, clock: clock) }
        for row in replay { sink.record(row) }
        sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(LifecycleSample(.calibrationStart, detail: "keep still for 0.0 s"))))
        sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(LifecycleSample(.calibrationEnd))))
        sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(LifecycleSample(
            .locationAuthorization,
            detail: "authorizationStatus=authorizedWhenInUse, accuracyAuthorization=full, backgroundActivitySession=held"
        ))))
        // Live: 1 s of motion at 100 Hz and polls at ~16 Hz, `seq` resuming
        // after the pre-Start polls that were not written (one gap).
        for index in 0..<100 {
            sink.record(StatsFixtures.motion(at: Double(index) * 10))
        }
        for index in 0..<16 {
            let uptime = 1_000.0 + Double(index) * 0.06
            let event = Self.exchange(500 + index, "010D0C1", "7E8064110D320C0A6C", phase: .poll, at: uptime)
            for row in LogEvent.rows(for: event, adapter: MappingFixtures.bleAdapter, clock: clock) { sink.record(row) }
        }
        sink.record(LogEvent(timestamp: StatsFixtures.ms(1_000), payload: .lifecycle(.stop(.user))))
        let stats = await writer.closeStatsWindow(at: StatsFixtures.ms(1_000))
        sink.record(LogEvent(timestamp: StatsFixtures.ms(1_000), payload: .stats(stats)))
        let summary = await writer.finish()
        #expect(summary.failure == nil)

        #expect(replay.allSatisfy { $0.timestamp.nanoseconds < 0 }, "negative t, not clamped")
        let reader = try LogFileReader(url: url, recovery: .strict)
        let events = Array(reader)
        #expect(reader.report.failure == nil && !reader.report.truncatedTail)
        #expect(events.first?.payload == .lifecycle(LifecycleSample(.start)), "start stays the first row")
        #expect(Array(events.dropFirst().prefix(replay.count)) == replay)

        var analyzer = RecordingAnalyzer(header: reader.header)
        for event in events { analyzer.observe(event) }
        let result = analyzer.summary(report: reader.report)
        #expect(result.healthWarnings.isEmpty, "\(result.healthWarnings)")
        for kind in ["link", "elm", "adapter"] {
            #expect(result.kinds.first { $0.kind == kind }?.outOfOrder == 0, "\(kind)")
        }
        #expect(result.firstT == replay.map(\.timestamp).min())
        #expect((15...18).contains(result.pollExchangeHz ?? 0), "live polls only")
        #expect(result.lifecycle["locationAuthorization"] == 1)
        #expect(result.render().contains("locationAuthorization"))
    }

    @Test("locationAuthorization is a stable on-disk lifecycle string (M4)")
    func locationAuthorizationString() throws {
        #expect(LifecycleSample.Event.locationAuthorization.rawValue == "locationAuthorization")
        let sample = LifecycleSample(.locationAuthorization, detail: "authorizationStatus=denied, accuracyAuthorization=full, backgroundActivitySession=none")
        let line = try LogCodec().line(for: LogEvent(timestamp: .zero, payload: .lifecycle(sample)))
        #expect(String(decoding: line, as: UTF8.self)
            == #"{"data":{"detail":"authorizationStatus=denied, accuracyAuthorization=full, backgroundActivitySession=none","event":"locationAuthorization"},"kind":"lifecycle","t":0}"# + "\n")
    }
}
