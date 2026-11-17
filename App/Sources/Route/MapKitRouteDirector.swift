import CoreLocation
import DriveLoggerCore
import Foundation
import MapKit

/// The live `RouteDirecting`: `MKDirections`, automobile, alternates
/// requested. This file only reads MapKit's answer into
/// `DirectionsRouteInput`; `RouteConversion` (pure, tested) builds the Core
/// `Route`. The origin and the destination are sent to Apple (MapKit); the
/// destination is passed as given, never snapped to our road packs.
@MainActor
final class MapKitRouteDirector: RouteDirecting {
    /// At most this many routes are kept (the card and the map show three).
    static let maxRoutes = 3

    func routes(from origin: GeoPoint, to destination: GeoPoint, label: String?) async throws -> [Route] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: Self.coordinate(origin)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: Self.coordinate(destination)))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            if error is CancellationError { throw error }
            throw MapKitErrorMapping.map(code: (error as NSError).code, domain: (error as NSError).domain)
        }
        let stamp = UUID().uuidString.prefix(8)
        let converted = response.routes.prefix(Self.maxRoutes).enumerated().compactMap { index, mk in
            RouteConversion.route(from: Self.input(mk), id: "apple-\(stamp)-\(index + 1)", label: label)
        }
        guard !converted.isEmpty else { throw RouteServiceError.nothingFound }
        return converted
    }

    private static func coordinate(_ p: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
    }

    private static func points(of polyline: MKPolyline) -> [DirectionsRouteInput.Point] {
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates.map { DirectionsRouteInput.Point(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private static func input(_ route: MKRoute) -> DirectionsRouteInput {
        DirectionsRouteInput(
            points: points(of: route.polyline),
            steps: route.steps.map {
                DirectionsRouteInput.Step(instruction: $0.instructions, distanceM: $0.distance, points: points(of: $0.polyline))
            },
            distanceM: route.distance, expectedTravelTimeS: route.expectedTravelTime)
    }
}
