import DriveLoggerCore
import Foundation

/// Text and symbols of the route UI. Pure; numbers go through the locale,
/// units through the catalog (no-break space before them, glossary §0).
enum RouteFormat {
    /// "350 m" under 1 km (rounded to 10 m under 1 km, to 50 m under 200 m),
    /// "12.4 km" from 1 km (one decimal under 10 km, whole above).
    static func distance(_ metres: Double, locale: Locale = .current) -> String {
        guard metres.isFinite else { return "—" }
        let m = max(0, metres)
        if m < 1_000 {
            let step = m < 200 ? 10.0 : 50.0
            return String(localized: "\(Int((m / step).rounded() * step)) m")
        }
        let km = m / 1_000
        let digits = km < 10 ? 1 : 0
        let text = km.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
        return String(localized: "\(text) km")
    }

    /// "14 min", "1 h 5 min"; at least 1 min.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let minutes = max(1, Int((max(0, seconds) / 60).rounded()))
        if minutes < 60 { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }

    /// One alternative's line: "12.4 km · 25 min".
    static func summary(_ route: Route) -> String {
        String(localized: "\(distance(route.distanceM)) · \(duration(route.expectedTravelTimeS))")
    }

    /// The remaining line of the next-manoeuvre bar.
    static func remaining(distanceM: Double, timeS: Double) -> String {
        String(localized: "\(distance(distanceM)) · \(duration(timeS)) left")
    }

    /// SF Symbol of a maneuver's glyph.
    static func symbol(_ maneuver: RouteManeuver) -> String {
        switch maneuver {
        case .depart, .straight: "arrow.up"
        case .slightLeft: "arrow.up.left"
        case .left: "arrow.turn.up.left"
        case .sharpLeft: "arrow.turn.down.left"
        case .slightRight: "arrow.up.right"
        case .right: "arrow.turn.up.right"
        case .sharpRight: "arrow.turn.down.right"
        case .uTurn: "arrow.uturn.down"
        case .roundaboutExit: "arrow.triangle.turn.up.right.circle"
        case .merge: "arrow.merge"
        case .exitRamp: "arrow.up.right"
        case .arrive: "flag.checkered"
        case .unknown: "arrow.up"
        }
    }

    /// The short name of a maneuver: the bar's text when the provider's
    /// instruction is empty, and the glyph's VoiceOver label.
    static func name(_ maneuver: RouteManeuver) -> String {
        switch maneuver {
        case .depart, .straight, .unknown: String(localized: "Straight")
        case .slightLeft: String(localized: "Slight left")
        case .left: String(localized: "Left")
        case .sharpLeft: String(localized: "Sharp left")
        case .slightRight: String(localized: "Slight right")
        case .right: String(localized: "Right")
        case .sharpRight: String(localized: "Sharp right")
        case .uTurn: String(localized: "U-turn")
        case .roundaboutExit: String(localized: "Roundabout exit")
        case .merge: String(localized: "Merge")
        case .exitRamp: String(localized: "Exit")
        case .arrive: String(localized: "Arrive")
        }
    }

    /// What the bar says for a step: the provider's instruction, else the maneuver's name.
    static func instruction(_ step: RouteStep) -> String {
        step.instruction.isEmpty ? name(step.maneuver) : step.instruction
    }

    static func message(_ failure: RouteFlowModel.Failure) -> String {
        switch failure {
        case .offline: String(localized: "No internet connection")
        case .nothingFound: String(localized: "Nothing found")
        case .busy: String(localized: "Apple Maps is busy. Try again in a moment.")
        case .failed: String(localized: "Something went wrong.")
        }
    }
}
