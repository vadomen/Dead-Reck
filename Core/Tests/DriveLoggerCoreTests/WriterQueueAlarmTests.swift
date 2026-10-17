import Foundation
import Testing

@testable import DriveLoggerCore

// The writer-queue alarm (backlog R4.1-8, M6.1-5): the threshold
// `max(2 s of data, 200)`, its 200-event floor, and whether the start-up init
// replay — written in one burst at Start, counted in the first `stats`
// window — can trip it.

@Suite("Writer queue alarm")
struct WriterQueueAlarmTests {
    static func sample(windowS: Double, total: Int, depth: Int) -> StatsSample {
        StatsSample(
            windowS: windowS, counts: total == 0 ? [:] : ["accel": total - total / 2, "motion": total / 2],
            obdHz: 0, motionHz: 0, gaps: [:], maxGapMs: [:],
            timeouts: 0, queueDepthMax: depth, dropped: 0, bytesWritten: 0
        )
    }

    @Test("Above 2 s of data alarms, at it does not; the detail is the on-disk text")
    func twoSeconds() {
        // 3 700 rows in 10 s: 2 s of data is 740 events.
        #expect(WriterQueueAlarm.twoSecondsOfData(Self.sample(windowS: 10, total: 3_700, depth: 0)) == 740)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 3_700, depth: 740)) == nil)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 3_700, depth: 741))
            == "writer queue peaked at 741 events, more than 2 s of data (740)")
        // Rounded up: 2 × 1 001 / 10 = 200.2 → 201.
        #expect(WriterQueueAlarm.twoSecondsOfData(Self.sample(windowS: 10, total: 1_001, depth: 0)) == 201)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 1_001, depth: 201)) == nil)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 1_001, depth: 202)) != nil)
    }

    @Test("The 200-event floor: a window with little data alarms only above 200; the detail still names 2 s of data")
    func floor() {
        #expect(WriterQueueAlarm.floor == 200)
        // 100 rows in 10 s: 2 s of data is 20 events, below the floor.
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 100, depth: 21)) == nil)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 100, depth: 200)) == nil)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 10, total: 100, depth: 201))
            == "writer queue peaked at 201 events, more than 2 s of data (20)")
    }

    @Test("A window of no length never alarms")
    func emptyWindow() {
        #expect(WriterQueueAlarm.twoSecondsOfData(Self.sample(windowS: 0, total: 5_000, depth: 0)) == nil)
        #expect(WriterQueueAlarm.detail(for: Self.sample(windowS: 0, total: 5_000, depth: 5_000)) == nil)
    }

    /// Full start-up initialisations by the real `ELMSession` against the
    /// scripted adapters, through selection and the ATAT1/ATAT2 comparison:
    /// the Touareg, the bench car, the bench car refusing `ATSH7E0`, and the
    /// longest scripted one, an 11-bit car whose `7E0` answers nothing
    /// (physical selection, `ATSH7DF`, functional selection).
    static let initScenarios: [(name: String, rules: [MockELMAdapter.Rule])] = [
        ("touareg", MockELMAdapter.Rule.touareg),
        ("bench car", MockELMAdapter.Rule.benchCar),
        ("bench car, ATSH7E0 refused", [refuseATSH7E0] + MockELMAdapter.Rule.benchCar),
        ("7E0 reaches nothing", gateCarRules(
            dpn: "A6", supported: PhysicalAddressingGateTests.engine0100,
            functional: ["010D0C": "7E806410D3C0C0BB8\r7E906410D3B0C0BB8"]
        )),
    ]

    /// Rows the recorder writes at Start in the same main-actor step as the
    /// replay, besides it: `start`, `thermalState`, an `error` per source
    /// (four on a phone), `locationAuthorization`, the background-risk
    /// `error`, `calibrationStart`.
    static let otherStartRows = 9

    @Test(
        "M6.1-5: a full start-up init replay is far below the 200-event floor, so it cannot trip the alarm in the first window",
        arguments: initScenarios.indices
    )
    func replayBurstBelowFloor(scenario: Int) async throws {
        let (name, rules) = Self.initScenarios[scenario]
        let harness = SessionHarness(rules: rules, configuration: ELMSessionProbeTests.probing)
        _ = try await harness.initialise()
        let initEvents: [LinkEvent] = [.ble(from: .discovering, to: .connected, reason: "vgate", uptime: 0)]
            + (await harness.log.events).map { .session($0) }

        let clock = SessionClock(
            referenceUptimeSeconds: 1_000, wallClockStart: Date(timeIntervalSince1970: 1_790_000_000),
            source: FixedUptimeSource(uptimeSeconds: 1_000)
        )
        let replay = initEvents.flatMap { LogEvent.rows(for: $0, adapter: MappingFixtures.bleAdapter, clock: clock) }
        let burst = 1 + replay.count + Self.otherStartRows
        // The worst case: the writer took none of the burst before the window
        // closed, and the window held nothing else (a real one also holds
        // ~10 s of sensor rows, which only raises the threshold).
        #expect(burst < WriterQueueAlarm.floor / 2, "\(name): \(replay.count) replay rows")
        let worst = StatsSample(
            windowS: 10, counts: ["lifecycle": 1 + Self.otherStartRows, "elm": replay.count],
            obdHz: 0, motionHz: 0, gaps: [:], maxGapMs: [:],
            timeouts: 0, queueDepthMax: burst, dropped: 0, bytesWritten: 0
        )
        #expect(WriterQueueAlarm.detail(for: worst) == nil, "\(name)")

        // Measured: the burst through a real writer, as the recorder writes it.
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let header = LogHeader(clock: clock, app: LogFixtures.app, device: LogFixtures.device, timeZone: "UTC")
        let writer = try LogFileWriter(
            url: scratch.url.appendingPathComponent("replay.jsonl.gz"), header: header,
            flushInterval: .seconds(3_600), diskSpace: FakeDiskSpace(WriterFixtures.roomy)
        )
        writer.sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(LifecycleSample(.start))))
        for row in replay { writer.sink.record(row) }
        for _ in 0..<Self.otherStartRows {
            writer.sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(LifecycleSample(.calibrationStart))))
        }
        let first = await writer.closeStatsWindow(at: MonotonicTimestamp(seconds: 10))
        #expect(first.queueDepthMax <= burst)
        #expect(first.counts.values.reduce(0, +) == burst)
        #expect(WriterQueueAlarm.detail(for: first) == nil, "\(name): peak \(first.queueDepthMax)")
        _ = await writer.finish()
    }
}
