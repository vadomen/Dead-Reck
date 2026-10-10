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

/// A manual fix shown on the map. Drawn as pending until the recorder has
/// written it (its undo window is over).
struct ConfirmedFix: Hashable, Identifiable {
    /// The recorder's `PendingManualFix.id`.
    let id: Int
    var latitude: Double
    var longitude: Double
}
