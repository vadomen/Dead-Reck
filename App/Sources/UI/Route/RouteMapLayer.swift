import CoreLocation
import DriveLoggerCore
import MapKit
import SwiftUI

/// Colours of the route line, explicit per scheme (MapKit overlays ignore
/// dynamic colours). A violet line with a pale (light) or near-black (dark)
/// casing: distinct from the OSM roads line (teal), the GPS track (accuracy
/// bands), the estimate (blue) and the debug edge (orange).
enum RouteColors {
    static func line(dark: Bool, chosen: Bool) -> HUDRGB {
        switch (dark, chosen) {
        case (false, true): HUDRGB(r: 112, g: 36, b: 204)
        case (false, false): HUDRGB(r: 140, g: 118, b: 190, a: 0.8)
        case (true, true): HUDRGB(r: 190, g: 140, b: 255)
        case (true, false): HUDRGB(r: 150, g: 130, b: 190, a: 0.8)
        }
    }

    static func casing(dark: Bool) -> HUDRGB {
        dark ? HUDRGB(r: 12, g: 12, b: 24, a: 0.85) : HUDRGB(r: 255, g: 255, b: 255, a: 0.9)
    }

    static func color(_ rgb: HUDRGB) -> Color {
        Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, opacity: rgb.a)
    }

    static let chosenWidth = 7.0
    static let otherWidth = 5.0
    static let casingExtra = 4.0
}

/// The route on the map: the offered alternatives (chosen one emphasised) or
/// the active route, then the destination flag. First in the map's content,
/// so the GPS track and the estimate marker draw over it.
struct RouteOverlay: MapContent {
    var flow: RouteFlowModel
    var dark: Bool

    var body: some MapContent {
        if flow.phase == .alternatives {
            ForEach(Array(flow.alternatives.enumerated()), id: \.offset) { index, route in
                if index != flow.chosenIndex { line(route, chosen: false) }
            }
            if let chosen = flow.chosenRoute { line(chosen, chosen: true) }
        } else if let active = flow.active {
            line(active.route, chosen: true)
        }
        if let place = flow.destinationShown {
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), anchor: .bottom) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, Color.red)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    @MapContentBuilder
    private func line(_ route: Route, chosen: Bool) -> some MapContent {
        let coordinates = route.polyline.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        MapPolyline(coordinates: coordinates)
            .stroke(
                RouteColors.color(RouteColors.casing(dark: dark)),
                style: StrokeStyle(
                    lineWidth: (chosen ? RouteColors.chosenWidth : RouteColors.otherWidth) + RouteColors.casingExtra,
                    lineCap: .round, lineJoin: .round))
        MapPolyline(coordinates: coordinates)
            .stroke(
                RouteColors.color(RouteColors.line(dark: dark, chosen: chosen)),
                style: StrokeStyle(
                    lineWidth: chosen ? RouteColors.chosenWidth : RouteColors.otherWidth, lineCap: .round, lineJoin: .round))
    }
}

extension RouteFlowModel {
    /// The destination flag on the map: the place of the card, the pending
    /// request or the active route; none while idle or searching.
    var destinationShown: RoutePlace? {
        switch phase {
        case .idle, .search, .arrived: nil
        case .placeCard, .requesting, .alternatives: place
        case .guiding: active?.place ?? place
        }
    }
}

/// Where the camera goes when the flow changes phase.
enum RouteCameraRule {
    enum Action: Equatable { case none, frameRoute, resumeFollow }

    /// Frame the whole route when the alternatives appear; return to the normal
    /// follow mode when they go away (Start, or backing out).
    static func action(from old: RouteFlowModel.Phase?, to new: RouteFlowModel.Phase?) -> Action {
        if new == .alternatives, old != .alternatives { return .frameRoute }
        if old == .alternatives, new != .alternatives, new != .requesting { return .resumeFollow }
        return .none
    }
}

/// The region that shows a whole route above a panel covering the bottom
/// `coveredFraction` of the map. Pure.
enum RouteFraming {
    /// Room around the route inside the visible part.
    static let margin = 1.35
    /// Smallest span, degrees (a route of a few metres).
    static let minSpan = 0.004
    static let maxSpan = 8.0

    /// `aspect`: map width over height.
    static func region(
        points: [(latitude: Double, longitude: Double)], coveredFraction: Double, aspect: Double = 0.5
    ) -> MKCoordinateRegion? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let centreLat = (minLat + maxLat) / 2, centreLon = (minLon + maxLon) / 2
        let cosLat = max(cos(centreLat * .pi / 180), 0.05)
        let visibleFraction = min(max(1 - coveredFraction, 0.2), 1)
        let latNeeded = (maxLat - minLat) * margin
        let lonNeeded = (maxLon - minLon) * margin * cosLat / max(aspect, 0.1)
        let visibleLat = min(max(max(latNeeded, lonNeeded), minSpan), maxSpan)
        let totalLat = visibleLat / visibleFraction
        // The visible part is the top: its centre is `coveredFraction / 2` of the
        // total above the region's centre, so the region's centre goes south.
        let shiftedLat = centreLat - totalLat * coveredFraction / 2
        guard abs(shiftedLat) <= 90, abs(centreLon) <= 180 else { return nil }
        let totalLon = min(totalLat * aspect / cosLat, 360)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: shiftedLat, longitude: centreLon),
            span: MKCoordinateSpan(latitudeDelta: totalLat, longitudeDelta: totalLon))
    }
}

/// The long press that drops a destination pin: 0.5 s, cancelled by a drag of
/// 10 pt or more, so panning is unaffected. The double tap ("I'm here" pin)
/// and the HUD's 1 s speed press are other views and gestures.
enum RouteGesture {
    static let longPressSeconds = 0.5
    static let cancelDistance = 10.0
}

struct RouteLongPress: ViewModifier {
    var space: String
    var proxy: MapProxy
    var action: (GeoPoint) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: RouteGesture.longPressSeconds, maximumDistance: RouteGesture.cancelDistance)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
                .onEnded { value in
                    guard case .second(true, let drag?) = value,
                          let coordinate = proxy.convert(drag.startLocation, from: .named(space)) else { return }
                    action(GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
                })
    }
}
