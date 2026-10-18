import Foundation

// Pure rules for what the map shows of roads (N3.4 item 6): the OSM
// attribution and the debug drawing of the matched edge. No MapKit and no
// SwiftUI, so every decision is unit-testable.

/// "© OpenStreetMap contributors" on the map.
enum MapAttribution {
    static let text = RoadsDiagnosticsText.attribution

    /// Shown while the current run has road packs attached ("loaded" = attached
    /// by the run, `RoadsStatus.inUse`): a recording or Navigate that is
    /// running and whose roads are on. Not for installed-but-unused packs
    /// and not after the run ended: nothing from OSM is on the screen then.
    static func visible(runActive: Bool, packsInUse: Int) -> Bool {
        runActive && packsInUse > 0
    }
}

/// The roads debug overlay: the matched OSM edge as a polyline and the
/// share of particles on a road in the stats lines. Off by default; it rides
/// on the existing `debug.navStats` switch (long-press on the speed number,
/// or Settings → Diagnostics).
enum RoadDebugOverlay {
    /// The polyline to draw, or nil: switch off, or fewer than two points.
    static func edge(enabled: Bool, points: [GeoPoint]) -> [GeoPoint]? {
        enabled && points.count >= 2 ? points : nil
    }

    /// The stats line, or nil when the switch is off. "--" without roads or
    /// before the first road update.
    static func shareLine(enabled: Bool, share: Double?) -> String? {
        guard enabled else { return nil }
        return "on road " + RoadsDiagnosticsText.onRoadShare(share)
    }
}
