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
    /// The matched OSM edge's shape for the roads debug drawing; empty
    /// without roads. Rewritten only when the matched edge changes (the
    /// service rebuilds the geometry on a change only), not per poll.
    private(set) var matchedEdge: [GeoPoint] = []

    /// The engine's GPS state (UX-22) while a session is navigating, else nil.
    /// Observed, written only when it changes (a few times per drive), so the
    /// HUD follows it without the 10 Hz `display` writes.
    private(set) var gps: EngineGPS?

    /// The restored estimate's status (UX-20) while a session is navigating
    /// from one, else nil (no run, or a run started fresh: status `.none`).
    /// Observed, written only when it changes (start, then the decision), so
    /// the map's "Restored · n min ago" line follows it without the 10 Hz
    /// `display` writes.
    private(set) var restore: RestoreDisplay?

    @ObservationIgnored private(set) var latest: NavDisplay?
    @ObservationIgnored private let source: Source?
    /// The generation the source's snapshots follow (the service's current
    /// run). Read before and after each snapshot: a poll across a run change
    /// is dropped, so `gps` is never tagged with the wrong run (R76.2-1).
    @ObservationIgnored private let generation: (@Sendable () async -> Int?)?
    @ObservationIgnored private var gate = NavWriteGate()
    @ObservationIgnored private var edgeKey: EdgeKey?
    @ObservationIgnored private var lastStatsWrite: ContinuousClock.Instant?

    init(source: @escaping Source, generation: (@Sendable () async -> Int?)? = nil) {
        self.source = source
        self.generation = generation
    }

    /// Previews and tests: fixed values, no service behind them unless a
    /// `source` is given (a test of the first poll after seeded values).
    init(
        display: NavDisplay?, stats: NavStatsDisplay? = nil, matchedEdge: [GeoPoint] = [], gps: EngineGPS? = nil,
        restore: RestoreDisplay? = nil, source: Source? = nil
    ) {
        self.source = source
        self.generation = nil
        self.gps = gps
        self.restore = restore
        self.matchedEdge = matchedEdge
        self.display = display
        self.latest = display
        self.stats = stats
    }

    /// Reads the newest snapshot. True when `display` was written (the
    /// estimate moved or turned enough): the caller may write the camera.
    @discardableResult
    func poll(at now: ContinuousClock.Instant = .now) async -> Bool {
        guard let source else { return false }
        let before = await generation?()
        let snapshot = await source()
        let after = await generation?()
        guard !Task.isCancelled, before == after else { return false }
        return apply(snapshot, run: after, at: now)
    }

    /// Forgets the engine's GPS state and the restore status (UX-20): the
    /// map's run changed, and the next state must come from the new run's
    /// own snapshots (R76.2-1).
    func clearGPS() {
        if gps != nil { gps = nil }
        if restore != nil { restore = nil }
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
    /// `run` is the generation the snapshot belongs to (nil: untagged, the demo's feed).
    func apply(_ snapshot: NavigationSnapshot, run: Int? = nil, at now: ContinuousClock.Instant) -> Bool {
        let nextGPS = snapshot.sessionID == nil
            ? nil : EngineGPS(inUse: snapshot.gnssInUse, switchedOff: snapshot.gpsSwitchedOff, run: run)
        if nextGPS != gps { gps = nextGPS }
        let nextRestore = snapshot.sessionID == nil ? nil : RestoreDisplay(snapshot.restore, run: run)
        if nextRestore != restore { restore = nextRestore }
        let next = NavDisplay(snapshot)
        latest = next
        writeStats(snapshot, at: now)
        writeEdge(snapshot)
        guard gate.admit(next, at: now) else { return false }
        display = next
        return true
    }

    private struct EdgeKey: Equatable {
        var edge: MatchedRoadEdge
        var roadSetHash: UInt64
    }

    private func writeEdge(_ snapshot: NavigationSnapshot) {
        let key = snapshot.matchedEdgeGeometry.map { EdgeKey(edge: $0.edge, roadSetHash: $0.roadSetHash) }
        guard key != edgeKey else { return }
        edgeKey = key
        matchedEdge = snapshot.matchedEdgeGeometry?.points.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
        } ?? []
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

/// What the engine says about GPS (`NavigationSnapshot.gnssInUse`,
/// `gpsSwitchedOff`), for the HUD.
struct EngineGPS: Hashable, Sendable {
    /// A fix with a valid speed was used in the last 5 s (network-only fixes never count).
    var inUse: Bool
    /// The engine has the driver's switch off. Lags the tap by the tap buffer.
    var switchedOff: Bool
    /// The run generation this state came from (R76.2-1); nil when the feed
    /// is untagged. The HUD ignores a state from any other run than the live one.
    var run: Int? = nil
}

/// What the engine says about a restored estimate (UX-20,
/// `NavigationSnapshot.restore`), for the map's "Restored · n min ago"
/// line. Constant over a run but for the one decision, so `NavigationFeed`
/// writes it a few times per run at most.
struct RestoreDisplay: Hashable, Sendable {
    /// `.unconfirmed` (seeded, no fix or pin has decided yet), `.confirmed`
    /// or `.rejected` (a fix or pin disagreed: the engine started over).
    var status: NavigationRestore.Status
    /// What confirmed or rejected it; nil while unconfirmed.
    var reason: NavigationRestore.Reason?
    /// How old the saved estimate was when the run started, seconds
    /// ("n min ago" is this over 60).
    var ageAtStartS: Double
    /// When it was confirmed or rejected, seconds on the run's clock; nil
    /// while unconfirmed.
    var decidedAtS: Double?
    /// The run generation this came from (as `EngineGPS.run`); nil untagged.
    var run: Int? = nil

    /// nil without a restore (`.none`: no saved estimate, refused, or too
    /// uncertain to use).
    init?(_ restore: NavigationRestore, run: Int? = nil) {
        guard restore.status != .none, let savedT = restore.savedT else { return nil }
        status = restore.status
        reason = restore.reason
        ageAtStartS = -savedT.seconds
        decidedAtS = restore.decidedT?.seconds
        self.run = run
    }

    init(status: NavigationRestore.Status, reason: NavigationRestore.Reason? = nil, ageAtStartS: Double,
         decidedAtS: Double? = nil, run: Int? = nil) {
        self.status = status
        self.reason = reason
        self.ageAtStartS = ageAtStartS
        self.decidedAtS = decidedAtS
        self.run = run
    }
}
