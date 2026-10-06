import CoreLocation
import DriveLoggerCore
import Foundation

/// Reference GNSS → `location`. Ground truth for later evaluation, never an
/// input to anything.
///
/// Best accuracy, no distance filter, `allowsBackgroundLocationUpdates`, no
/// automatic pausing, and a `CLBackgroundActivitySession` held while
/// recording so the app keeps running with the screen locked.
///
/// Time: `CLLocation.timestamp` is wall clock. At receipt the source takes
/// `receivedT = clock.now()` and `ageS = Date().timeIntervalSince(fix.timestamp)`
/// together and stamps the event at `receivedT - ageS` — the approved
/// exception to "no `Date()` per sample" (docs/PLAN.md §3.4). Raw `fixTime` is
/// kept so the conversion can be redone offline. Implemented in M2.
@MainActor
final class LocationSource: SensorSource {
    let name = "location"

    init() {}

    var availability: SensorAvailability {
        fatalError("M2: LocationSource.availability")
    }

    func start(clock: SessionClock, sink: LogSink) throws {
        fatalError("M2: LocationSource.start")
    }

    func stop() {
        fatalError("M2: LocationSource.stop")
    }
}
