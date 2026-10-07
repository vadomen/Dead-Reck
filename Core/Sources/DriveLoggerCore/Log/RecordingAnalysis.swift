import Foundation

// The analysis behind `inspect_log` (docs/PLAN.md §4.7), in Core so it is
// tested by `swift test`. `inspect_log/main.swift` only parses arguments,
// streams a `LogFileReader` through a `RecordingAnalyzer` and prints
// `RecordingSummary.render()`.

/// Accumulates what `inspect_log` reports, one event at a time, so a
/// multi-hundred-megabyte drive streams through without being held whole.
///
/// Keeps one `Int64` per event for the timestamp-ordered interval analysis
/// (about 20 MB for a 2-hour drive) and one latency per OBD exchange.
public struct RecordingAnalyzer {
    private let header: LogHeader
    private var eventCount = 0
    private var firstT: Int64?
    private var lastT: Int64?
    private var perKind: [String: KindAccumulator] = [:]
    private var obdLatencyBySeq: [Int: Double] = [:]
    private var obdLatencyUnsequenced: [Double] = []
    private var elmOutcomes: [String: Int] = [:]
    private var pollOKTimes: [Int64] = []
    private var lifecycle: [String: Int] = [:]
    private var errors: [String] = []
    private var markers: [RecordingSummary.Marker] = []
    private var stats = StatsAccumulation()

    public init(header: LogHeader) {
        self.header = header
    }

    public mutating func observe(_ event: LogEvent) {
        let t = event.timestamp.nanoseconds
        eventCount += 1
        firstT = min(firstT ?? t, t)
        lastT = max(lastT ?? t, t)
        perKind[event.payload.kind, default: KindAccumulator()].observe(t)

        switch event.payload {
        case .obd(let sample):
            if let requestT = sample.requestT {
                let latency = Double(t - requestT.nanoseconds) / 1_000_000
                if let seq = sample.seq {
                    obdLatencyBySeq[seq] = obdLatencyBySeq[seq] ?? latency
                } else {
                    obdLatencyUnsequenced.append(latency)
                }
            }
        case .elm(let exchange):
            elmOutcomes[exchange.outcome, default: 0] += 1
            if exchange.outcome == ELMOutcome.ok.rawValue, exchange.phase == ELMPhase.poll.rawValue {
                pollOKTimes.append(t)
            }
        case .lifecycle(let sample):
            lifecycle[sample.event, default: 0] += 1
            if sample.event == LifecycleSample.Event.error.rawValue {
                errors.append(sample.detail ?? "(no detail)")
            }
        case .marker(let text):
            markers.append(RecordingSummary.Marker(t: event.timestamp, text: text))
        case .stats(let sample):
            stats.observe(sample)
        default:
            break
        }
    }

    public func summary(report: LogReadReport) -> RecordingSummary {
        let known = LogEventKind.allCases.map(\.rawValue)
        let order = known + perKind.keys.filter { !known.contains($0) }.sorted()
        let gapKinds = StatsAccumulator.gapKinds.map(\.rawValue)
        let kinds = order.compactMap { kind in
            perKind[kind].map { $0.summary(kind: kind, checkGaps: gapKinds.contains(kind)) }
        }

        let pollHz: Double? = {
            guard let first = pollOKTimes.min(), let last = pollOKTimes.max(), last > first else { return nil }
            return Double(pollOKTimes.count - 1) / (Double(last - first) / 1e9)
        }()

        return RecordingSummary(
            header: header,
            report: report,
            eventCount: eventCount,
            firstT: firstT.map(MonotonicTimestamp.init(nanoseconds:)),
            lastT: lastT.map(MonotonicTimestamp.init(nanoseconds:)),
            kinds: kinds,
            obdLatency: RecordingSummary.Latency(milliseconds: Array(obdLatencyBySeq.values) + obdLatencyUnsequenced),
            elmOutcomes: elmOutcomes,
            pollExchangeHz: pollHz,
            lifecycle: lifecycle,
            errors: errors,
            markers: markers,
            stats: stats.summary
        )
    }
}

private struct KindAccumulator {
    var times: [Int64] = []
    var outOfOrder = 0

    mutating func observe(_ t: Int64) {
        if let previous = times.last, t < previous {
            outOfOrder += 1
        }
        times.append(t)
    }

    func summary(kind: String, checkGaps: Bool) -> RecordingSummary.Kind {
        let sorted = times.sorted()
        var longest: Int64?
        var gaps = 0
        var gapTotal: Int64 = 0
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            let interval = later - earlier
            longest = max(longest ?? 0, interval)
            if interval > StatsAccumulator.gapThreshold.nanoseconds {
                gaps += 1
                gapTotal += interval
            }
        }
        let span = (sorted.last ?? 0) - (sorted.first ?? 0)
        return RecordingSummary.Kind(
            kind: kind,
            count: times.count,
            firstT: sorted.first.map(MonotonicTimestamp.init(nanoseconds:)),
            lastT: sorted.last.map(MonotonicTimestamp.init(nanoseconds:)),
            rateHz: span > 0 ? Double(times.count - 1) / (Double(span) / 1e9) : nil,
            maxIntervalMs: longest.map { Double($0) / 1e6 },
            gapsOver50ms: checkGaps ? gaps : nil,
            gapTotalMs: checkGaps ? Double(gapTotal) / 1e6 : nil,
            outOfOrder: outOfOrder
        )
    }
}

private struct StatsAccumulation {
    var rows = 0
    var motionHz: [Double] = []
    var obdHz: [Double] = []
    var maxQueueDepth = 0
    var totalDropped = 0
    var totalTimeouts = 0
    var totalGaps: [String: Int] = [:]
    var lastBytesWritten = 0

    mutating func observe(_ sample: StatsSample) {
        rows += 1
        motionHz.append(sample.motionHz)
        obdHz.append(sample.obdHz)
        maxQueueDepth = max(maxQueueDepth, sample.queueDepthMax)
        totalDropped += sample.dropped
        totalTimeouts += sample.timeouts
        for (kind, count) in sample.gaps {
            totalGaps[kind, default: 0] += count
        }
        lastBytesWritten = sample.bytesWritten
    }

    var summary: RecordingSummary.Stats? {
        guard rows > 0 else { return nil }
        return RecordingSummary.Stats(
            rows: rows,
            minMotionHz: motionHz.min() ?? 0,
            meanMotionHz: motionHz.reduce(0, +) / Double(rows),
            minObdHz: obdHz.min() ?? 0,
            meanObdHz: obdHz.reduce(0, +) / Double(rows),
            maxQueueDepth: maxQueueDepth,
            totalDropped: totalDropped,
            totalTimeouts: totalTimeouts,
            totalGaps: totalGaps,
            lastBytesWritten: lastBytesWritten
        )
    }
}

/// Everything `inspect_log` prints about one recording.
public struct RecordingSummary: Hashable, Sendable {
    public struct Kind: Hashable, Sendable {
        public var kind: String
        public var count: Int
        public var firstT: MonotonicTimestamp?
        public var lastT: MonotonicTimestamp?
        /// (count − 1) / (last − first): achieved rate. nil below two samples.
        public var rateHz: Double?
        /// Longest interval between consecutive samples in timestamp order.
        public var maxIntervalMs: Double?
        /// Intervals over 50 ms; only for `motion`, `accel`, `gyro`.
        public var gapsOver50ms: Int?
        /// Sum of those intervals.
        public var gapTotalMs: Double?
        /// Rows whose `t` is earlier than the previous row of the same kind,
        /// in file order. CoreMotion batches can cause a few; many means a
        /// stamping problem.
        public var outOfOrder: Int
    }

    /// Nearest-rank percentiles, in milliseconds.
    public struct Latency: Hashable, Sendable {
        public var count: Int
        public var minMs: Double
        public var p50Ms: Double
        public var p90Ms: Double
        public var p95Ms: Double
        public var p99Ms: Double
        public var maxMs: Double
        /// Values below zero — a reply stamped before its request, which is
        /// a clock bug.
        public var negative: Int

        public init?(milliseconds values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func rank(_ p: Double) -> Double {
                let index = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
                return sorted[min(max(index, 0), sorted.count - 1)]
            }
            count = sorted.count
            minMs = sorted[0]
            p50Ms = rank(50)
            p90Ms = rank(90)
            p95Ms = rank(95)
            p99Ms = rank(99)
            maxMs = sorted[sorted.count - 1]
            negative = sorted.filter { $0 < 0 }.count
        }
    }

    public struct Stats: Hashable, Sendable {
        public var rows: Int
        public var minMotionHz: Double
        public var meanMotionHz: Double
        public var minObdHz: Double
        public var meanObdHz: Double
        public var maxQueueDepth: Int
        public var totalDropped: Int
        public var totalTimeouts: Int
        public var totalGaps: [String: Int]
        public var lastBytesWritten: Int
    }

    public struct Marker: Hashable, Sendable {
        public var t: MonotonicTimestamp
        public var text: String

        public init(t: MonotonicTimestamp, text: String) {
            self.t = t
            self.text = text
        }
    }

    public var header: LogHeader
    public var report: LogReadReport
    public var eventCount: Int
    public var firstT: MonotonicTimestamp?
    public var lastT: MonotonicTimestamp?
    /// Known kinds in format order, then unknown kinds alphabetically.
    public var kinds: [Kind]
    /// `obd` latency `t − requestT`, one value per exchange (`seq`).
    public var obdLatency: Latency?
    public var elmOutcomes: [String: Int]
    /// Successful poll exchanges per second over the span they cover.
    public var pollExchangeHz: Double?
    public var lifecycle: [String: Int]
    /// `detail` of every `lifecycle` `error` row.
    public var errors: [String]
    public var markers: [Marker]
    /// Aggregate of the recorder's own `stats` rows.
    public var stats: Stats?

    /// Problems worth a look before trusting the drive. Empty for a clean
    /// recording.
    public var healthWarnings: [String] {
        var warnings: [String] = []
        if report.truncatedTail {
            warnings.append("file has a truncated or damaged tail (crash or power loss); the last few seconds are missing")
        }
        if !report.damagedMemberIndices.isEmpty {
            warnings.append("\(report.damagedMemberIndices.count) damaged gzip member(s) skipped: \(report.damagedMemberIndices)")
        }
        if !report.skippedLineIndices.isEmpty {
            warnings.append("\(report.skippedLineIndices.count) malformed line(s) skipped")
        }
        if let failure = report.failure {
            warnings.append("reading stopped early: \(failure)")
        }
        if let readError = report.readError {
            warnings.append("reading stopped at a read error; the rest of the file was not read: \(readError)")
        }
        if let stats {
            if stats.totalDropped > 0 {
                warnings.append("\(stats.totalDropped) event(s) dropped by the recorder")
            }
        } else if let firstT, let lastT, firstT.interval(to: lastT) > 30, header.formatVersion >= .v2 {
            warnings.append("no stats rows in a v2 recording longer than 30 s")
        }
        for kind in kinds {
            if let gaps = kind.gapsOver50ms, gaps > 0 {
                warnings.append("\(kind.kind): \(gaps) gap(s) over 50 ms, longest \(Self.format(kind.maxIntervalMs ?? 0, 1)) ms")
            }
            if kind.outOfOrder > 0, Double(kind.outOfOrder) > Double(kind.count) * 0.01 {
                warnings.append("\(kind.kind): \(kind.outOfOrder) out-of-order row(s)")
            }
        }
        if let latency = obdLatency, latency.negative > 0 {
            warnings.append("\(latency.negative) OBD reply(ies) stamped before their request")
        }
        if !errors.isEmpty {
            warnings.append("\(errors.count) lifecycle error row(s)")
        }
        return warnings
    }

    /// The human-readable report `inspect_log` prints.
    public func render() -> String {
        var out: [String] = []
        func row(_ label: String, _ value: String) {
            out.append("  " + label.padding(toLength: 14, withPad: " ", startingAt: 0) + value)
        }

        out.append("Header")
        row("format", "v\(header.formatVersion.rawValue)")
        row("session", header.sessionID.uuidString)
        row("started", header.startedAt.formatted(Date.ISO8601FormatStyle()) + (header.timeZone.map { " (\($0))" } ?? ""))
        row("app", "\(header.app.name) \(header.app.version) (\(header.app.build))")
        row("device", "\(header.device.model) \(header.device.systemName) \(header.device.systemVersion)")
        if let mount = header.mount { row("mount", mount) }
        if let vehicle = header.vehicle { row("vehicle", vehicle) }
        if let notes = header.notes { row("notes", notes) }
        if let adapter = header.adapter {
            var parts = [adapter.name.isEmpty ? "(unnamed)" : adapter.name]
            if let version = adapter.elmVersion { parts.append(version) }
            if let proto = adapter.protocolNumber { parts.append("protocol \(proto)") }
            if let volts = adapter.voltage { parts.append("\(Self.format(volts, 1)) V") }
            row("adapter", parts.joined(separator: ", "))
        } else {
            row("adapter", "none (recorded without OBD)")
        }
        if let polling = header.polling {
            var parts = ["\(polling.command)", "pids \(polling.pids)", polling.multiPID ? "multi-PID" : "rpm every \(polling.rpmEvery)"]
            parts.append("ATAT\(polling.adaptiveTiming)")
            parts.append("timeout \(polling.timeoutMs) ms")
            row("polling", parts.joined(separator: ", "))
        }
        if let sensors = header.sensors {
            row("sensors", "motion \(Self.format(sensors.deviceMotionHz, 0)) Hz, accel \(Self.format(sensors.accelerometerHz, 0)) Hz, gyro \(Self.format(sensors.gyroHz, 0)) Hz, mag \(Self.format(sensors.magnetometerHz, 0)) Hz, \(sensors.referenceFrame)\(sensors.altimeter ? ", altimeter" : "")")
        }

        out.append("")
        if let firstT, let lastT {
            out.append("Duration      \(Self.format(firstT.interval(to: lastT), 3)) s  (t \(Self.format(firstT.seconds, 3)) … \(Self.format(lastT.seconds, 3)) s)")
        }
        out.append("Events        \(eventCount)")
        out.append("")
        out.append("  kind        count     rate Hz  max gap ms  gaps>50ms  gap total ms  out-of-order")
        for kind in kinds {
            out.append(
                "  " + kind.kind.padding(toLength: 10, withPad: " ", startingAt: 0)
                    + Self.right(String(kind.count), 7)
                    + Self.right(kind.rateHz.map { Self.format($0, 2) } ?? "-", 12)
                    + Self.right(kind.maxIntervalMs.map { Self.format($0, 1) } ?? "-", 12)
                    + Self.right(kind.gapsOver50ms.map(String.init) ?? "", 11)
                    + Self.right(kind.gapTotalMs.map { Self.format($0, 1) } ?? "", 14)
                    + Self.right(String(kind.outOfOrder), 14)
            )
        }

        out.append("")
        if let latency = obdLatency {
            out.append("OBD latency   t − requestT per exchange, n = \(latency.count): min \(Self.format(latency.minMs, 1)), p50 \(Self.format(latency.p50Ms, 1)), p90 \(Self.format(latency.p90Ms, 1)), p95 \(Self.format(latency.p95Ms, 1)), p99 \(Self.format(latency.p99Ms, 1)), max \(Self.format(latency.maxMs, 1)) ms")
        } else {
            out.append("OBD latency   no obd rows with requestT")
        }
        if let pollExchangeHz {
            out.append("Poll rate     \(Self.format(pollExchangeHz, 2)) successful poll exchanges/s")
        }
        out.append("ELM outcomes  " + (elmOutcomes.isEmpty ? "none" : Self.counts(elmOutcomes, order: ELMOutcome.allCases.map(\.rawValue))))
        out.append("Lifecycle     " + (lifecycle.isEmpty ? "none" : Self.counts(lifecycle, order: LifecycleSample.Event.allCases.map(\.rawValue))))
        for error in errors.prefix(10) {
            out.append("  error: \(error)")
        }
        if !markers.isEmpty {
            out.append("Markers       " + markers.map { "\(Self.format($0.t.seconds, 1)) s \($0.text)" }.joined(separator: "; "))
        }
        if let stats {
            let gaps = Self.counts(stats.totalGaps, order: StatsAccumulator.gapKinds.map(\.rawValue))
            out.append("Stats rows    \(stats.rows): motionHz min \(Self.format(stats.minMotionHz, 1)) mean \(Self.format(stats.meanMotionHz, 1)); obdHz min \(Self.format(stats.minObdHz, 1)) mean \(Self.format(stats.meanObdHz, 1)); queue depth max \(stats.maxQueueDepth); dropped \(stats.totalDropped); timeouts \(stats.totalTimeouts); gaps \(gaps.isEmpty ? "none" : gaps); \(stats.lastBytesWritten) bytes")
        } else {
            out.append("Stats rows    none")
        }

        out.append("")
        let members = report.members == 0 ? "plain .jsonl" : "\(report.members) gzip members"
        out.append("Integrity     \(members); truncated tail: \(report.truncatedTail ? "yes" : "no"); damaged members: \(report.damagedMemberIndices.isEmpty ? "none" : "\(report.damagedMemberIndices)"); skipped lines: \(report.skippedLineIndices.isEmpty ? "none" : "\(report.skippedLineIndices.count)")" + (report.readError == nil ? "" : "; read error: yes"))
        let warnings = healthWarnings
        out.append("Health        " + (warnings.isEmpty ? "OK" : "\(warnings.count) warning(s)"))
        for warning in warnings {
            out.append("  WARN \(warning)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func format(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private static func right(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(1, width - text.count)) + text
    }

    private static func counts(_ values: [String: Int], order: [String]) -> String {
        let keys = order.filter { values[$0] != nil } + values.keys.filter { !order.contains($0) }.sorted()
        return keys.map { "\($0) \(values[$0]!)" }.joined(separator: ", ")
    }
}
