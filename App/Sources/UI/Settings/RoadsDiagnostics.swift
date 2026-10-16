import Foundation
import Observation

/// Pure text and rules for the roads rows of Settings → Diagnostics.
enum RoadsDiagnosticsText {
    static let attribution = "© OpenStreetMap contributors"

    /// The attribution is shown whenever a pack is in use by the recording.
    static func attributionVisible(packsInUse: Int) -> Bool { packsInUse > 0 }

    static func state(_ pack: RoadPackLibrary.PackStatus) -> String {
        pack.verified ? "Verified" : "Refused: " + (pack.refusal ?? "not usable")
    }

    /// "12.3 MB · OSM 2026-10-01 · a1b2c3d4 · cached".
    static func detail(_ pack: RoadPackLibrary.PackStatus) -> String {
        var parts: [String] = []
        parts.append(pack.sizeBytes.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "-- MB")
        if let ts = pack.osmTimestamp, ts > 0 {
            parts.append("OSM " + Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.iso8601.year().month().day()))
        } else {
            parts.append("OSM date unknown")
        }
        parts.append(pack.hashPrefix ?? "no hash")
        if pack.cacheHit {
            parts.append("cached")
        } else if let s = pack.verifySeconds {
            parts.append("verified in " + duration(s))
        }
        return parts.joined(separator: " · ")
    }

    /// Below 1 s whole milliseconds ("42 ms"), else seconds with one decimal ("1.2 s").
    /// A value that would round up to 1000 ms shows as "1.0 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let ms = (max(seconds, 0) * 1000).rounded()
        if ms < 1000 { return "\(Int(ms)) ms" }
        return String(format: "%.1f s", seconds)
    }

    /// Which packs the recording uses and since when, else why none.
    static func usage(_ roads: NavigationService.RoadsStatus) -> String {
        if roads.inUse {
            let at = roads.activeAtSessionS.map { String(format: " from %.0f s", $0) } ?? ""
            return roads.packNames.joined(separator: ", ") + at
        }
        if let refusal = roads.refusal { return "none (refused: \(refusal))" }
        return roads.selectionPending ? "none yet (looking for a pack)" : "none"
    }

    static func onRoadShare(_ share: Double?) -> String {
        share.map { String(format: "%.0f %%", $0 * 100) } ?? "--"
    }
}

/// Everything the roads rows show, as plain values.
struct RoadsDiagnostics: Equatable, Sendable {
    var library = RoadPackLibrary.Status.empty
    var roads = NavigationService.RoadsStatus.none
    var footprintBytes: UInt64?
}

/// Reads the library and the navigation service for Settings → Diagnostics.
@MainActor
@Observable
final class RoadsDiagnosticsModel {
    private(set) var value = RoadsDiagnostics()
    @ObservationIgnored private let library: RoadPackLibrary?
    @ObservationIgnored private let service: NavigationService?

    init(library: RoadPackLibrary, service: NavigationService) {
        self.library = library
        self.service = service
    }

    /// Previews and tests: fixed values.
    init(value: RoadsDiagnostics) {
        self.value = value
        library = nil
        service = nil
    }

    func refresh() async {
        guard let library, let service else { return }
        let status = await library.status()
        let roads = await service.roadsStatus()
        let next = RoadsDiagnostics(library: status, roads: roads, footprintBytes: MemoryFootprint.currentBytes())
        if next != value { value = next }
    }

    /// While Diagnostics is visible: rescan once, then refresh every 2 s.
    func run() async {
        await library?.rescan()
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
