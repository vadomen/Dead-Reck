/// Builds the `stats` row written every 10 s.
///
/// Pure value type, fed every event the recorder writes, in write order. The
/// recorder supplies what only it knows — queue depth, drops, bytes on disk —
/// when closing a window.
///
/// Definitions (the `stats` row's fields):
/// - `counts`: events observed since the last close, by `kind` string
///   (unknown kinds included).
/// - `windowS`: from the previous close; for the first window, from the
///   first observed event's `t`. Zero if nothing was ever observed.
/// - `obdHz`: `elm` rows with phase `poll` and outcome `ok`, per second —
///   successful poll exchanges, however many `obd` rows (PIDs × ECUs) each
///   produced.
/// - `motionHz`: `motion` rows per second.
/// - `timeouts`: `elm` rows with outcome `timeout`, any phase.
/// - `gaps` / `maxGapMs`: for `motion`, `accel` and `gyro`, the intervals
///   between consecutive samples **in timestamp order**. The window's samples
///   are sorted together with the stream's latest sample from earlier
///   windows, so an interval spanning a window boundary is counted in the
///   window of its later sample, and a CoreMotion batch that arrives late
///   and fills a hole closes that hole instead of producing a phantom gap.
///   No interval is ever negative. `gaps` has a key for every gap kind
///   (0 when none); `maxGapMs` only for kinds with at least one interval in
///   the window. A stream that is silent for a whole window shows as a
///   missing `counts` key; its gap is counted when it resumes.
///   Limitation: a late sample that fills a hole already counted in an
///   earlier, closed window cannot uncount it.
public struct StatsAccumulator: Sendable {
    /// An interval longer than this between two samples of a 100 Hz stream
    /// counts as a gap.
    public static let gapThreshold = MonotonicTimestamp(nanoseconds: 50_000_000)

    /// Streams checked for gaps.
    public static let gapKinds: [LogEventKind] = [.motion, .accelerometer, .gyroscope]

    private var counts: [String: Int] = [:]
    private var pollOK = 0
    private var timeouts = 0
    private var windowStart: MonotonicTimestamp?
    /// This window's timestamps per gap kind (raw value), in arrival order.
    private var samples: [String: [Int64]] = [:]
    /// Latest timestamp per gap kind from closed windows.
    private var lastBefore: [String: Int64] = [:]

    public init() {}

    /// Counts one event. Out-of-order timestamps (CoreMotion batches) must not
    /// produce negative intervals or phantom gaps.
    public mutating func observe(_ event: LogEvent) {
        if windowStart == nil {
            windowStart = event.timestamp
        }
        let kind = event.payload.kind
        counts[kind, default: 0] += 1

        switch event.payload {
        case .motion, .accelerometer, .gyroscope:
            samples[kind, default: []].append(event.timestamp.nanoseconds)
        case .elm(let exchange):
            if exchange.outcome == ELMOutcome.timeout.rawValue {
                timeouts += 1
            } else if exchange.outcome == ELMOutcome.ok.rawValue, exchange.phase == ELMPhase.poll.rawValue {
                pollOK += 1
            }
        default:
            break
        }
    }

    /// Closes the current window and starts the next. The first window runs
    /// from the first observed event.
    public mutating func closeWindow(
        at end: MonotonicTimestamp,
        queueDepthMax: Int,
        dropped: Int,
        bytesWritten: Int
    ) -> StatsSample {
        let start = windowStart ?? end
        let windowS = max(0, start.interval(to: end))
        func perSecond(_ count: Int) -> Double {
            windowS > 0 ? Double(count) / windowS : 0
        }

        var gaps: [String: Int] = [:]
        var maxGapMs: [String: Double] = [:]
        for kind in Self.gapKinds.map(\.rawValue) {
            var times = samples[kind] ?? []
            if let previous = lastBefore[kind] {
                times.append(previous)
            }
            times.sort()
            var count = 0
            var longest: Int64?
            for (earlier, later) in zip(times, times.dropFirst()) {
                let interval = later - earlier
                if interval > Self.gapThreshold.nanoseconds { count += 1 }
                longest = max(longest ?? 0, interval)
            }
            gaps[kind] = count
            if let longest {
                maxGapMs[kind] = Double(longest) / 1_000_000
            }
            if let latest = times.last {
                lastBefore[kind] = latest
            }
        }

        let row = StatsSample(
            windowS: windowS,
            counts: counts,
            obdHz: perSecond(pollOK),
            motionHz: perSecond(counts[LogEventKind.motion.rawValue] ?? 0),
            gaps: gaps,
            maxGapMs: maxGapMs,
            timeouts: timeouts,
            queueDepthMax: queueDepthMax,
            dropped: dropped,
            bytesWritten: bytesWritten
        )

        counts = [:]
        pollOK = 0
        timeouts = 0
        samples = [:]
        windowStart = end
        return row
    }
}
