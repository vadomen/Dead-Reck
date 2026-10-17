import DriveLoggerCore
import Foundation
import Observation

/// The map's view of live dead reckoning (N4 C). Main-actor; it owns no
/// engine. The map's 100 ms loop calls `poll` while the map is visible and
/// the scene is active; each poll asks `NavigationService` for the newest
/// snapshot.
///
/// Two copies of the estimate, on purpose:
/// - `latest`: every poll, not observed. The follow camera reads it from the
///   loop, so the camera can follow at 10 Hz without re-rendering anything.
/// - `display`: written through `NavWriteGate` (position change, heading
///   change above 2 degrees, at most every 0.25 s) and observed. Only the
///   small dead-reckoning map content and label views read it, so the
///   reference-GPS polylines are not rebuilt when it changes.
@MainActor
@Observable
final class NavigationFeed {
    typealias Source = @Sendable () async -> NavigationSnapshot

    /// Statistics are re-published at most this often.
    static let statsInterval: Duration = .seconds(1)

    private(set) var display: NavDisplay?
    private(set) var stats: NavStatsDisplay?

    @ObservationIgnored private(set) var latest: NavDisplay?
    @ObservationIgnored private let source: Source?
    @ObservationIgnored private var gate = NavWriteGate()
    @ObservationIgnored private var lastStatsWrite: ContinuousClock.Instant?

    init(source: @escaping Source) {
        self.source = source
    }

    /// Previews and tests: fixed values, no service behind them unless a
    /// `source` is given (a test of the first poll after seeded values).
    init(display: NavDisplay?, stats: NavStatsDisplay? = nil, source: Source? = nil) {
        self.source = source
        self.display = display
        self.latest = display
        self.stats = stats
    }

    /// Reads the newest snapshot. True when `display` was written (the
    /// estimate moved or turned enough): the caller may write the camera.
    @discardableResult
    func poll(at now: ContinuousClock.Instant = .now) async -> Bool {
        guard let source else { return false }
        let snapshot = await source()
        guard !Task.isCancelled else { return false }
        return apply(snapshot, at: now)
    }

    /// Polls once and returns the estimate as of now, for framing the camera
    /// when the map opens (R14.1-3). `latest` is written only while the loop
    /// polls, so without this a Stop (or a later recording) that happened while
    /// the map was away would be framed on the old estimate. nil without a
    /// recording or an estimate. After a cancelled poll `latest` is unchanged:
    /// the caller must check its own cancellation.
    func refreshed(at now: ContinuousClock.Instant = .now) async -> NavDisplay? {
        await poll(at: now)
        return latest
    }

    /// Applies one snapshot (split from `poll` so tests need no service).
    func apply(_ snapshot: NavigationSnapshot, at now: ContinuousClock.Instant) -> Bool {
        let next = NavDisplay(snapshot)
        latest = next
        writeStats(snapshot, at: now)
        guard gate.admit(next, at: now) else { return false }
        display = next
        return true
    }

    private func writeStats(_ snapshot: NavigationSnapshot, at now: ContinuousClock.Instant) {
        guard snapshot.sessionID != nil else {
            if stats != nil { stats = nil }
            lastStatsWrite = nil
            return
        }
        if let lastStatsWrite, now - lastStatsWrite < Self.statsInterval { return }
        lastStatsWrite = now
        let next = NavStatsDisplay(snapshot.stats)
        if next != stats { stats = next }
    }
}
