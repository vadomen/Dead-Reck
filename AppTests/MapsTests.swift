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

    @Test("Size, OSM date (from the timestamp, UTC), total storage")
    func fields() {
        #expect(MapsText.size(48_000_000) == "48.0 MB")
        #expect(MapsText.size(nil) == "-- MB")
        #expect(MapsText.osmDate(pack(osm: 1_760_000_000)) == "OSM 2025-10-09")
        #expect(MapsText.osmDate(timestamp: 1_760_000_000) == "OSM 2025-10-09")
        #expect(MapsText.osmDate(pack(osm: 0)) == "OSM date unknown")
        #expect(MapsText.osmDate(pack(osm: nil)) == "OSM date unknown")
        #expect(MapsText.totalStorage(216_000_000) == "Storage used: 216.0 MB")
        #expect(MapsText.totalStorage(nil) == "Storage used: -- MB")
    }

    @Test("Attribution: the manifest's own text, else the standard credit")
    func attribution() {
        #expect(MapsText.attribution(manifest: nil) == "© OpenStreetMap contributors")
        #expect(MapsText.attribution(manifest: PackManifest.preview([])) == "© OpenStreetMap contributors")
        var manifest = PackManifest.preview([])
        manifest.attribution = "© OSM, ODbL"
        #expect(MapsText.attribution(manifest: manifest) == "© OSM, ODbL")
        manifest.attribution = "  "
        #expect(MapsText.attribution(manifest: manifest) == "© OpenStreetMap contributors")
    }

    @Test("Remove is offered for a stored pack not already pending")
    func canRemove() {
        #expect(MapsText.canRemove(pack()))
        #expect(MapsText.canRemove(pack(refusal: "bad hash")), "a refused installed pack can be removed")
        #expect(!MapsText.canRemove(pack(pending: true)))
        #expect(!MapsText.canRemove(pack(packName: nil)))
        #expect(!MapsText.canRemove(pack(inbox: true)))
    }

    @Test("Notices per outcome")
    func notices() {
        #expect(MapsText.notice(.deleted(["x"]), packName: "region-a") == nil)
        #expect(MapsText.notice(.removalPending(["x"]), packName: "region-a")
                == "region-a: Removal takes effect after the app restarts.")
        #expect(MapsText.notice(.notInstalled, packName: "region-a") == "region-a is not installed.")
        #expect(MapsText.notice(.failed("disk"), packName: "region-a") == "Could not remove region-a: disk")
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

// MARK: - Rows

@Suite("Maps rows")
struct MapsRowsTests {
    static let manifest = PackManifest.preview([
        ("national", .national, "National roads", "0f0e0d0c00000000"),
        ("region-a", .region, "Zulu", "a1b2c3d400000000"),
        ("region-b", .region, "alpha", "5e6f7a8b00000000"),
        ("region-c", .region, "Mike", "1122334400000000"),
    ])

    static func rows(installed: [RoadPackLibrary.PackStatus] = [], downloads: PackDownloader.Snapshot = .init(),
                     manifest: PackManifest? = MapsRowsTests.manifest, languages: [String] = ["en"]) -> MapsRows {
        MapsText.rows(manifest: manifest, installed: installed, downloads: downloads, preferredLanguages: languages,
                      locale: Locale(identifier: "en_US"))
    }

    @Test("Order: national, then installed, then by title; titles come from the manifest")
    func order() {
        let rows = Self.rows(installed: [.preview("region-c", hash: "11223344")])
        #expect(rows.listed.map(\.id) == ["national", "region-c", "region-b", "region-a"])
        #expect(rows.listed.map(\.title) == ["National roads", "Mike", "alpha", "Zulu"])
        #expect(rows.other.isEmpty)
    }

    @Test("The title follows the app language and falls back to the code")
    func titles() {
        var manifest = Self.manifest
        manifest.packs[1].titleUK = "Зулу"
        #expect(Self.rows(manifest: manifest, languages: ["uk-UA"]).listed.first { $0.id == "region-a" }?.title == "Зулу")
        #expect(Self.rows(manifest: manifest, languages: ["en-US"]).listed.first { $0.id == "region-a" }?.title == "Zulu")
        // Before any manifest: installed packs, the code as title.
        let none = Self.rows(installed: [.preview("region-a"), .preview("national", coverage: false)], manifest: nil)
        #expect(none.listed.map(\.title) == ["national", "region-a"])
        #expect(none.other.isEmpty)
    }

    @Test("Installed packs the manifest does not list go to Other, with their code")
    func other() {
        let rows = Self.rows(installed: [.preview("dev-pack"), .preview("region-a", hash: "a1b2c3d4")])
        #expect(rows.other.map(\.title) == ["dev-pack"])
        #expect(rows.other[0].action == nil && rows.other[0].canRemove && rows.other[0].status == .installed)
        #expect(rows.listed.first { $0.id == "region-a" }?.status == .installed)
    }

    @Test("States: not installed, installed, update available, removal pending, refused")
    func installedStates() {
        let rows = Self.rows(installed: [
            .preview("region-a", hash: "a1b2c3d4"),   // same content hash as the manifest's a1b2c3d400000000
            .preview("region-b", hash: "00000001"),   // differs: update
            .preview("region-c", pending: true),
            .preview("national", coverage: false, refusal: "truncated"),
        ])
        func state(_ id: String) -> MapsRow.Status { rows.listed.first { $0.id == id }!.status }
        func action(_ id: String) -> MapsRow.Action? { rows.listed.first { $0.id == id }!.action }
        #expect(state("region-a") == .installed && action("region-a") == nil)
        #expect(state("region-b") == .updateAvailable && action("region-b") == .update)
        #expect(state("region-c") == .removalPending && action("region-c") == .downloadAgain, "B5: bring it back")
        #expect(state("national") == .failed("truncated") && action("national") == nil)
        #expect(Self.rows().listed.allSatisfy { $0.status == .notInstalled && $0.action == .download })
        #expect(rows.listed.first { $0.id == "region-c" }?.canRemove == false)
        #expect(rows.listed.first { $0.id == "region-a" }?.canRemove == true)
    }

    @Test("A live file wins over a pending-removal one of the same name")
    func liveWins() {
        let rows = Self.rows(installed: [.preview("region-a", hash: "a1b2c3d4", pending: true),
                                         .preview("region-a", hash: "a1b2c3d4")])
        #expect(rows.listed.first { $0.id == "region-a" }?.status == .installed)
    }

    @Test("Download states and their actions")
    func downloadStates() {
        let snapshot = PackDownloader.Snapshot(states: [
            "national": .queued, "region-a": .downloading(received: 42, total: 100),
            "region-b": .failed("checksum mismatch"), "region-c": .waitingForWiFi,
        ])
        let rows = Self.rows(downloads: snapshot)
        func row(_ id: String) -> MapsRow { rows.listed.first { $0.id == id }! }
        #expect(row("national").status == .queued && row("national").action == .cancel)
        #expect(row("region-a").status == .downloading(percent: 42) && row("region-a").action == .cancel)
        #expect(row("region-b").status == .failed("checksum mismatch") && row("region-b").action == .download)
        #expect(row("region-c").status == .waitingForWiFi && row("region-c").action == .cancel)
        // A failed update of an installed pack retries as Update.
        let update = Self.rows(installed: [.preview("region-b", hash: "00000001")], downloads: snapshot)
        #expect(update.listed.first { $0.id == "region-b" }?.action == .update)
        // Verifying and paused.
        let more = Self.rows(downloads: .init(states: ["region-a": .verifying, "region-b": .pausedForRecording,
                                                       "region-c": .offline]))
        #expect(more.listed.first { $0.id == "region-a" }?.status == .verifying)
        #expect(more.listed.first { $0.id == "region-a" }?.action == nil)
        #expect(more.listed.first { $0.id == "region-b" }?.action == .cancel)
        #expect(more.listed.first { $0.id == "region-c" }?.status == .offline)
    }

    @Test("An update installed during a run says it is used from the next start")
    func updatedNextStart() {
        let snapshot = PackDownloader.Snapshot(states: [:], updatedForNextStart: ["region-a"])
        let rows = Self.rows(installed: [.preview("region-a", hash: "a1b2c3d4")], downloads: snapshot)
        #expect(rows.listed.first { $0.id == "region-a" }?.status == .updatedNextStart)
        #expect(MapsText.stateText(.updatedNextStart) == "Updated · used from the next start")
    }

    @Test("Texts: secondary line is size · OSM date (manifest timestamp) · state")
    func texts() {
        let rows = Self.rows(downloads: .init(states: ["region-a": .downloading(received: 1, total: 4)]))
        let row = rows.listed.first { $0.id == "region-a" }!
        #expect(MapsText.detail(row) == "31.0 MB · OSM 2025-10-09 · Downloading 25%")
        #expect(MapsText.stateText(.notInstalled) == "Not installed")
        #expect(MapsText.stateText(.queued) == "Queued")
        #expect(MapsText.stateText(.waitingForWiFi) == "Waiting for Wi-Fi")
        #expect(MapsText.stateText(.pausedForRecording) == "Paused (recording)")
        #expect(MapsText.stateText(.verifying) == "Verifying")
        #expect(MapsText.stateText(.installed) == "Installed")
        #expect(MapsText.stateText(.failed("x")) == "Failed: x")
        #expect(MapsText.stateText(.removalPending) == "Removal pending")
        #expect(MapsText.stateText(.updateAvailable).hasPrefix("Update available"))
        #expect(MapsText.percent(received: 1, total: 3) == 33)
        #expect(MapsText.percent(received: 5, total: 3) == 100)
        #expect(MapsText.percent(received: 1, total: 0) == 0)
        #expect(MapsText.tone(.failed("x")) == .bad && MapsText.tone(.installed) == .good)
        #expect(MapsText.actionLabel(.cancel, title: "Zulu") == "Cancel download of Zulu")
    }

    @Test("Offline note follows the connection even with a fresh cache (R66.1-2)")
    func offlineFromConnection() {
        // A fresh cache means no fetch and so no failed refresh: the note must still show.
        #expect(MapsText.listNote(.idle, connection: .none, hasManifest: true) == "Showing the saved list.")
        #expect(MapsText.listNote(.ok, connection: .none, hasManifest: true) == "Showing the saved list.")
        #expect(MapsText.listNote(.ok, connection: .none, hasManifest: false) == nil, "the top line already says Offline")
        #expect(MapsText.listNote(.ok, connection: .unmetered, hasManifest: true) == nil)
        #expect(MapsText.listNote(.idle, connection: .cellular, hasManifest: true) == nil)
        // A failed fetch on a live connection still says the update failed; offline wins when both hold.
        #expect(MapsText.listNote(.failed(offline: false), connection: .unmetered, hasManifest: true)
                == "Couldn't update the list. Showing the saved list.")
        #expect(MapsText.listNote(.failed(offline: false), connection: .none, hasManifest: true)
                == "Showing the saved list.")
    }

    @MainActor
    @Test("The Maps model takes the connection from the downloader snapshot")
    func modelOffline() {
        let status = RoadPackLibrary.Status(packs: [], scansCompleted: 1, storeBytes: 0)
        let offline = MapsModel(status: status, manifest: Self.manifest,
                                downloads: .init(connection: .none), refresh: .ok)
        #expect(offline.listNote == "Showing the saved list.")
        #expect(MapsText.networkLine(connection: .none, cellularAllowed: false).text == "Offline")
        let online = MapsModel(status: status, manifest: Self.manifest, downloads: .init(), refresh: .ok)
        #expect(online.listNote == nil)
    }

    @Test("Remove confirmation names the pack by its title")
    func confirmation() {
        let row = Self.rows(installed: [.preview("region-a", bytes: 48_000_000, hash: "a1b2c3d4")]).listed
            .first { $0.id == "region-a" }!
        #expect(MapsText.confirmationTitle(row) == "Remove Zulu?")
        #expect(MapsText.confirmationMessage(row) == "Frees 48.0 MB. Recordings are not affected.")
    }
}

// MARK: - Developer diagnostics gate

@Suite("Developer diagnostics gate")
@MainActor
struct DeveloperGateTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "gate-\(UUID().uuidString)")!
    }

    @Test("Counter: seven consecutive quick taps complete a run; a slow tap starts again")
    func counter() {
        func at(_ seconds: Double) -> Date { Self.t0.addingTimeInterval(seconds) }
        var counter = TapCounter()
        var done = false
        for i in 0..<6 { done = counter.tap(at: at(Double(i) * 0.5)); #expect(!done) }
        done = counter.tap(at: at(3.0))
        #expect(done && counter.count == 0)
        // A 2 s gap resets to 1.
        var slow = TapCounter()
        for i in 0..<5 { _ = slow.tap(at: at(Double(i) * 0.2)) }
        #expect(slow.count == 5)
        done = slow.tap(at: at(0.8 + 2.0))
        #expect(!done && slow.count == 1)
        for i in 1..<6 { done = slow.tap(at: at(2.8 + Double(i) * 0.2)); #expect(!done) }
        done = slow.tap(at: at(2.8 + 1.2))
        #expect(done)
        // Exactly 1.5 s apart still counts.
        var edge = TapCounter()
        _ = edge.tap(at: at(0))
        _ = edge.tap(at: at(1.5))
        #expect(edge.count == 2)
    }

    @Test("DEBUG always shows the developer rows")
    func debug() {
        let gate = DeveloperGate(isDebug: true, defaults: defaults())
        #expect(gate.showsDiagnostics)
        for i in 0..<14 { gate.tapVersion(at: Self.t0.addingTimeInterval(Double(i) * 0.1)) }
        #expect(gate.showsDiagnostics && gate.toast == nil)
    }

    @Test("Release: locked; 7 taps show them (and say so); 7 more hide them; a slow tap does not count")
    func release() {
        let store = defaults()
        let gate = DeveloperGate(isDebug: false, defaults: store)
        #expect(!gate.showsDiagnostics)
        for i in 0..<6 { gate.tapVersion(at: Self.t0.addingTimeInterval(Double(i) * 0.3)) }
        gate.tapVersion(at: Self.t0.addingTimeInterval(5))   // too slow: starts again
        #expect(!gate.showsDiagnostics)
        for i in 1..<7 { gate.tapVersion(at: Self.t0.addingTimeInterval(5 + Double(i) * 0.3)) }
        #expect(gate.showsDiagnostics && gate.toast == "Developer diagnostics shown")
        #expect(DeveloperGate(isDebug: false, defaults: store).showsDiagnostics, "kept per install")
        for i in 0..<7 { gate.tapVersion(at: Self.t0.addingTimeInterval(20 + Double(i) * 0.3)) }
        #expect(!gate.showsDiagnostics && gate.toast == "Developer diagnostics hidden")
        #expect(!DeveloperGate(isDebug: false, defaults: store).showsDiagnostics)
    }
}
