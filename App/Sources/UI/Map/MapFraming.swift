import DriveLoggerCore
import Foundation

/// Pure rules for the map camera and the manual-fix panel text. No MapKit,
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

/// A pin the driver has dropped but not yet confirmed.
struct StagedFix: Hashable {
    var latitude: Double
    var longitude: Double
    /// From `RecordingSession.manualFixPressTime()` at long-press begin.
    /// nil only in previews.
    var press: ManualFixPress?
}

/// A manual fix that `recordManualFix` accepted, for display.
struct ConfirmedFix: Hashable, Identifiable {
    let id: Int
    var latitude: Double
    var longitude: Double
    /// Trimmed note, nil when empty.
    var note: String?
}

/// What the confirm panel needs from the recorder, read inside the panel's
/// own body so only it observes the live status.
struct ManualFixAvailability: Hashable {
    var canRecord: Bool
    var gate: ManualFixGate.Result
}

enum ManualFixText {
    /// Why Confirm is disabled, nil when it is enabled.
    static func disabledReason(_ availability: ManualFixAvailability) -> String? {
        if availability.canRecord { return nil }
        let gate = availability.gate
        if !gate.isAllowed {
            let limit = Int(ManualFixGate.maxSpeedKmh)
            var text = "Slow to ≤\(limit) km/h to confirm"
            if let kmh = gate.speedKmh {
                let source = gate.speedSource == .obd ? "OBD" : "GPS"
                text += " (\(source) \(DisplayFormat.speed(kmh)) km/h)"
            }
            return text
        }
        return "Not recording"
    }
}
