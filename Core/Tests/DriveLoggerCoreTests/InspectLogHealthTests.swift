import Foundation
import Testing

@testable import DriveLoggerCore

// `inspect_log`'s health warnings and `stats` aggregation on shapes real
// drives produce (backlog M2-S4, M2-S5, M6.1-2): a reconnect's `link` rows
// in emission order, a final `stats` window a few milliseconds long, and a
// start-up init replay whose rows predate the `start` row by a minute.

@Suite("inspect_log health on real recording shapes")
struct InspectLogHealthTests {
    typealias F = AnalysisFixtures

    static func link(_ layer: String, _ from: String, _ to: String, reason: String? = nil, at ms: Double) -> LogEvent {
        LogEvent(timestamp: F.ms(ms), payload: .link(LinkSample(layer: layer, from: from, to: to, reason: reason)))
    }

    static func stats(windowS: Double, motionHz: Double, obdHz: Double, at ms: Double) -> LogEvent {
        LogEvent(timestamp: F.ms(ms), payload: .stats(StatsSample(
            windowS: windowS, counts: [:], obdHz: obdHz, motionHz: motionHz,
            gaps: [:], maxGapMs: [:], timeouts: 0, queueDepthMax: 3, dropped: 0, bytesWritten: 1_000
        )))
    }

    static let clean = LogReadReport(members: 3, truncatedTail: false, skippedLineIndices: [])

    /// One adapter reconnect, as the M2 part 2 E2E run wrote it: the BLE
    /// layer's `disconnected → reconnecting` rows are emitted before the ELM
    /// session's `polling → failed (transport closed)` row, which is stamped
    /// microseconds earlier; the old session's last `elm` timeout row is
    /// emitted after the new session's first exchange. 13 `link` rows, so one
    /// reordering is more than 1 % of them.
    static func reconnect() -> [LogEvent] {
        var rows: [LogEvent] = [
            LogEvent(timestamp: F.ms(0), payload: .lifecycle(LifecycleSample(.start))),
            link("ble", "idle", "connecting", at: 100),
            link("ble", "connecting", "discovering", at: 400),
            link("ble", "discovering", "connected", reason: "vgate", at: 900),
            link("elm", "idle", "resetting", at: 1_000),
            link("elm", "probing", "ready", at: 2_800),
            link("elm", "ready", "polling", at: 2_900),
        ]
        for index in 0..<30 {
            rows.append(StatsFixtures.elm(.ok, at: 3_000 + Double(index) * 60))
        }
        rows += [
            link("ble", "connected", "disconnected", reason: "link lost", at: 5_000.020),
            link("ble", "disconnected", "reconnecting", at: 5_000.030),
            link("elm", "polling", "failed", reason: "transport closed", at: 5_000.010),  // emitted later, stamped earlier
            link("ble", "reconnecting", "connecting", at: 6_000),
            link("ble", "connecting", "discovering", at: 6_300),
            link("ble", "discovering", "connected", reason: "vgate", at: 6_800),
            link("elm", "idle", "resetting", at: 6_900),
        ]
        rows.append(StatsFixtures.elm(.ok, phase: .initialisation, at: 7_000))
        rows.append(StatsFixtures.elm(.timeout, at: 5_100))  // the old session's last row, delivered late
        for index in 0..<30 {
            rows.append(StatsFixtures.elm(.ok, at: 8_000 + Double(index) * 60))
        }
        return rows
    }

    @Test("A reconnect's link and elm rows in emission order are not an out-of-order warning; the table still counts them (M2-S4)")
    func reconnectIsHealthy() {
        var analyzer = RecordingAnalyzer(header: F.header)
        for row in Self.reconnect() { analyzer.observe(row) }
        let summary = analyzer.summary(report: Self.clean)

        let link = summary.kinds.first { $0.kind == "link" }
        #expect(link?.count == 13)
        #expect(link?.outOfOrder == 1, "still counted in the table")
        #expect(summary.kinds.first { $0.kind == "elm" }?.outOfOrder == 1)
        #expect(summary.healthWarnings.isEmpty, "\(summary.healthWarnings)")
        #expect(summary.render().contains("Health        OK"))
    }

    @Test("Out-of-order sensor rows above 1 % still warn (M2-S4 leaves the rule for every other kind)")
    func sensorOutOfOrderStillWarns() {
        var analyzer = RecordingAnalyzer(header: F.header)
        for t in [0.0, 10, 20, 15, 30, 40, 35, 50] {  // 2 of 8 out of order
            analyzer.observe(StatsFixtures.motion(at: t))
        }
        #expect(analyzer.summary(report: Self.clean).healthWarnings == ["motion: 2 out-of-order row(s)"])
    }

    @Test("Stats Hz means are weighted by windowS; a final window under 1 s is left out of the minimums (M2-S5)")
    func statsMeansAndMinimums() {
        var analyzer = RecordingAnalyzer(header: F.header)
        // Three full windows of a healthy drive, then the stop's 5 ms window:
        // 182 Hz motion (one sample in 5.5 ms), no poll in it.
        for (index, (motion, obd)) in [(100.0, 16.0), (99.0, 16.0), (101.0, 17.0)].enumerated() {
            analyzer.observe(Self.stats(windowS: 10, motionHz: motion, obdHz: obd, at: Double(index + 1) * 10_000))
        }
        analyzer.observe(Self.stats(windowS: 0.005, motionHz: 182, obdHz: 0, at: 30_005))
        let stats = analyzer.summary(report: Self.clean).stats

        #expect(stats?.rows == 4)
        // (100 + 99 + 101) × 10 + 182 × 0.005 = 3 000.91 motion rows over 30.005 s.
        #expect(abs((stats?.meanMotionHz ?? 0) - 3_000.91 / 30.005) < 1e-9)
        #expect(abs((stats?.meanObdHz ?? 0) - 490 / 30.005) < 1e-9)
        #expect(stats?.minMotionHz == 99)
        #expect(stats?.minObdHz == 16, "not the 5 ms window's 0 Hz")
        #expect(analyzer.summary(report: Self.clean).render().contains("motionHz min 99.0 mean 100.0; obdHz min 16.0 mean 16.3"))

        // Exactly `minimumWindowS` long counts.
        #expect(RecordingSummary.Stats.minimumWindowS == 1)
        analyzer.observe(Self.stats(windowS: 1, motionHz: 60, obdHz: 8, at: 31_005))
        let withOneSecond = analyzer.summary(report: Self.clean).stats
        #expect(withOneSecond?.minMotionHz == 60 && withOneSecond?.minObdHz == 8)
    }

    @Test("Stats rows all shorter than 1 s: the minimums fall back to every window; zero total windowS falls back to the plain mean (M2-S5)")
    func statsShortWindowsOnly() {
        var analyzer = RecordingAnalyzer(header: F.header)
        analyzer.observe(Self.stats(windowS: 0.5, motionHz: 98, obdHz: 10, at: 500))
        analyzer.observe(Self.stats(windowS: 0.25, motionHz: 104, obdHz: 0, at: 750))
        let stats = analyzer.summary(report: Self.clean).stats
        #expect(stats?.minMotionHz == 98)
        #expect(stats?.minObdHz == 0)
        #expect(abs((stats?.meanMotionHz ?? 0) - (98 * 0.5 + 104 * 0.25) / 0.75) < 1e-9)

        var empty = RecordingAnalyzer(header: F.header)
        empty.observe(Self.stats(windowS: 0, motionHz: 0, obdHz: 0, at: 0))
        empty.observe(Self.stats(windowS: 0, motionHz: 0, obdHz: 0, at: 0))
        let none = empty.summary(report: Self.clean).stats
        #expect(none?.meanMotionHz == 0 && none?.minMotionHz == 0)
    }

    /// A v2 recording 20 s long from its `start` row, whose start-up init
    /// replay is stamped 60 s before Start, and no `stats` rows.
    static func replayedInitWithoutStats() -> [LogEvent] {
        var rows: [LogEvent] = [LogEvent(timestamp: F.ms(0), payload: .lifecycle(LifecycleSample(.start)))]
        rows.append(link("ble", "discovering", "connected", reason: "vgate", at: -60_000))
        rows.append(StatsFixtures.elm(.ok, phase: .initialisation, at: -59_000))
        rows.append(link("elm", "ready", "polling", at: -58_000))
        for index in 0..<2_001 {
            rows.append(StatsFixtures.motion(at: Double(index) * 10))
        }
        return rows
    }

    @Test("Duration and the no-stats check measure from the start row, not from the replay's first t; the pre-Start span is printed apart (M6.1-2)")
    func durationFromStartRow() {
        var v2 = F.header
        v2.formatVersion = .v2
        var analyzer = RecordingAnalyzer(header: v2)
        for row in Self.replayedInitWithoutStats() { analyzer.observe(row) }
        let summary = analyzer.summary(report: Self.clean)

        #expect(summary.firstT == F.ms(-60_000), "firstT is still the earliest row")
        #expect(summary.startT == F.ms(0))
        #expect(summary.healthWarnings.isEmpty, "20 s from start: no stats row is due yet; \(summary.healthWarnings)")
        let text = summary.render()
        #expect(text.contains("Duration      20.000 s  (t 0.000 … 20.000 s, from the start row)"), "\(text)")
        #expect(text.contains("Pre-Start     60.000 s  (t -60.000 … 0.000 s, rows stamped before the start row)"), "\(text)")
    }

    @Test("Longer than 30 s from the start row without stats rows still warns; a file with no start row measures from its first row (M6.1-2)")
    func noStatsStillWarns() {
        var v2 = F.header
        v2.formatVersion = .v2
        var analyzer = RecordingAnalyzer(header: v2)
        for row in Self.replayedInitWithoutStats() { analyzer.observe(row) }
        analyzer.observe(.marker("end", at: F.ms(30_001)))
        #expect(analyzer.summary(report: Self.clean).healthWarnings == ["no stats rows in a v2 recording longer than 30 s"])

        var headless = RecordingAnalyzer(header: v2)
        headless.observe(.marker("a", at: F.ms(-1)))
        headless.observe(.marker("b", at: F.ms(30_000)))
        let summary = headless.summary(report: Self.clean)
        #expect(summary.startT == nil)
        #expect(summary.healthWarnings == ["no stats rows in a v2 recording longer than 30 s"])
        #expect(summary.render().contains("Duration      30.001 s  (t -0.001 … 30.000 s)\n"))
        #expect(!summary.render().contains("Pre-Start"))
    }

    @Test("A file whose start row is its first row has no Pre-Start line: firstT == startT is not a pre-Start span (R46.1-1)")
    func startRowFirstHasNoPreStart() {
        var v2 = F.header
        v2.formatVersion = .v2
        var analyzer = RecordingAnalyzer(header: v2)
        analyzer.observe(LogEvent(timestamp: F.ms(250), payload: .lifecycle(LifecycleSample(.start))))
        for index in 0..<100 {
            analyzer.observe(StatsFixtures.motion(at: 250 + Double(index) * 10))
        }
        let summary = analyzer.summary(report: Self.clean)

        #expect(summary.firstT == F.ms(250))
        #expect(summary.startT == summary.firstT)
        let text = summary.render()
        #expect(text.contains("Duration      0.990 s  (t 0.250 … 1.240 s, from the start row)"), "\(text)")
        #expect(!text.contains("Pre-Start"), "\(text)")
    }
}
