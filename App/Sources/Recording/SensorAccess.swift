import DriveLoggerCore
import Foundation

/// Which sensor permissions are refused, as the map needs them (prompt 43,
/// R-QA42-1). Derived from the sources' own `availability` (the same reasons
/// the Record screen shows), so nothing new is asked of CoreMotion or
/// CoreLocation. On a phone the Motion & Fitness answer comes from the
/// altimeter source (the only one that reads `CMAltimeter.authorizationStatus`),
/// the Location answer from the reference location source; the simulator's
/// simulated sources are always available.
struct SensorAccess: Equatable, Sendable {
    var motionDenied = false
    var locationDenied = false

    var isGranted: Bool { !motionDenied && !locationDenied }

    static func from(_ availabilities: [SensorAvailability]) -> SensorAccess {
        var out = SensorAccess()
        for case .unavailable(let reason) in availabilities {
            switch reason {
            case SensorUnavailableReason.motionDenied.rawValue, SensorUnavailableReason.motionRestricted.rawValue:
                out.motionDenied = true
            case SensorUnavailableReason.locationDenied.rawValue, SensorUnavailableReason.locationRestricted.rawValue:
                out.locationDenied = true
            default: break
            }
        }
        return out
    }
}
