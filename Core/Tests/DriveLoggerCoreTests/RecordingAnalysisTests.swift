import Foundation
import Testing

@testable import DriveLoggerCore

enum AnalysisFixtures {
    static func ms(_ value: Double) -> MonotonicTimestamp { StatsFixtures.ms(value) }

    static func obd(seq: Int, pid: OBDPID = .vehicleSpeed, requestMs: Double, replyMs: Double) -> LogEvent {
        .obd(
            OBDSample(pid: pid, value: 50, unit: pid.unit, raw: "7E803410D32", requestT: ms(requestMs), command: "010D0C1", ecu: "7E8", seq: seq),
            at: ms(replyMs)
        )
    }

    /// A manual fix confirmed at `ms`, pressed 2.4 s earlier, near (0, 0).
    static func manualFix(at ms: Double) -> LogEvent {
        LogEvent(timestamp: Self.ms(ms), payload: .manualFix(ManualFixSample(
            latitude: 0.0125, longitude: -0.025, pressedT: Self.ms(ms - 2_400), mapSpanM: 250,
            obdSpeedKmh: 5, obdSpeedT: Self.ms(ms - 3_200), gpsSpeedKmh: 5.4,
            speedSource: "obd", gateSpeedKmh: 5, note: "tunnel exit"
        )))
    }

    static let header = LogHeader(
        sessionID: LogFixtures.sessionID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        referenceUptimeSeconds: 1_234.5,
        app: LogFixtures.app,
        device: LogFixtures.device,
        notes: "analysis",
        adapter: MappingFixtures.bleAdapter.with(MappingFixtures.info),
        polling: PollingRecord(MappingFixtures.multiPlan),
        sensors: SensorConfigRecord(deviceMotionHz: 100, accelerometerHz: 100, gyroHz: 100, magnetometerHz: 10, referenceFrame: "xArbitraryZVertical", altimeter: true),
        mount: "windscreen",
        vehicle: "Touareg 2025",
        timeZone: "Europe/Kyiv"
    )
}

@Suite("Recording analysis")
struct RecordingAnalysisTests {
    typealias F = AnalysisFixtures

    @Test("Per-kind counts, span, achieved rate, gaps over 50 ms and out-of-order rows")
    func kinds() {
        var analyzer = RecordingAnalyzer(header: F.header)
        for index in 0..<101 where index != 50 && index != 51 {  // a 30 ms hole: no gap
            analyzer.observe(StatsFixtures.motion(at: Double(index) * 10))
        }
        for t in [0.0, 10, 20, 200, 210, 205] {  // 180 ms gap, one row out of order
            analyzer.observe(StatsFixtures.accel(at: t))
        }
        analyzer.observe(.marker("tunnel", at: F.ms(500)))
        let summary = analyzer.summary(report: LogReadReport(members: 3, truncatedTail: false, skippedLineIndices: []))

        #expect(summary.eventCount == 99 + 6 + 1)
        #expect(summary.firstT == F.ms(0))
        #expect(summary.lastT == F.ms(1_000))
        let motion = summary.kinds.first { $0.kind == "motion" }
        #expect(motion?.count == 99)
        #expect(motion?.rateHz == 98)                     // 98 intervals over 1 s
        #expect(motion?.gapsOver50ms == 0)
        #expect(motion?.maxIntervalMs == 30)
        let accel = summary.kinds.first { $0.kind == "accel" }
        #expect(accel?.gapsOver50ms == 1)
        #expect(accel?.maxIntervalMs == 180)
        #expect(accel?.outOfOrder == 1)
        let marker = summary.kinds.first { $0.kind == "marker" }
        #expect(marker?.gapsOver50ms == nil)              // only the 100 Hz streams
        #expect(summary.markers == [RecordingSummary.Marker(t: F.ms(500), text: "tunnel")])
        // Known kinds first, in format order.
        #expect(summary.kinds.map(\.kind) == ["motion", "marker", "accel"])
    }

    @Test("OBD latency percentiles are per exchange (seq), in milliseconds")
    func latency() {
        var analyzer = RecordingAnalyzer(header: F.header)
        // Ten exchanges with latencies 10, 20, …, 100 ms; each multi-PID
        // exchange produced two rows, which must count once.
        for seq in 1...10 {
            let request = Double(seq) * 1_000
            analyzer.observe(F.obd(seq: seq, pid: .vehicleSpeed, requestMs: request, replyMs: request + Double(seq) * 10))
            analyzer.observe(F.obd(seq: seq, pid: .engineSpeed, requestMs: request, replyMs: request + Double(seq) * 10))
        }
        let latency = analyzer.summary(report: LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: [])).obdLatency
        #expect(latency?.count == 10)
        #expect(latency?.minMs == 10)
        #expect(latency?.p50Ms == 50)
        #expect(latency?.p90Ms == 90)
        #expect(latency?.p99Ms == 100)
        #expect(latency?.maxMs == 100)
        #expect(latency?.negative == 0)
    }

    @Test("Nearest-rank percentiles")
    func percentiles() {
        let summary = RecordingSummary.Latency(milliseconds: [5, 1, 4, 2, 3])
        #expect(summary?.minMs == 1)
        #expect(summary?.p50Ms == 3)
        #expect(summary?.p90Ms == 5)
        #expect(summary?.maxMs == 5)
        #expect(RecordingSummary.Latency(milliseconds: []) == nil)
        #expect(RecordingSummary.Latency(milliseconds: [-2, 7])?.negative == 1)
    }

    @Test("ELM outcomes, poll rate, lifecycle and stats rows are aggregated")
    func aggregates() {
        var analyzer = RecordingAnalyzer(header: F.header)
        for index in 0..<11 {
            analyzer.observe(StatsFixtures.elm(.ok, at: Double(index) * 100))
        }
        analyzer.observe(StatsFixtures.elm(.noData, at: 50))
        analyzer.observe(StatsFixtures.elm(.timeout, at: 60))
        analyzer.observe(LogEvent(timestamp: F.ms(0), payload: .lifecycle(LifecycleSample(.start))))
        analyzer.observe(LogEvent(timestamp: F.ms(5), payload: .lifecycle(LifecycleSample(.background))))
        analyzer.observe(LogEvent(timestamp: F.ms(6), payload: .lifecycle(LifecycleSample(.error, detail: "disk on fire"))))
        for (index, motionHz) in [99.5, 100.0].enumerated() {
            analyzer.observe(LogEvent(timestamp: F.ms(Double(index + 1) * 10_000), payload: .stats(StatsSample(
                windowS: 10, counts: ["motion": 995], obdHz: 9, motionHz: motionHz,
                gaps: ["motion": index, "accel": 0, "gyro": 2], maxGapMs: ["motion": 60],
                timeouts: 1, queueDepthMax: 40 + index, dropped: index, bytesWritten: 1_000 * (index + 1)
            ))))
        }
        let summary = analyzer.summary(report: LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: []))
        #expect(summary.elmOutcomes == ["ok": 11, "noData": 1, "timeout": 1])
        #expect(summary.pollExchangeHz == 10)
        #expect(summary.lifecycle == ["start": 1, "background": 1, "error": 1])
        #expect(summary.errors == ["disk on fire"])
        let stats = summary.stats
        #expect(stats?.rows == 2)
        #expect(stats?.minMotionHz == 99.5)
        #expect(stats?.maxQueueDepth == 41)
        #expect(stats?.totalDropped == 1)
        #expect(stats?.totalTimeouts == 2)
        #expect(stats?.totalGaps == ["motion": 1, "accel": 0, "gyro": 4])
        #expect(stats?.lastBytesWritten == 2_000)
    }

    @Test("Health flags a truncated tail, damaged members, skipped lines, drops and gaps")
    func health() {
        var analyzer = RecordingAnalyzer(header: F.header)
        analyzer.observe(StatsFixtures.motion(at: 0))
        analyzer.observe(StatsFixtures.motion(at: 100))
        analyzer.observe(LogEvent(timestamp: F.ms(10_000), payload: .stats(StatsSample(
            windowS: 10, counts: [:], obdHz: 0, motionHz: 0, gaps: [:], maxGapMs: [:],
            timeouts: 0, queueDepthMax: 0, dropped: 3, bytesWritten: 0
        ))))
        let damaged = LogReadReport(members: 5, truncatedTail: true, skippedLineIndices: [7], damagedMemberIndices: [2])
        let warnings = analyzer.summary(report: damaged).healthWarnings
        #expect(warnings.contains { $0.contains("truncated") })
        #expect(warnings.contains { $0.contains("damaged") })
        #expect(warnings.contains { $0.contains("skipped") })
        #expect(warnings.contains { $0.contains("dropped") })
        #expect(warnings.contains { $0.contains("gap") })

        var clean = RecordingAnalyzer(header: F.header)
        for index in 0..<10 { clean.observe(StatsFixtures.motion(at: Double(index) * 10)) }
        #expect(clean.summary(report: LogReadReport(members: 2, truncatedTail: false, skippedLineIndices: [])).healthWarnings.isEmpty)
    }

    @Test("The rendered report names the header, kinds, latency and integrity")
    func render() {
        var analyzer = RecordingAnalyzer(header: F.header)
        for index in 0..<10 { analyzer.observe(StatsFixtures.motion(at: Double(index) * 10)) }
        analyzer.observe(F.obd(seq: 1, requestMs: 0, replyMs: 42))
        analyzer.observe(StatsFixtures.elm(.ok, at: 42))
        let text = analyzer.summary(report: LogReadReport(members: 2, truncatedTail: true, skippedLineIndices: [])).render()
        for needle in [
            "3F2504E0-4F89-41D3-9A0C-0305E82C3301", "2023-11-14T22:13:20Z", "Europe/Kyiv", "iPhone15,2",
            "IOS-Vlink", "ELM327 v2.1", "010D0C1", "Touareg 2025", "motion", "obd", "OBD latency",
            "42.0", "ok 1", "truncated tail: yes",
        ] {
            #expect(text.contains(needle), "missing \(needle) in\n\(text)")
        }
    }

    @Test("Manual fixes are counted and listed: t, speedSource, gate speed, press-to-confirm delay, note")
    func manualFixes() {
        var analyzer = RecordingAnalyzer(header: F.header)
        analyzer.observe(F.manualFix(at: 4_200))
        analyzer.observe(LogEvent(timestamp: F.ms(9_000), payload: .manualFix(
            ManualFixSample(latitude: 0, longitude: 0, pressedT: F.ms(8_500), speedSource: "unknown")
        )))
        let summary = analyzer.summary(report: LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: []))
        #expect(summary.manualFixes.count == 2)
        #expect(summary.manualFixes.first?.t == F.ms(4_200))
        #expect(summary.manualFixes.first?.sample.speedSource == "obd")
        #expect(summary.kinds.first { $0.kind == "manualFix" }?.count == 2)

        let text = summary.render()
        for needle in [
            "Manual fixes  2",
            "4.200 s  obd 5.0 km/h  pressed 2.40 s earlier  0.0125000, -0.0250000  note: tunnel exit",
            "9.000 s  unknown -  pressed 0.50 s earlier  0.0000000, 0.0000000",
        ] {
            #expect(text.contains(needle), "missing \(needle) in\n\(text)")
        }
    }

    @Test("No manual fixes: a v3 recording says none, an older one says nothing")
    func noManualFixes() {
        var v3 = F.header
        v3.formatVersion = .v3
        let empty = LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: [])
        #expect(RecordingAnalyzer(header: v3).summary(report: empty).render().contains("Manual fixes  none"))
        var v2 = F.header
        v2.formatVersion = .v2
        #expect(!RecordingAnalyzer(header: v2).summary(report: empty).render().contains("Manual fixes"))
    }
}

@Suite("Recording CSV")
struct RecordingCSVTests {
    static let samples: [LogEvent] = {
        let t = MonotonicTimestamp(nanoseconds: -5)
        return [
            .motion(LogFixtures.motion, at: t),
            .location(SimulatedLocationModel.fix(index: 3, intervalS: 1), at: t),
            AnalysisFixtures.obd(seq: 3, requestMs: 1, replyMs: 2),
            .marker("tunnel, \"long\"", at: t),
            LogEvent(timestamp: t, payload: .accelerometer(Vector3(x: 1, y: 2, z: 3))),
            LogEvent(timestamp: t, payload: .gyroscope(.zero)),
            LogEvent(timestamp: t, payload: .magnetometer(.zero)),
            LogEvent(timestamp: t, payload: .barometer(BarometerSample(pressureKPa: 101.3, relativeAltitude: -0.5))),
            StatsFixtures.elm(.ok, at: 3),
            LogEvent(timestamp: t, payload: .adapter(AdapterEventSample(adapter: MappingFixtures.bleAdapter, polling: PollingRecord(.baseline)))),
            LogEvent(timestamp: t, payload: .link(LinkSample(layer: "ble", from: "idle", to: "scanning"))),
            LogEvent(timestamp: t, payload: .lifecycle(LifecycleSample(.stop, detail: "user"))),
            LogEvent(timestamp: t, payload: .stats(StatsSample(
                windowS: 10, counts: ["motion": 1_000], obdHz: 9.5, motionHz: 100, gaps: ["motion": 1],
                maxGapMs: ["motion": 61.5], timeouts: 0, queueDepthMax: 3, dropped: 0, bytesWritten: 77
            ))),
            LogEvent(timestamp: t, payload: .unrecognized(kind: "future/kind", data: .object(["a": .int(1)]))),
            LogEvent(timestamp: t, payload: .manualFix(ManualFixSample(latitude: 0, longitude: 0, pressedT: t, speedSource: "unknown"))),
        ]
    }()

    @Test("Every kind has as many values as columns, starting with t")
    func shapes() {
        for event in Self.samples {
            let columns = RecordingCSV.columns(for: event.payload.kind)
            let values = RecordingCSV.values(for: event)
            #expect(columns.first == "t")
            #expect(values.first == "-5" || event.payload.kind == "obd" || event.payload.kind == "elm")
            #expect(columns.count == values.count, "\(event.payload.kind): \(columns) vs \(values)")
        }
    }

    @Test("Fields with commas, quotes or line breaks are quoted RFC 4180-style")
    func escaping() {
        #expect(RecordingCSV.line(["a", "b,c", "say \"hi\"", "7E8\r\r", ""]) == "a,\"b,c\",\"say \"\"hi\"\"\",\"7E8\r\r\",\n")
    }

    @Test("Values are lossless: integer nanoseconds, shortest round-trip doubles, empty for absent")
    func values() {
        let obd = RecordingCSV.values(for: AnalysisFixtures.obd(seq: 3, requestMs: 1, replyMs: 2))
        #expect(obd == ["2000000", "13", "50.0", "km/h", "7E803410D32", "1000000", "010D0C1", "7E8", "3"])
        let motion = RecordingCSV.values(for: .motion(LogFixtures.motion, at: .zero))
        #expect(motion[1] == "0.1")
        #expect(motion.last == "")                         // magneticAccuracy absent
    }

    @Test("manualFix.csv has every field; absent optional fields are empty cells")
    func manualFixValues() {
        #expect(RecordingCSV.columns(for: "manualFix") == [
            "t", "latitude", "longitude", "pressedT", "mapSpanM", "obdSpeedKmh", "obdSpeedT",
            "gpsSpeedKmh", "speedSource", "gateSpeedKmh", "note",
        ])
        #expect(RecordingCSV.values(for: AnalysisFixtures.manualFix(at: 4_200)) == [
            "4200000000", "0.0125", "-0.025", "1800000000", "250.0", "5.0", "1000000000",
            "5.4", "obd", "5.0", "tunnel exit",
        ])
        let minimal = LogEvent(timestamp: .zero, payload: .manualFix(
            ManualFixSample(latitude: 0, longitude: 0, pressedT: .zero, speedSource: "unknown")
        ))
        #expect(RecordingCSV.values(for: minimal) == ["0", "0.0", "0.0", "0", "", "", "", "", "unknown", "", ""])
        #expect(RecordingCSV.fileName(for: "manualFix") == "manualFix.csv")
    }

    @Test("The exporter writes one CSV per kind with a header row")
    func exporter() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let exporter = try RecordingCSVExporter(directory: scratch.url.appendingPathComponent("csv"))
        for event in Self.samples + Self.samples {
            try exporter.write(event)
        }
        let rows = try exporter.finish()
        #expect(rows["motion"] == 2)
        #expect(rows.count == Self.samples.count)
        let motion = try String(contentsOf: scratch.url.appendingPathComponent("csv/motion.csv"), encoding: .utf8)
        let lines = motion.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.first == Substring(RecordingCSV.columns(for: "motion").joined(separator: ",")))
        // Unknown kinds get a file-system-safe name.
        #expect(FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("csv/future_kind.csv").path))
    }
}

/// End to end: simulated sources → sink → writer → file → reader → analysis.
@Suite("Recording pipeline")
struct RecordingPipelineTests {
    @Test("A short simulated drive is complete, ordered and healthy")
    @MainActor
    func simulatedDrive() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let directory = ProcessInfo.processInfo.environment["INSPECT_LOG_SAMPLE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? scratch.url
        let clock = SessionClock()
        let header = LogHeader(clock: clock, app: LogFixtures.app, device: LogFixtures.device, notes: "simulated drive", timeZone: "UTC")
        let url = directory.appendingPathComponent(LogFileName.make(for: clock.wallClockStart, timeZone: TimeZone(identifier: "UTC")!, collisionIndex: Int.random(in: 2...1_000_000)))
        let writer = try LogFileWriter(url: url, header: header, flushInterval: .milliseconds(100), diskSpace: FakeDiskSpace(WriterFixtures.roomy))
        let motion = SimulatedMotionSource(rateHz: 100)
        let location = SimulatedLocationSource(interval: .milliseconds(100))
        try motion.start(clock: clock, sink: writer.sink)
        try location.start(clock: clock, sink: writer.sink)
        try await Task.sleep(for: .milliseconds(600))
        motion.stop()
        location.stop()
        let summary = await writer.finish()
        #expect(summary.failure == nil)
        #expect(writer.sink.dropped == 0)

        let reader = try LogFileReader(url: url)
        var analyzer = RecordingAnalyzer(header: reader.header)
        for event in reader { analyzer.observe(event) }
        let result = analyzer.summary(report: reader.report)
        #expect(result.eventCount == summary.eventCount)
        #expect(result.kinds.first { $0.kind == "motion" }?.gapsOver50ms == 0)
        #expect(result.kinds.first { $0.kind == "motion" }?.outOfOrder == 0)
        #expect(result.kinds.first { $0.kind == "location" }.map { $0.count >= 1 } == true)
        #expect(result.healthWarnings.isEmpty, "\(result.healthWarnings)")
        #expect(!reader.report.truncatedTail)
    }
}
