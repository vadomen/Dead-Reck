import DriveLoggerCore
import MapKit
import SwiftUI

// The demo drive on the map (REL-DEMO): the bundled pack's roads under the
// arrow, so the map is not blank in airplane mode, the DEMO badge and the
// Stop demo control. Shown only while the demo runs. Decisions are pure
// (`DemoRoadTier`, `DemoRoadLayers`) and tested.

/// How important a road class looks on the demo map.
enum DemoRoadTier: Int, CaseIterable, Comparable, Sendable {
    /// Drawn first, thin.
    case minor
    case collector
    /// Drawn last, thick.
    case major

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// nil: not drawn. Service roads are dropped (most of the pack's lines,
    /// no help to the driver, expensive for MapKit).
    static func tier(for roadClass: RoadClass) -> DemoRoadTier? {
        switch roadClass {
        case .motorway, .trunk, .primary: .major
        case .secondary, .tertiary: .collector
        case .unclassified, .residential, .livingStreet, .road: .minor
        case .service: nil
        }
    }

    var lineWidth: Double {
        switch self {
        case .major: 6
        case .collector: 4.5
        case .minor: 2.5
        }
    }

    /// Slate on the light map, pale on the dark one; the minor roads fainter.
    var color: Color {
        let alpha: Double = switch self {
        case .major: 0.9
        case .collector: 0.8
        case .minor: 0.6
        }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.78, green: 0.82, blue: 0.88, alpha: alpha)
                : UIColor(red: 0.27, green: 0.31, blue: 0.38, alpha: alpha)
        })
    }
}

/// The demo roads ready to draw: coordinates converted once per demo run,
/// grouped by tier in drawing order (minor first). A class, so the map's
/// content compares it by identity and does not rebuild per fix.
final class DemoRoadLayers: Equatable, Sendable {
    struct Layer: Sendable {
        var tier: DemoRoadTier
        var lines: [[CLLocationCoordinate2D]]
    }

    let layers: [Layer]

    init(_ roads: DemoDriveRoads) {
        var byTier: [DemoRoadTier: [[CLLocationCoordinate2D]]] = [:]
        for line in roads.lines where line.points.count >= 2 {
            guard let tier = DemoRoadTier.tier(for: line.highwayClass) else { continue }
            byTier[tier, default: []].append(line.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        }
        layers = DemoRoadTier.allCases.sorted().compactMap { tier in
            byTier[tier].map { Layer(tier: tier, lines: $0) }
        }
    }

    var lineCount: Int { layers.reduce(0) { $0 + $1.lines.count } }

    static func == (a: DemoRoadLayers, b: DemoRoadLayers) -> Bool { a === b }
}

/// What the map needs of a running demo, plain values: nil outside it.
struct MapDemo: Equatable {
    var roads: DemoRoadLayers
    var southWest: GeoPoint
    var northEast: GeoPoint
    var onStop: () -> Void

    static func == (a: MapDemo, b: MapDemo) -> Bool {
        a.roads === b.roads && a.southWest == b.southWest && a.northEast == b.northEast
    }

    /// The demo area with a margin: where the camera opens, before the first
    /// demo estimate (never the user's cached position).
    var region: MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: (southWest.latitude + northEast.latitude) / 2,
            longitude: (southWest.longitude + northEast.longitude) / 2)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.002, (northEast.latitude - southWest.latitude) * 1.15),
                longitudeDelta: max(0.002, (northEast.longitude - southWest.longitude) * 1.15)))
    }
}

/// The demo roads as map content. Its own type so it is rebuilt only when the
/// layers change.
struct DemoRoadsOverlay: MapContent {
    var roads: DemoRoadLayers

    var body: some MapContent {
        ForEach(Array(roads.layers.enumerated()), id: \.offset) { _, layer in
            ForEach(Array(layer.lines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(layer.tier.color, style: StrokeStyle(lineWidth: layer.tier.lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// "DEMO" and the big "Stop demo" button, top right (the top left is the
/// speed card). Always together: the badge exists exactly while the demo runs.
struct DemoControls: View {
    var onStop: () -> Void

    static let badgeText = "DEMO"
    static let stopText = "Stop demo"

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(Self.badgeText)
                .font(.system(size: 16, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(minHeight: MapLayout.minTapTarget - 8)
                .background(Color(red: 1.0, green: 0.78, blue: 0.1), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                .accessibilityLabel("Demo drive, simulated car")
            Button(action: onStop) {
                Label(Self.stopText, systemImage: "stop.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: MapLayout.controlSize)
                    .background(Color(red: 0.78, green: 0.08, blue: 0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop the demo drive")
        }
    }
}

#Preview("Demo controls") {
    DemoControls(onStop: {})
        .padding()
        .background(Color(.secondarySystemBackground))
}

#Preview("Demo controls, dark") {
    DemoControls(onStop: {})
        .padding()
        .background(Color(.secondarySystemBackground))
        .preferredColorScheme(.dark)
}
