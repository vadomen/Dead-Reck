import CoreLocation
import Foundation
import MapKit

/// The live `DestinationSearching`: `MKLocalSearchCompleter` for completions,
/// `MKLocalSearch` for resolving one. Thin on purpose: everything with a rule
/// in it (debounce, pacing, region choice) is in the flow and the pacer.
/// Search text is sent to Apple (MapKit); nothing goes to us (About →
/// "Data and services"). The device's language decides the result language
/// (uk and en are what the R1 spike measured); no transliteration is tried.
@MainActor
final class MapKitDestinationSearcher: NSObject, DestinationSearching, @preconcurrency MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var pending: CheckedContinuation<[DestinationCompletion], Error>?
    private var results: [String: MKLocalSearchCompletion] = [:]

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func completions(for query: String, region: SearchRegion) async throws -> [DestinationCompletion] {
        // A new query supersedes the one still waiting: it ends as cancelled.
        pending?.resume(throwing: CancellationError())
        pending = nil
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            latitudinalMeters: region.radiusM * 2, longitudinalMeters: region.radiusM * 2)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                completer.queryFragment = query
            }
        } onCancel: {
            Task { @MainActor in
                self.pending?.resume(throwing: CancellationError())
                self.pending = nil
            }
        }
    }

    func resolve(_ completion: DestinationCompletion) async throws -> RoutePlace {
        guard let source = results[completion.id] else { throw RouteServiceError.failed }
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: source)).start()
            guard let item = response.mapItems.first else { throw RouteServiceError.nothingFound }
            let coordinate = item.placemark.coordinate
            let line = [item.placemark.thoroughfare, item.placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            return RoutePlace(
                name: item.name ?? completion.title, addressLine: line.isEmpty ? completion.subtitle : line,
                latitude: coordinate.latitude, longitude: coordinate.longitude)
        } catch let error as RouteServiceError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: MKLocalSearchCompleterDelegate

    // The completer calls its delegate on the main thread.
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        deliver(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        pending?.resume(throwing: Self.map(error))
        pending = nil
    }

    private func deliver(_ found: [MKLocalSearchCompletion]) {
        var list: [DestinationCompletion] = []
        for (index, item) in found.enumerated() {
            let id = "\(index)|\(item.title)|\(item.subtitle)"
            results[id] = item
            list.append(DestinationCompletion(id: id, title: item.title, subtitle: item.subtitle))
        }
        pending?.resume(returning: list)
        pending = nil
    }

    /// `MKError` code 3 is `loadingThrottled`; no network is a URL error.
    nonisolated static func map(_ error: Error) -> RouteServiceError {
        MapKitErrorMapping.map(code: (error as NSError).code, domain: (error as NSError).domain)
    }
}

/// The error-to-case rule, split out so a test can feed it codes and domains
/// without MapKit (`MapKitErrorMappingTests`).
enum MapKitErrorMapping {
    static func map(code: Int, domain: String) -> RouteServiceError {
        if domain == NSURLErrorDomain {
            let offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
                           NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorInternationalRoamingOff]
            return offline.contains(code) ? .offline : .failed
        }
        if domain == MKError.errorDomain {
            switch MKError.Code(rawValue: UInt(code)) {
            case .loadingThrottled: return .throttled
            case .placemarkNotFound, .directionsNotFound: return .nothingFound
            default: return .failed
            }
        }
        return .failed
    }
}
