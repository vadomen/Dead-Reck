import CoreLocation
import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// `LastKnownLocationProviding` whose cached fix the test sets; counts reads,
/// so a test can prove `location` is not even read while unauthorised.
final class FakeLastKnownLocation: LastKnownLocationProviding {
    private(set) var reads = 0
    private let stored: CLLocation?

    init(_ location: CLLocation?) {
        stored = location
    }

    var location: CLLocation? {
        reads += 1
        return stored
    }

    /// A fix near (0, 0): no real place in tests.
    static func fix(horizontalAccuracy: Double = 25) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0.001, longitude: -0.002),
            altitude: 0, horizontalAccuracy: horizontalAccuracy, verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }
}

/// The map camera's cached position (M4.2): read-only, display only, never a
/// reason to start location or ask for permission.
@Suite("Cached location")
@MainActor
struct CachedLocationTests {
    @Test("Authorised: the cached fix's position and accuracy")
    func authorised() {
        for status in [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways] {
            let source = ReferenceLocationSource(
                authorization: FakeLocationAuthorization(status),
                lastKnownLocation: FakeLastKnownLocation(FakeLastKnownLocation.fix())
            )
            #expect(source.cachedLocation == CachedLocation(latitude: 0.001, longitude: -0.002, horizontalAccuracy: 25))
        }
    }

    @Test("Not authorised: nil, and the cached fix is not even read")
    func unauthorised() {
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            let cache = FakeLastKnownLocation(FakeLastKnownLocation.fix())
            let source = ReferenceLocationSource(authorization: FakeLocationAuthorization(status), lastKnownLocation: cache)
            #expect(source.cachedLocation == nil)
            #expect(cache.reads == 0)
        }
    }

    @Test("Nothing cached, or an invalid position (negative accuracy): nil")
    func invalid() {
        let authorised = FakeLocationAuthorization(.authorizedWhenInUse)
        #expect(ReferenceLocationSource(authorization: authorised, lastKnownLocation: FakeLastKnownLocation(nil)).cachedLocation == nil)
        let invalid = FakeLastKnownLocation(FakeLastKnownLocation.fix(horizontalAccuracy: -1))
        #expect(ReferenceLocationSource(authorization: authorised, lastKnownLocation: invalid).cachedLocation == nil)
    }

    @Test("Reading it starts nothing: no background session, no recording rows")
    func startsNothing() {
        let source = ReferenceLocationSource(
            authorization: FakeLocationAuthorization(.authorizedWhenInUse),
            lastKnownLocation: FakeLastKnownLocation(FakeLastKnownLocation.fix())
        )
        _ = source.cachedLocation
        #expect(source.locationAuthorizationDetail.hasSuffix("backgroundActivitySession=none"))
        #expect(source.latestReferenceFix == nil)
    }

    @Test("Only the phone's reference source provides it; the simulator suite does not")
    func whoProvides() {
        #expect(!SensorSuite.simulated().sources.contains { $0 is any CachedLocationProviding })
        let reference: any SensorSource = ReferenceLocationSource(authorization: FakeLocationAuthorization(.denied))
        #expect(reference is any CachedLocationProviding)
    }
}
