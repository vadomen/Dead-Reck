import DriveLoggerCore
import Foundation

/// Whether Location is refused, as the map needs it (prompt 43, R-QA42-1).
/// Derived from the sources' own `availability` (the same reasons the Record
/// screen shows), so nothing new is asked of CoreLocation. Motion & Fitness is
/// not here (R81.1-1): it gates only the altimeter, which navigation never
/// reads. The simulator's simulated sources are always available.
struct SensorAccess: Equatable, Sendable {
    var locationDenied = false

    var isGranted: Bool { !locationDenied }

    static func from(_ availabilities: [SensorAvailability]) -> SensorAccess {
        var out = SensorAccess()
        for case .unavailable(let reason) in availabilities {
            switch reason {
            case SensorUnavailableReason.locationDenied.rawValue, SensorUnavailableReason.locationRestricted.rawValue:
                out.locationDenied = true
            default: break
            }
        }
        return out
    }
}
