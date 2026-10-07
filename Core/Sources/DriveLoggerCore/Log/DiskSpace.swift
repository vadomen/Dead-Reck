import Foundation

// Free-space reporting for `LogFileWriter` (docs/PLAN.md §4.3). The provider
// is injectable so tests can drive the writer across both thresholds; the
// reporting rule (`DiskSpacePolicy`) is a pure value type tested on its own.

/// Reports free space on the volume holding a recording.
public protocol DiskSpaceProvider: Sendable {
    /// Bytes available for new data on the volume containing `url`. `url` may
    /// name a file that does not exist yet; implementations resolve it to its
    /// directory.
    func availableBytes(for url: URL) throws -> Int64
}

/// Free-space query failed: the volume reported neither capacity value.
public enum DiskSpaceError: Error, Hashable, Sendable {
    case capacityUnavailable(path: String)
}

/// Production provider backed by `URLResourceValues`.
///
/// **The reading is the smaller of `volumeAvailableCapacityForImportantUsage`
/// and `volumeAvailableCapacity`** (either alone when the volume reports only
/// one). Important-usage capacity counts purgeable space — caches iOS can
/// delete for an important write — but iOS purges asynchronously, so a write
/// can fail with `ENOSPC` while that figure still reads far above the floor
/// (on the development Mac it read ~32 GB above plain capacity; review
/// finding R2-8). The thresholds exist to leave room for a clean stop *now*,
/// and only plain free space is there now. The cost is conservatism: on a
/// phone whose free space is mostly purgeable, the warning, the floor and the
/// start refusal (`DiskSpacePolicy.canStart`) trigger earlier than iOS would
/// strictly require. A clean stop with an intact file beats a write failure,
/// so that is the side to err on. To verify on a nearly full iPhone (M4).
///
/// **Every call reads through a freshly built `URL`, never the caller's.**
/// Foundation caches resource values on a `URL` instance and only discards
/// them on the next turn of the run loop. `LogFileWriter` holds one recording
/// URL for the whole drive and queries free space from an actor running on
/// the cooperative thread pool, where no run loop ever turns — so reading
/// through the caller's URL returns the start-of-drive value on every later
/// flush and no `DiskSpaceNotice` ever fires (review finding R2-1, guarded by
/// `VolumeDiskSpaceProviderFreshnessTests`). A new
/// `URL(fileURLWithPath:)` carries no cache; clearing it as well is belt and
/// braces in case Foundation ever shares cache storage between equal URLs.
public struct VolumeDiskSpaceProvider: DiskSpaceProvider {
    public init() {}

    public func availableBytes(for url: URL) throws -> Int64 {
        // Fresh instance per call, built from the path alone: see the type's
        // doc comment. `deletingLastPathComponent()` also returns a new,
        // cache-free instance.
        let fresh = URL(fileURLWithPath: url.path)
        var target = FileManager.default.fileExists(atPath: fresh.path)
            ? fresh
            : fresh.deletingLastPathComponent()
        target.removeAllCachedResourceValues()
        let values = try target.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        guard let reading = Self.reading(
            important: values.volumeAvailableCapacityForImportantUsage,
            plain: values.volumeAvailableCapacity
        ) else {
            throw DiskSpaceError.capacityUnavailable(path: target.path)
        }
        return reading
    }

    /// The combining rule: the smaller of the two readings, or whichever the
    /// volume reported. See the type's doc comment for why.
    static func reading(important: Int64?, plain: Int?) -> Int64? {
        switch (important, plain.map(Int64.init)) {
        case let (important?, plain?): min(important, plain)
        case let (important?, nil): important
        case let (nil, plain?): plain
        case (nil, nil): nil
        }
    }
}

/// An advisory free-space signal from `LogFileWriter`. **Not a write
/// failure**: it never blocks, delays or fails a write, and it travels on
/// `LogFileWriter.diskSpaceNotices`, never on `failures`. What the recorder
/// does with it is `RecordingSession`'s policy ("warn, then stop at a floor").
public enum DiskSpaceNotice: Hashable, Sendable {
    /// Free space fell strictly below the warning threshold
    /// (`warningFreeBytes`, default 200 MB). The recording continues.
    case low(availableBytes: Int64)
    /// Free space fell strictly below the stop floor (`stopFreeBytes`,
    /// default 50 MB). The recording is stopped cleanly while there is still
    /// room for its final rows.
    case critical(availableBytes: Int64)
}

/// Turns free-space readings into `DiskSpaceNotice`s, as `LogFileWriter`
/// applies it to every reading. Pure and fully tested in Core.
///
/// Two independent `LowDiskSpaceMonitor`s, one per threshold, each
/// edge-triggered with its own hysteresis:
///
/// - The **warning** monitor (`warningFreeBytes`) yields `.low` once per
///   crossing.
/// - The **floor** monitor (`stopFreeBytes`) yields `.critical` once per
///   crossing.
/// - "Below" is strict for both: a reading exactly at a threshold is not
///   below it.
/// - A single reading that drops straight below both thresholds yields
///   `[.low, .critical]`, in that order, so the warning row always precedes
///   the floor row in a recording.
/// - Each monitor re-arms only on a reading strictly above its own threshold
///   plus `hysteresisBytes`; re-arming one says nothing about the other.
///   Re-arming is silent: recovery produces no notice.
///
/// `canStart(availableBytes:warningFreeBytes:)` is the matching start rule:
/// a recording may start only at or above the warning threshold, so a new
/// drive never begins in the warning band.
public struct DiskSpacePolicy: Hashable, Sendable {
    /// 200 MB: several minutes of recording at the highest rates, enough to
    /// notice the warning and free space before the floor is reached.
    public static let defaultWarningFreeBytes: Int64 = 200_000_000
    /// 50 MB: far more than the final member, `stop` row and `stats` row
    /// need (kilobytes), with margin for whatever else on the phone is
    /// writing at the same time.
    public static let defaultStopFreeBytes: Int64 = 50_000_000

    public var warningFreeBytes: Int64 { warning.thresholdBytes }
    public var stopFreeBytes: Int64 { floor.thresholdBytes }
    /// `true` while the warning monitor is disarmed (`.low` reported, not yet
    /// re-armed).
    public var isLow: Bool { warning.isBelow }
    /// `true` while the floor monitor is disarmed (`.critical` reported, not
    /// yet re-armed).
    public var isCritical: Bool { floor.isBelow }

    private var warning: LowDiskSpaceMonitor
    private var floor: LowDiskSpaceMonitor

    /// - Precondition: `stopFreeBytes < warningFreeBytes` (a floor at or
    ///   above the warning threshold would stop a recording without ever
    ///   warning), and `hysteresisBytes >= 0`.
    public init(
        warningFreeBytes: Int64 = defaultWarningFreeBytes,
        stopFreeBytes: Int64 = defaultStopFreeBytes,
        hysteresisBytes: Int64 = LowDiskSpaceMonitor.defaultHysteresisBytes
    ) {
        precondition(
            stopFreeBytes < warningFreeBytes,
            "stopFreeBytes (\(stopFreeBytes)) must be below warningFreeBytes (\(warningFreeBytes))"
        )
        self.warning = LowDiskSpaceMonitor(thresholdBytes: warningFreeBytes, hysteresisBytes: hysteresisBytes)
        self.floor = LowDiskSpaceMonitor(thresholdBytes: stopFreeBytes, hysteresisBytes: hysteresisBytes)
    }

    /// Feeds one free-space reading to both monitors. Returns the notices it
    /// triggers, warning first: `[]`, `[.low]`, `[.critical]` or
    /// `[.low, .critical]`. Each carries this reading.
    public mutating func observe(availableBytes: Int64) -> [DiskSpaceNotice] {
        var notices: [DiskSpaceNotice] = []
        if warning.observe(availableBytes: availableBytes) {
            notices.append(.low(availableBytes: availableBytes))
        }
        if floor.observe(availableBytes: availableBytes) {
            notices.append(.critical(availableBytes: availableBytes))
        }
        return notices
    }

    /// The start rule: `true` at or above `warningFreeBytes`, `false`
    /// strictly below it — the same strict "below" as the warning monitor, so
    /// any reading that can start a recording would not trigger `.low`.
    public static func canStart(
        availableBytes: Int64,
        warningFreeBytes: Int64 = defaultWarningFreeBytes
    ) -> Bool {
        availableBytes >= warningFreeBytes
    }
}

/// One edge-triggered threshold with hysteresis. `DiskSpacePolicy` runs one
/// for the warning threshold and one for the stop floor.
///
/// Edge-triggered, so a reading that changes on every flush does not produce
/// a report on every flush:
///
/// - **Armed** (the initial state): a reading strictly below `thresholdBytes`
///   returns `true` (a crossing) and disarms. A reading exactly at
///   `thresholdBytes` is not below. Starting already below the threshold
///   therefore reports on the first observation.
/// - **Disarmed**: every reading returns `false`, however it changes. The
///   monitor re-arms only on a reading strictly above
///   `thresholdBytes + hysteresisBytes` (exactly at that sum stays
///   disarmed). After re-arming, the next reading below the threshold reports
///   again.
public struct LowDiskSpaceMonitor: Hashable, Sendable {
    /// 50 MB: about two orders of magnitude above what a 2 s flush adds
    /// (tens of kilobytes compressed), so ordinary jitter in the volume's free
    /// space — caches purged and refilled, other apps writing — can't re-arm
    /// the monitor, while deleting a recording or an app clearly does.
    public static let defaultHysteresisBytes: Int64 = 50_000_000

    public let thresholdBytes: Int64
    public let hysteresisBytes: Int64
    /// `true` once a crossing has been reported and the monitor has not yet
    /// re-armed.
    public private(set) var isBelow: Bool = false

    /// `thresholdBytes + hysteresisBytes`, saturating at `Int64.max`.
    private let rearmAboveBytes: Int64

    /// - Precondition: `hysteresisBytes >= 0`.
    public init(thresholdBytes: Int64, hysteresisBytes: Int64 = defaultHysteresisBytes) {
        precondition(hysteresisBytes >= 0, "hysteresisBytes must not be negative")
        self.thresholdBytes = thresholdBytes
        self.hysteresisBytes = hysteresisBytes
        let (sum, overflow) = thresholdBytes.addingReportingOverflow(hysteresisBytes)
        self.rearmAboveBytes = overflow ? .max : sum
    }

    /// Feeds one free-space reading. Returns `true` only on a crossing as
    /// defined on the type.
    public mutating func observe(availableBytes: Int64) -> Bool {
        if isBelow {
            if availableBytes > rearmAboveBytes {
                isBelow = false
            }
            return false
        }
        guard availableBytes < thresholdBytes else { return false }
        isBelow = true
        return true
    }
}
