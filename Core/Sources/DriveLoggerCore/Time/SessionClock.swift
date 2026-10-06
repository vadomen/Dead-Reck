import Foundation

/// Source of the monotonic time base a recording is stamped against.
///
/// `uptimeSeconds` must come from the same timebase CoreMotion uses for
/// `CMLogItem.timestamp` — seconds since boot, not advancing while the device is
/// fully suspended. CoreMotion is the highest-rate stream in a recording and the
/// only one that hands us pre-dated samples, so its clock is the one everything
/// else converts *into*, rather than the reverse.
public protocol UptimeSource: Sendable {
    var uptimeSeconds: Double { get }
}

/// Production source: `ProcessInfo.systemUptime`, which shares CoreMotion's
/// timebase.
public struct SystemUptimeSource: UptimeSource {
    public init() {}

    public var uptimeSeconds: Double {
        ProcessInfo.processInfo.systemUptime
    }
}

/// Fixed source, for tests, previews and replaying an already-recorded session.
public struct FixedUptimeSource: UptimeSource {
    public let uptimeSeconds: Double

    public init(uptimeSeconds: Double) {
        self.uptimeSeconds = uptimeSeconds
    }
}

/// The one clock a recording session stamps every sample with.
///
/// Construct exactly one per recording and pass it to every sensor adapter.
/// Wall-clock time is captured once, here, and written to the log header; it is
/// never consulted per sample.
public struct SessionClock: Sendable {
    /// Uptime reading at the instant the session started. Written to the log
    /// header so a recording can be re-aligned with other uptime-based data.
    public let referenceUptimeSeconds: Double

    /// Wall clock at session start. The only wall-clock value in a recording.
    public let wallClockStart: Date

    private let source: any UptimeSource

    public init(source: any UptimeSource = SystemUptimeSource(), wallClockStart: Date = Date()) {
        self.source = source
        self.referenceUptimeSeconds = source.uptimeSeconds
        self.wallClockStart = wallClockStart
    }

    /// Rebuilds the clock of an already-recorded session from its log header,
    /// so offline analysis resolves timestamps exactly as the recorder did.
    public init(
        referenceUptimeSeconds: Double,
        wallClockStart: Date,
        source: any UptimeSource = SystemUptimeSource()
    ) {
        self.referenceUptimeSeconds = referenceUptimeSeconds
        self.wallClockStart = wallClockStart
        self.source = source
    }

    public init(header: LogHeader, source: any UptimeSource = SystemUptimeSource()) {
        self.init(
            referenceUptimeSeconds: header.referenceUptimeSeconds,
            wallClockStart: header.startedAt,
            source: source
        )
    }

    /// Converts a sensor-supplied uptime (e.g. `CMLogItem.timestamp`) into a
    /// session timestamp.
    public func timestamp(uptimeSeconds: Double) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: uptimeSeconds - referenceUptimeSeconds)
    }

    /// Timestamp for an event observed right now — for streams that don't carry
    /// their own uptime, such as an OBD reply arriving over Bluetooth.
    public func now() -> MonotonicTimestamp {
        timestamp(uptimeSeconds: source.uptimeSeconds)
    }

    /// Wall-clock estimate for a sample. For display and export only: it
    /// inherits every drift and jump the wall clock suffered during the drive,
    /// so never use it for timing maths between samples.
    public func wallClock(for timestamp: MonotonicTimestamp) -> Date {
        wallClockStart.addingTimeInterval(timestamp.seconds)
    }
}
