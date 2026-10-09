import CoreLocation
import Foundation

/// The system's last known position, for placing the map camera before a
/// recording has any fix. Display only: never written to a log and never an
/// input. It can be minutes or days old.
struct CachedLocation: Hashable, Sendable {
    /// Degrees, WGS 84.
    var latitude: Double
    /// Degrees, WGS 84.
    var longitude: Double
    /// Metres, always ≥ 0 (an invalid position is never returned).
    var horizontalAccuracy: Double
}

/// A source that can report the system's cached position without starting
/// anything: no authorisation request, no location updates. On a phone,
/// `ReferenceLocationSource`. The simulated sources do not conform. The UI
/// finds it in `AppServices.sensors.sources`.
@MainActor
protocol CachedLocationProviding: AnyObject {
    /// nil when location is not authorised, nothing is cached, or the
    /// cached position is invalid (negative accuracy, non-finite values).
    var cachedLocation: CachedLocation? { get }
}

/// Where the cached position is read. `CLLocationManager.location` in the
/// app; a fake in tests.
protocol LastKnownLocationProviding: AnyObject {
    var location: CLLocation? { get }
}

extension CLLocationManager: LastKnownLocationProviding {}

extension CachedLocation {
    /// `location` when authorisation allows reading it at all
    /// (`authorizedWhenInUse` or `authorizedAlways`) and its position is
    /// valid, else nil. Reads `location` only when authorised.
    static func read(
        authorization: CLAuthorizationStatus,
        from provider: any LastKnownLocationProviding
    ) -> CachedLocation? {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways,
              let location = provider.location else { return nil }
        let coordinate = location.coordinate
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy.isFinite,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return CachedLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy
        )
    }
}
