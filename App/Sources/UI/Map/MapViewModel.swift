import DriveLoggerCore
import Foundation
import Observation

/// State of the Map tab. Consumes the recorder's own reference fix
/// (`RecordingSession.live.referenceFix`); it owns no location manager and
/// writes nothing.
@MainActor
@Observable
final class MapViewModel {
    private(set) var track = GPSTrack()
    private(set) var latest: LocationSample?
    /// Follow state; lives here so it survives the tab's view being rebuilt.
    var follow = FollowController()
    /// Direction of travel for heading-up (display only); nil until a good one.
    private(set) var bearing: Double?
    /// OBD speed is exactly 0 km/h: heading-up holds still. Set only when it
    /// flips, so the 16 Hz status does not re-render the map.
    private(set) var isStationary = false
    /// The speed the info block shows and where it comes from (`MapSpeedRule`).
    /// Set only when it changes, so the 16 Hz status does not re-render the map.
    private(set) var speed = MapSpeedReadout.none
    private var obdInput: (kmh: Double?, ageS: Double?)?
    private let bearingSource: any MapBearingSource
    /// The recording the track belongs to.
    private(set) var currentFile: URL?

    /// When the latest fix arrived (stamped at ingest, not read from the
    /// recorder), for the stale-fix display.
    private(set) var lastFixInstant: ContinuousClock.Instant?
    /// False before the first fix of a recording and after Stop.
    private(set) var isReceiving = false
    /// Manual fixes staged in the current recording; cleared with the track.
    private(set) var manualFixes: [ConfirmedFix] = []

    init(bearingSource: (any MapBearingSource)? = nil) {
        self.bearingSource = bearingSource ?? GPSCourseBearingSource()
    }

    /// Preview/test seeding.
    init(
        track: GPSTrack, latest: LocationSample?, manualFixes: [ConfirmedFix] = [],
        bearingSource: (any MapBearingSource)? = nil
    ) {
        self.bearingSource = bearingSource ?? GPSCourseBearingSource()
        self.track = track
        self.latest = latest
        self.manualFixes = manualFixes
    }

    /// Takes the recorder's latest fix. When the scene is not active (locked
    /// screen) it only feeds the bearing source, for the recording already
    /// shown: a good course from a locked stretch would otherwise be lost and
    /// unlocking at a light would show the pre-lock heading (M10.1-2). Track,
    /// latest fix and staleness are untouched. A different `file` is a new recording and resets the track; a
    /// nil fix or nil file (after Stop) keeps what is shown until the next Start.
    ///
    /// `elapsed` is the recorder's session-clock time now; with it the fix's
    /// age comes from the fix's own time (`receivedT - ageS`), so an old fix
    /// ingested late (scene reactivation) already looks stale. Without it the
    /// fix is treated as arriving now.
    func ingest(_ fix: LocationSample?, file: URL?, isActive: Bool, elapsed: TimeInterval? = nil) {
        guard isActive else {
            if let fix, let file, file == currentFile {
                bearingSource.ingest(fix)
                if bearingSource.bearingDegrees != bearing { bearing = bearingSource.bearingDegrees }
            }
            return
        }
        if let file, file != currentFile {
            currentFile = file
            track = GPSTrack()
            latest = nil
            lastFixInstant = nil
            isReceiving = false
            manualFixes = []
            bearingSource.reset()
            bearing = nil
            refreshSpeed()
        }
        guard let fix else {
            isReceiving = false
            return
        }
        if fix != latest {
            latest = fix
            bearingSource.ingest(fix)
            if bearingSource.bearingDegrees != bearing { bearing = bearingSource.bearingDegrees }
            var age = 0.0
            if let elapsed, let received = fix.receivedT {
                age = max(0, elapsed - (received.seconds - (fix.ageS ?? 0)))
            }
            lastFixInstant = .now - .seconds(age)
            refreshSpeed()
        }
        isReceiving = true
        track.append(fix)
    }

    /// OBD speed from the feed (km/h, J1979 integer) with the uptime of its
    /// reply and the uptime now. Stationary only for a fresh 0 (see
    /// `StationaryRule`); nil or stale is unknown, not stationary. Publishes
    /// only when the stationary state flips.
    ///
    /// Also refreshes `speed`. The caller ticks twice a second, which is what
    /// ages an OBD reply or a fix out after `MapSpeedRule.maxOBDAgeS` / `maxGPSAgeS`.
    func setOBDSpeed(_ kmh: Double?, replyUptime: Double?, now: Double) {
        let stationary = StationaryRule.isStopped(kmh: kmh, replyUptime: replyUptime, now: now)
        if stationary != isStationary { isStationary = stationary }
        obdInput = (kmh, replyUptime.map { now - $0 })
        refreshSpeed()
    }

    /// Applies `MapSpeedRule` to the latest OBD input and fix. The fix's age
    /// is on the same instant clock the stale-fix display uses.
    private func refreshSpeed(instantNow: ContinuousClock.Instant = .now) {
        let fixAge = lastFixInstant.map { instant -> Double in
            let d = instant.duration(to: instantNow).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
        let next = MapSpeedRule.resolve(
            obdKmh: obdInput?.kmh, obdAgeS: obdInput?.ageS, fix: latest, fixAgeS: fixAge
        )
        if next != speed { speed = next }
    }

    /// Remembers a fix the recorder staged so the map can show it. `id` is the
    /// recorder's pending-fix id.
    func addManualFix(id: Int, latitude: Double, longitude: Double) {
        guard !manualFixes.contains(where: { $0.id == id }) else { return }
        manualFixes.append(ConfirmedFix(id: id, latitude: latitude, longitude: longitude))
    }

    /// What the map draws: never a fix the session dropped without writing it.
    func drawnManualFixes(excluding dropped: Set<Int>) -> [ConfirmedFix] {
        dropped.isEmpty ? manualFixes : manualFixes.filter { !dropped.contains($0.id) }
    }

    /// Undo: the fix is not drawn any more.
    func removeManualFix(id: Int) {
        manualFixes.removeAll { $0.id == id }
    }
}
