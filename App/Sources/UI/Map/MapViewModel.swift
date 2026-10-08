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
    var followsUser = true
    /// The recording the track belongs to.
    private(set) var currentFile: URL?

    /// When the latest fix arrived (stamped at ingest, not read from the
    /// recorder), for the stale-fix display.
    private(set) var lastFixInstant: ContinuousClock.Instant?
    /// False before the first fix of a recording and after Stop.
    private(set) var isReceiving = false

    init() {}

    /// Preview/test seeding.
    init(track: GPSTrack, latest: LocationSample?) {
        self.track = track
        self.latest = latest
    }

    /// Takes the recorder's latest fix. Does nothing when the scene is not
    /// active. A different `file` is a new recording and resets the track; a
    /// nil fix or nil file (after Stop) keeps what is shown until the next Start.
    ///
    /// `elapsed` is the recorder's session-clock time now; with it the fix's
    /// age comes from the fix's own time (`receivedT - ageS`), so an old fix
    /// ingested late (scene reactivation) already looks stale. Without it the
    /// fix is treated as arriving now.
    func ingest(_ fix: LocationSample?, file: URL?, isActive: Bool, elapsed: TimeInterval? = nil) {
        guard isActive else { return }
        if let file, file != currentFile {
            currentFile = file
            track = GPSTrack()
            latest = nil
            lastFixInstant = nil
            isReceiving = false
        }
        guard let fix else {
            isReceiving = false
            return
        }
        if fix != latest {
            latest = fix
            var age = 0.0
            if let elapsed, let received = fix.receivedT {
                age = max(0, elapsed - (received.seconds - (fix.ageS ?? 0)))
            }
            lastFixInstant = .now - .seconds(age)
        }
        isReceiving = true
        track.append(fix)
    }
}
