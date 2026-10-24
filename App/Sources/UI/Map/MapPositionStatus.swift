import Foundation
import SwiftUI

/// The matched road under the arrow, in every build (C7, prompt 38): a thin,
/// quiet line along the OSM edge the cloud is on, drawn while the share of
/// particles on a road is at least `minShare`. It tells the driver that roads
/// are engaged (a slow start otherwise reads as "binding is broken"). It is
/// not a route: thin, muted teal, under the arrow, never the blue of the
/// ellipse or of a route line. The orange strip of the debug switch
/// (`RoadDebugOverlay`) replaces it while that switch is on.
enum MatchedRoadLine {
    /// "On road" share from which the line is drawn.
    static let minShare = 0.9
    static let lineWidth = 3.0

    /// The edge to draw, or nil: too few points, no share yet, or the cloud
    /// is not on a road.
    static func edge(points: [GeoPoint], onRoadShare: Double?) -> [GeoPoint]? {
        guard let onRoadShare, onRoadShare.isFinite, onRoadShare >= minShare, points.count >= 2 else { return nil }
        return points
    }

    /// Explicit per scheme: MapKit overlays do not resolve dynamic colours
    /// (REL-DEMO). Dark teal on the light map, pale teal on the dark one.
    static func rgb(dark: Bool) -> HUDRGB {
        dark ? HUDRGB(r: 115, g: 217, b: 199, a: 0.75) : HUDRGB(r: 20, g: 105, b: 95, a: 0.7)
    }

    static func color(dark: Bool) -> Color {
        let c = rgb(dark: dark)
        return Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: c.a)
    }
}

/// The map's one-line "Finding your position..." status (C6, prompt 38): shown
/// while the engine has no direction yet (not converged) or its 95 % ellipse
/// is wider than `maxSemiMajorM` (roads are not engaged yet; they engage below
/// 1 km), hidden once converged and within it. The wording asks nothing of the
/// driver but to keep driving (no touching the phone while moving).
enum PositionStatus {
    static let text = String(localized: "Finding your position… · keep driving")
    static let maxSemiMajorM = 1_000.0

    static func isFinding(_ nav: NavDisplay?) -> Bool {
        guard let nav else { return false }
        return !nav.converged || !(nav.semiMajorM <= maxSemiMajorM)
    }

    /// The line for the estimate on the map, or nil.
    static func line(_ nav: NavDisplay?) -> String? { isFinding(nav) ? text : nil }
}

/// The status line. Its own view, so only it observes the feed's `display`
/// (the map's body does not re-render with the estimate). Empty when there is
/// nothing to say.
struct PositionStatusLine: View {
    var feed: NavigationFeed

    var body: some View {
        if let text = PositionStatus.line(feed.display) {
            Label(text, systemImage: "location.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                // Wraps in full (Ukrainian is longer; large Dynamic Type longer still): never cut.
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .hudSurface(RoundedRectangle(cornerRadius: 22))
                // Like the other map cards: wraps in full, but does not grow past AX2 (R67.1-5).
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
                .transition(.opacity)
        }
    }
}
