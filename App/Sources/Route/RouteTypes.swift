import DriveLoggerCore
import Foundation

/// Plain values of the destination and route services (prompt 52 = R2). No
/// MapKit type crosses this boundary: the MapKit code in this folder converts
/// to and from these, so the flow and its tests never see Apple's types.

/// A place the driver can route to: what the card shows and what a recent
/// destination stores. Coordinates are as MapKit (or the long press) gave
/// them: never snapped to our road packs.
struct RoutePlace: Hashable, Sendable, Codable {
    var name: String
    /// One line, may be empty (a long-pressed point has none).
    var addressLine: String
    var latitude: Double
    var longitude: Double

    var coordinate: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }

    /// Rounded to 1e-4 degrees (about 11 m): two spellings of one place, or the
    /// same long-press twice, are one recent destination.
    var dedupKey: String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

/// One completion in the search list; resolved to a `RoutePlace` on tap.
struct DestinationCompletion: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
}

/// The area completions are biased to: centre and half-width in metres.
struct SearchRegion: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var radiusM: Double

    /// Kyiv-wide, when there is no estimate and no good fix.
    static let kyivWide = SearchRegion(latitude: 50.45, longitude: 30.52, radiusM: 60_000)
    static let nearbyRadiusM = 30_000.0

    /// The FuGPS estimate, else the last good fix, else Kyiv-wide.
    static func choose(estimate: GeoPoint?, lastGoodFix: GeoPoint?) -> SearchRegion {
        if let p = estimate ?? lastGoodFix {
            return SearchRegion(latitude: p.latitude, longitude: p.longitude, radiusM: nearbyRadiusM)
        }
        return .kyivWide
    }
}

/// Why a search or route request did not give a result. Throttling is its own
/// case on purpose: it must never be shown as "nothing found" (the R1 spike).
enum RouteServiceError: Error, Equatable, Sendable {
    /// No network.
    case offline
    /// MapKit's `loadingThrottled` (`MKError` code 3): retried with backoff.
    case throttled
    /// A valid answer with no result.
    case nothingFound
    /// Anything else.
    case failed
}

/// Destination search (completions as you type; resolving a completion).
@MainActor
protocol DestinationSearching: AnyObject {
    func completions(for query: String, region: SearchRegion) async throws -> [DestinationCompletion]
    func resolve(_ completion: DestinationCompletion) async throws -> RoutePlace
}

/// Routing: origin and destination to up to three automobile routes.
@MainActor
protocol RouteDirecting: AnyObject {
    /// `label` goes into each `Route.label` (the destination as shown).
    func routes(from origin: GeoPoint, to destination: GeoPoint, label: String?) async throws -> [Route]
}

/// Where route rows go (prompt 52 item 5): `RecordingSession` in the app, a
/// recorder stub in tests. Core types only. Both are no-ops outside a
/// recording.
@MainActor
protocol RouteEventSink: AnyObject {
    func routeSet(_ route: Route, reason: RouteSample.Reason, origin: RouteOrigin?)
    func routeCleared(routeID: String, reason: RouteClearedSample.Reason)
}
