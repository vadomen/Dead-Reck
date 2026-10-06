/// Builds the `stats` row written every 10 s.
///
/// Pure value type, fed every event the recorder writes. The recorder supplies
/// what only it knows — queue depth, drops, bytes on disk — when closing a
/// window.
public struct StatsAccumulator: Sendable {
    /// An interval longer than this between two samples of a 100 Hz stream
    /// counts as a gap.
    public static let gapThreshold = MonotonicTimestamp(nanoseconds: 50_000_000)

    /// Streams checked for gaps.
    public static let gapKinds: [LogEventKind] = [.motion, .accelerometer, .gyroscope]

    public init() {}

    /// Counts one event. Out-of-order timestamps (CoreMotion batches) must not
    /// produce negative intervals or phantom gaps.
    public mutating func observe(_ event: LogEvent) {
        fatalError("M1: StatsAccumulator.observe")
    }

    /// Closes the current window and starts the next. The first window runs
    /// from the first observed event.
    public mutating func closeWindow(
        at end: MonotonicTimestamp,
        queueDepthMax: Int,
        dropped: Int,
        bytesWritten: Int
    ) -> StatsSample {
        fatalError("M1: StatsAccumulator.closeWindow")
    }
}
