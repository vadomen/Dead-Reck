import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Settings → Maps text and rules, the map's OSM attribution and the roads
// debug overlay (N3.4 items 5 and 6). Synthetic pack names only.

@Suite("Maps text")
struct MapsTextTests {
    private func pack(
        coverage: Bool? = true, refusal: String? = nil, pending: Bool = false, osm: Int64? = 1_760_000_000,
        hash: String? = "a1b2c3d4e5f6", bytes: Int64? = 48_000_000, packName: String? = "region-a", inbox: Bool = false
    ) -> RoadPackLibrary.PackStatus {
        var p = RoadPackLibrary.PackStatus(
            name: "region-a-00.roadpack", verified: refusal == nil && !pending, refusal: refusal, sizeBytes: bytes,
            osmTimestamp: osm, hashPrefix: hash, cacheHit: false, verifySeconds: 1.2)
        p.packName = packName
        p.hasCoverage = coverage
        p.pendingRemoval = pending
        p.inInbox = inbox
        return p
    }

    @Test("Coverage wording: area, bounding box only, unknown")
    func coverage() {
        #expect(MapsText.coverage(pack(coverage: true)) == "Coverage area")
        #expect(MapsText.coverage(pack(coverage: false)) == "Bounding box only")
        #expect(MapsText.coverage(pack(coverage: nil)) == "Coverage unknown")
    }

    @Test("Size, OSM date, 8-digit hash, total storage")
    func fields() {
        #expect(MapsText.size(48_000_000) == "48.0 MB")
        #expect(MapsText.size(nil) == "-- MB")
        #expect(MapsText.osmDate(pack(osm: 1_760_000_000)) == "OSM 2025-10-09")
        #expect(MapsText.osmDate(pack(osm: 0)) == "OSM date unknown")
        #expect(MapsText.osmDate(pack(osm: nil)) == "OSM date unknown")
        #expect(MapsText.hash(pack(hash: "a1b2c3d4e5f6")) == "a1b2c3d4")
        #expect(MapsText.hash(pack(hash: nil)) == "no hash")
        #expect(MapsText.totalStorage(216_000_000) == "Storage used: 216.0 MB")
        #expect(MapsText.totalStorage(nil) == "Storage used: -- MB")
    }

    @Test("Attribution under the list exactly when a pack is listed")
    func attribution() {
        #expect(!MapsText.attributionVisible(packs: []))
        #expect(MapsText.attributionVisible(packs: [pack()]))
    }

    @Test("Remove is offered for a stored pack not already pending")
    func canRemove() {
        #expect(MapsText.canRemove(pack()))
        #expect(MapsText.canRemove(pack(refusal: "bad hash")), "a refused installed pack can be removed")
        #expect(!MapsText.canRemove(pack(pending: true)))
        #expect(!MapsText.canRemove(pack(packName: nil)))
        #expect(!MapsText.canRemove(pack(inbox: true)))
    }

    @Test("Confirmation names the pack; notices per outcome")
    func notices() {
        #expect(MapsText.confirmationTitle(pack()) == "Remove region-a?")
        #expect(MapsText.confirmationMessage(pack()) == "Frees 48.0 MB. Recordings are not affected.")
        #expect(MapsText.notice(.deleted(["x"]), packName: "region-a") == nil)
        #expect(MapsText.notice(.removalPending(["x"]), packName: "region-a")
                == "region-a: Removal takes effect after the app restarts.")
        #expect(MapsText.notice(.notInstalled, packName: "region-a") == "region-a is not installed.")
        #expect(MapsText.notice(.failed("disk"), packName: "region-a") == "Could not remove region-a: disk")
    }

    @Test("Tone: good, bad, caution while removal is pending")
    func tone() {
        #expect(MapsText.tone(pack()) == .good)
        #expect(MapsText.tone(pack(refusal: "bad")) == .bad)
        #expect(MapsText.tone(pack(pending: true)) == .caution)
    }

    @Test("Developer verify line: cached, verified in, not verified")
    func verifyLine() {
        var p = pack()
        #expect(RoadsDiagnosticsText.verifyLine(p) == "verified in 1.2 s")
        p = RoadPackLibrary.PackStatus(
            name: "n", verified: true, refusal: nil, sizeBytes: nil, osmTimestamp: nil, hashPrefix: nil,
            cacheHit: true, verifySeconds: nil)
        #expect(RoadsDiagnosticsText.verifyLine(p) == "cached")
        p = RoadPackLibrary.PackStatus(
            name: "n", verified: false, refusal: "x", sizeBytes: nil, osmTimestamp: nil, hashPrefix: nil,
            cacheHit: false, verifySeconds: nil)
        #expect(RoadsDiagnosticsText.verifyLine(p) == "not verified")
    }
}

@Suite("Maps model", .serialized)
@MainActor
struct MapsModelTests {
    @Test("Remove during a run is pending, says so, and cannot be repeated")
    func removeFlow() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let source = try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: dirs.sources)
        _ = try #require(store.installer.install(from: source, name: "region-a").installed)
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        let model = MapsModel(library: library)

        await library.setRunActivity { true }
        _ = await library.candidates()
        await model.refresh()
        let listed = try #require(model.status.installedPacks.first)
        #expect(listed.packName == "region-a" && MapsText.canRemove(listed))
        await model.remove(listed)
        #expect(model.notice == "region-a: " + MapsText.restartNote)
        let pending = try #require(model.status.installedPacks.first)
        #expect(pending.pendingRemoval && !MapsText.canRemove(pending))
        #expect(RoadsDiagnosticsText.state(pending) == "Removal pending (after restart)")

        // A pending pack cannot be removed again.
        model.dismissNotice()
        await model.remove(pending)
        #expect(model.notice == nil)
    }

    @Test("Remove with no run active deletes the files at once and the list empties")
    func removeIdle() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let source = try RoadPackFixture.write(try RoadPackFixture.data(), named: "b.roadpack", in: dirs.sources)
        _ = try #require(store.installer.install(from: source, name: "region-b").installed)
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        await library.setRunActivity { false }
        _ = await library.candidates()
        let model = MapsModel(library: library)
        await model.refresh()
        let fresh = try #require(model.status.installedPacks.first)
        #expect(model.status.storeBytes ?? 0 > 0)
        await model.remove(fresh)
        #expect(model.notice == nil)
        #expect(model.status.installedPacks.isEmpty)
        #expect(StoreFixture.entries(dirs.store).filter { $0.hasSuffix(".roadpack") }.isEmpty)
    }
}

@Suite("Map roads overlay")
@MainActor
struct MapRoadsOverlayTests {
    @Test("Attribution: only while the active run has packs attached")
    func attribution() {
        #expect(MapAttribution.visible(runActive: true, packsInUse: 1))
        #expect(MapAttribution.visible(runActive: true, packsInUse: 3))
        #expect(!MapAttribution.visible(runActive: true, packsInUse: 0))
        #expect(!MapAttribution.visible(runActive: false, packsInUse: 2), "a finished run draws nothing from OSM")
        #expect(MapAttribution.text == "© OpenStreetMap contributors")
    }

    @Test("Debug overlay: off by default draws nothing; on draws a polyline of two or more points and the share")
    func gating() {
        let edge = [GeoPoint(latitude: 0.001, longitude: 0.002), GeoPoint(latitude: 0.002, longitude: 0.004)]
        #expect(RoadDebugOverlay.edge(enabled: false, points: edge) == nil)
        #expect(RoadDebugOverlay.edge(enabled: true, points: edge) == edge)
        #expect(RoadDebugOverlay.edge(enabled: true, points: []) == nil)
        #expect(RoadDebugOverlay.edge(enabled: true, points: [edge[0]]) == nil)
        #expect(RoadDebugOverlay.shareLine(enabled: false, share: 0.93) == nil)
        #expect(RoadDebugOverlay.shareLine(enabled: true, share: 0.93) == "on road 93 %")
        #expect(RoadDebugOverlay.shareLine(enabled: true, share: nil) == "on road --")
    }

    @Test("Stats display carries onRoadShare from the snapshot")
    func statsShare() {
        let stats = NavigationSnapshot.Stats(onRoadShare: 0.5)
        #expect(NavStatsDisplay(stats).onRoadShare == 0.5)
        #expect(NavStatsDisplay(NavigationSnapshot.Stats()).onRoadShare == nil)
    }

    @Test("Feed: the matched edge is rebuilt only when the edge changes, and cleared without roads")
    func feedEdge() throws {
        let pack = try RoadPack(data: RoadPackFixture.data(), verify: false)
        let network = try RoadNetwork(packs: [pack])
        let edge = MatchedRoadEdge(pack: 0, edge: 0, osmWayID: 10)
        let geometry = try #require(MatchedEdgeGeometry(edge: edge, network: network))
        let feed = NavigationFeed(display: nil)
        let now = ContinuousClock.now
        func snapshot(_ g: MatchedEdgeGeometry?) -> NavigationSnapshot {
            NavigationSnapshot(t: MonotonicTimestamp(seconds: 1), sessionID: UUID(), estimate: nil, stats: .init(),
                               matchedEdgeGeometry: g)
        }
        #expect(feed.matchedEdge.isEmpty)
        _ = feed.apply(snapshot(geometry), at: now)
        #expect(feed.matchedEdge.count == geometry.points.count && feed.matchedEdge.count >= 2)
        #expect(feed.matchedEdge.first == GeoPoint(latitude: geometry.points[0].latitude, longitude: geometry.points[0].longitude))
        // Same edge, same geometry: still there.
        _ = feed.apply(snapshot(geometry), at: now + .seconds(1))
        #expect(feed.matchedEdge.count == geometry.points.count)
        // No roads (or a run without a matched edge): cleared.
        _ = feed.apply(snapshot(nil), at: now + .seconds(2))
        #expect(feed.matchedEdge.isEmpty)
    }

    @Test("Warning model: attribution follows its source and is written only on change")
    func warningModelAttribution() async {
        actor Flag { var on = false; func set(_ v: Bool) { on = v }; func get() -> Bool { on } }
        let flag = Flag()
        let model = RoadsWarningModel(source: { nil }, attributionSource: { await flag.get() })
        await model.refresh()
        #expect(!model.attribution)
        await flag.set(true)
        await model.refresh()
        #expect(model.attribution)
        #expect(RoadsWarningModel(message: nil, attribution: true).attribution)
        #expect(RoadsWarning.refused.hasSuffix("see Maps"))
    }
}
