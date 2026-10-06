import Foundation

// Free-space reporting for `LogFileWriter` (docs/PLAN.md §4.3). The provider
// is injectable so tests can drive the writer across the threshold; the
// reporting rule is a pure value type so it is tested on its own.

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
/// Uses `volumeAvailableCapacityForImportantUsage` — what iOS will actually
/// let the app write, counting purgeable space the system frees on demand —
/// and falls back to `volumeAvailableCapacity` when the volume doesn't report
/// it.
public struct VolumeDiskSpaceProvider: DiskSpaceProvider {
    public init() {}

    public func availableBytes(for url: URL) throws -> Int64 {
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url
            : url.deletingLastPathComponent()
        let values = try target.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let plain = values.volumeAvailableCapacity {
            return Int64(plain)
        }
        throw DiskSpaceError.capacityUnavailable(path: target.path)
    }
}

/// The `.lowDiskSpace` reporting rule, as `LogFileWriter` applies it to each
/// free-space reading.
///
/// Edge-triggered with hysteresis, so a reading that changes on every flush
/// does not produce a report on every flush:
///
/// - **Armed** (the initial state): a reading strictly below
///   `minimumFreeBytes` returns `.lowDiskSpace(availableBytes:)` with that
///   reading and disarms. A reading exactly at `minimumFreeBytes` is not low.
///   Starting already below the threshold therefore reports on the first
///   observation.
/// - **Disarmed**: every reading returns `nil`, however it changes. The
///   monitor re-arms only on a reading strictly above
///   `minimumFreeBytes + hysteresisBytes` (exactly at that sum stays
///   disarmed). After re-arming, the next reading below the threshold reports
///   again.
///
/// The report is advisory; see `LogFileWriter` for what it does (and does
/// not do) to writing.
public struct LowDiskSpaceMonitor: Hashable, Sendable {
    /// 50 MB: about two orders of magnitude above what a 2 s flush adds
    /// (tens of kilobytes compressed), so ordinary jitter in the volume's free
    /// space — caches purged and refilled, other apps writing — can't re-arm
    /// the monitor, while deleting a recording or an app clearly does.
    public static let defaultHysteresisBytes: Int64 = 50_000_000

    public let minimumFreeBytes: Int64
    public let hysteresisBytes: Int64
    /// `true` once a crossing has been reported and the monitor has not yet
    /// re-armed.
    public private(set) var isLow: Bool = false

    /// `minimumFreeBytes + hysteresisBytes`, saturating at `Int64.max`.
    private let rearmAboveBytes: Int64

    /// - Precondition: `hysteresisBytes >= 0`.
    public init(minimumFreeBytes: Int64, hysteresisBytes: Int64 = defaultHysteresisBytes) {
        precondition(hysteresisBytes >= 0, "hysteresisBytes must not be negative")
        self.minimumFreeBytes = minimumFreeBytes
        self.hysteresisBytes = hysteresisBytes
        let (sum, overflow) = minimumFreeBytes.addingReportingOverflow(hysteresisBytes)
        self.rearmAboveBytes = overflow ? .max : sum
    }

    /// Feeds one free-space reading. Returns `.lowDiskSpace(availableBytes:)`
    /// only on a crossing as defined on the type, otherwise `nil`.
    public mutating func observe(availableBytes: Int64) -> LogWriteError? {
        if isLow {
            if availableBytes > rearmAboveBytes {
                isLow = false
            }
            return nil
        }
        guard availableBytes < minimumFreeBytes else { return nil }
        isLow = true
        return .lowDiskSpace(availableBytes: availableBytes)
    }
}
