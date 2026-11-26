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
        // No speed source while not standing (prompt 53d) is uncertain for every consumer.
        return nav.noSpeedSource || !nav.converged || !(nav.semiMajorM <= maxSemiMajorM)
    }

    /// The line for the estimate on the map, or nil. While there is no speed source the reason
    /// replaces "Finding your position…": driving on finds nothing without one.
    static func line(_ nav: NavDisplay?) -> String? {
        guard isFinding(nav) else { return nil }
        return nav?.noSpeedSource == true ? NoSpeedSourceText.text : text
    }

    /// The status line's symbol.
    static func symbol(_ nav: NavDisplay?) -> String {
        nav?.noSpeedSource == true ? NoSpeedSourceText.symbol : "location.magnifyingglass"
    }
}

extension PositionStatus {
    /// What the status capsule draws.
    enum Presentation: Equatable {
        /// Symbol and the sentence.
        case sentence(symbol: String, text: String)
        /// The symbol alone; the sentence stays as the accessibility label.
        case glyphOnly(symbol: String, accessibilityLabel: String)

        var symbol: String {
            switch self {
            case .sentence(let symbol, _), .glyphOnly(let symbol, _): symbol
            }
        }

        /// What VoiceOver reads, in both shapes.
        var accessibilityLabel: String {
            switch self {
            case .sentence(_, let text): text
            case .glyphOnly(_, let label): label
            }
        }
    }

    /// The capsule for `nav`, or nil when there is nothing to say (same rule as `line`). While the guidance
    /// bar shows the "No speed source" reason (`barShowsNoSpeedReason`), the capsule keeps the uncertain
    /// glyph and drops the sentence the bar already says; every other state is unchanged.
    static func presentation(_ nav: NavDisplay?, barShowsNoSpeedReason: Bool) -> Presentation? {
        guard let text = line(nav) else { return nil }
        let symbol = symbol(nav)
        if barShowsNoSpeedReason, nav?.noSpeedSource == true {
            return .glyphOnly(symbol: symbol, accessibilityLabel: text)
        }
        return .sentence(symbol: symbol, text: text)
    }
}

/// The status line. Its own view, so only it observes the feed's `display`
/// (the map's body does not re-render with the estimate). Empty when there is
/// nothing to say.
struct PositionStatusLine: View {
    var feed: NavigationFeed
    /// The route flow, read here (not by the map's body) for whether the guidance bar shows the reason.
    var flow: RouteFlowModel?

    var body: some View {
        if let shape = PositionStatus.presentation(feed.display, barShowsNoSpeedReason: flow?.barShowsNoSpeedReason ?? false) {
            capsule(shape)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .hudSurface(RoundedRectangle(cornerRadius: 22))
                // Like the other map cards: wraps in full, but does not grow past AX2 (R67.1-5).
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shape.accessibilityLabel)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func capsule(_ shape: PositionStatus.Presentation) -> some View {
        switch shape {
        case .sentence(let symbol, let text):
            // Wraps in full (Ukrainian is longer; large Dynamic Type longer still): never cut.
            Label(text, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
        case .glyphOnly(let symbol, _):
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
        }
    }
}
