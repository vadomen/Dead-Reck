import DriveLoggerCore
import Foundation

/// Pure rules for the map camera. No MapKit,
/// so they are testable without a view.
enum MapFraming {
    /// Smallest visible span, metres.
    static let minSpanM = 500.0

    /// `max(500 m, 3 × horizontalAccuracy)`; 500 m when the accuracy is
    /// invalid (negative or non-finite).
    static func spanMeters(horizontalAccuracy: Double) -> Double {
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else { return minSpanM }
        return max(minSpanM, 3 * horizontalAccuracy)
    }

    /// Visible north-south extent in metres of a region `latitudeDelta`
    /// degrees tall (about 111.32 km per degree). nil when not usable.
    static func visibleSpanMeters(latitudeDelta: Double) -> Double? {
        guard latitudeDelta.isFinite, latitudeDelta > 0 else { return nil }
        return latitudeDelta * 111_320
    }
}

extension MapFraming {
    /// Camera heading (degrees) beyond which the viewport counts as rotated.
    static let rotatedHeadingThresholdDeg = 0.5

    /// Visible span for the map's report, the same quantity in both modes
    /// (M10.1-3): the viewport's height in metres, which is the N-S extent
    /// of a north-up map.
    ///
    /// North-up: `region.span.latitudeDelta`. Rotated (heading-up): that
    /// delta is the N-S extent of the rotated viewport's bounding box,
    /// H|cos θ| + W|sin θ|: on a portrait screen between ~0.5x and ~1.15x
    /// the viewport height, smallest near east/west headings, so the span is
    /// derived from the camera distance instead (`distancePerSpan`, the same
    /// approximation the follow camera uses). nil when not usable.
    static func visibleSpanMeters(latitudeDelta: Double, cameraDistance: Double, heading: Double) -> Double? {
        guard heading.isFinite else { return nil }
        let turned = abs(HeadingSmoother.shortestDelta(from: 0, to: heading))
        if turned <= rotatedHeadingThresholdDeg {
            return visibleSpanMeters(latitudeDelta: latitudeDelta)
        }
        guard cameraDistance.isFinite, cameraDistance > 0 else { return nil }
        return cameraDistance / distancePerSpan
    }
}

/// A manual fix shown on the map. Drawn as pending until the recorder has
/// written it (its undo window is over).
struct ConfirmedFix: Hashable, Identifiable {
    /// The recorder's `PendingManualFix.id`.
    let id: Int
    var latitude: Double
    var longitude: Double
}

extension MapFraming {
    /// What the camera opens on (R74.1-1). During the demo only the demo's
    /// own estimate or area; never a real fix or the cached location.
    enum OpenChoice: Equatable {
        case fix, estimate, demoRegion, cached, none
    }

    static func chooseOpen(hasFix: Bool, hasEstimate: Bool, demo: Bool, hasCached: Bool) -> OpenChoice {
        if demo { return hasEstimate ? .estimate : .demoRegion }
        if hasFix { return .fix }
        if hasEstimate { return .estimate }
        return hasCached ? .cached : .none
    }
}
