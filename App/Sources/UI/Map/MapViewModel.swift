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
    /// Manual fixes accepted in the current recording; cleared with the track.
    private(set) var manualFixes: [ConfirmedFix] = []
    private var nextFixID = 0

    init() {}

    /// Preview/test seeding.
    init(track: GPSTrack, latest: LocationSample?, manualFixes: [ConfirmedFix] = []) {
        self.track = track
        self.latest = latest
        self.manualFixes = manualFixes
        nextFixID = manualFixes.count
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
            manualFixes = []
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

    /// Remembers a fix the recorder accepted so the map can show it.
    func addManualFix(latitude: Double, longitude: Double, note: String?) {
        manualFixes.append(ConfirmedFix(
            id: nextFixID, latitude: latitude, longitude: longitude,
            note: ManualFixSample.normalizedNote(note)
        ))
        nextFixID += 1
    }
}
