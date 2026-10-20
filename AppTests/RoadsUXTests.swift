import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Prompt 38, items B3-B5 and C6-C7: the roads banner's Download, the "only main
// roads" offer, Remove during a run, "Finding your position", the matched road
// line. Synthetic names and positions only.

@Suite("Roads banner Download and the only-main-roads offer (B3, B4)")
@MainActor
struct RoadsBannerDownloadTests {
    typealias F = OfferFixture

    private func offer(_ context: PackOfferMonitor.Offer.Context = .noRoadMap) -> PackOfferMonitor.Offer {
        PackOfferMonitor.Offer(name: "zz-02", title: "Region A", sizeBytes: 35_000_000, context: context)
    }

    @Test("The banner offers Download only for the two fixable warnings, and only with an offer")
    func bannerMatrix() {
        for message in [RoadsWarning.noneCovering, RoadsWarning.noPacks] {
            let shown = RoadsWarningOffer.make(message: message, offer: offer(), downloadingTitle: nil, recording: false)
            #expect(shown?.state == .offer && shown?.title == "Region A")
            #expect(RoadsWarningOffer.hostsOffer(shown), "the banner hosts it: the card steps aside")
            #expect(RoadsWarningOffer.make(message: message, offer: nil, downloadingTitle: nil, recording: false) == nil,
                    "no region known, or the car is moving: no button")
        }
        for message in [RoadsWarning.refused, nil] {
            #expect(RoadsWarningOffer.make(message: message, offer: offer(), downloadingTitle: nil, recording: false) == nil,
                    "refused packs and no warning: the plain card, not the banner")
        }
        #expect(!RoadsWarningOffer.hostsOffer(nil))
    }

    @Test("After the tap the banner says it is downloading, without a button; the card does not come back for it")
    func queued() {
        let queued = RoadsWarningOffer.make(
            message: RoadsWarning.noneCovering, offer: nil, downloadingTitle: "Region A", recording: false)
        #expect(queued?.state == .queued)
        #expect(queued?.queuedText == "Downloading Region A\u{2026}")
        #expect(!RoadsWarningOffer.hostsOffer(queued))
    }

    @Test("During Record the button and the line say the download waits for the recording to end")
    func recordingWording() {
        let offerState = RoadsWarningOffer.make(
            message: RoadsWarning.noneCovering, offer: offer(), downloadingTitle: nil, recording: true)
        #expect(offerState?.buttonText == "Download Region A after recording")
        let idle = RoadsWarningOffer.make(
            message: RoadsWarning.noneCovering, offer: offer(), downloadingTitle: nil, recording: false)
        #expect(idle?.buttonText == "Download Region A")
        let queued = RoadsWarningOffer.make(
            message: RoadsWarning.noPacks, offer: nil, downloadingTitle: "Region A", recording: true)
        #expect(queued?.queuedText == "Region A downloads after the recording")
    }

    @Test("Offer wording: only main roads names the region on the button; no road map keeps the old card")
    func offerText() {
        #expect(PackOfferText.summary(sizeBytes: 35_000_000, context: .noRoadMap) == "No road map here \u{00B7} 35.0 MB")
        #expect(PackOfferText.summary(sizeBytes: 35_000_000, context: .onlyMainRoads) == "Only main roads here \u{00B7} 35.0 MB")
        #expect(PackOfferText.downloadLabel(title: "Region A", context: .onlyMainRoads) == "Download Region A")
        #expect(PackOfferText.downloadLabel(title: "Region A", context: .noRoadMap) == "Download")
        #expect(PackOfferText.summary(title: "Region A", sizeBytes: 1_000_000, context: .noRoadMap)
                == PackOfferText.summary(title: "Region A", sizeBytes: 1_000_000))
    }

    @Test("Context: only the national pack in use is 'only main roads'; no roads or a region pack is not")
    func context() {
        let packs = F.packs
        #expect(PackOfferContext.make(sessionPackNames: [], manifestPacks: packs) == .noRoadMap)
        #expect(PackOfferContext.make(sessionPackNames: ["zz-national"], manifestPacks: packs) == .onlyMainRoads)
        #expect(PackOfferContext.make(sessionPackNames: ["zz-national", "zz-01"], manifestPacks: packs) == .noRoadMap)
        #expect(PackOfferContext.make(sessionPackNames: ["zz-01"], manifestPacks: packs) == .noRoadMap)
        #expect(PackOfferContext.make(sessionPackNames: ["dev-pack"], manifestPacks: packs) == .noRoadMap,
                "a pack the manifest does not list is not known to be national")
        #expect(PackOfferContext.make(sessionPackNames: ["zz-national"], manifestPacks: []) == .noRoadMap)
    }

    @Test("The loop gives the offer the session's roads; Download names the region until the drive ends")
    func monitorFlow() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        box.installed = [InstalledPackCoverage(name: "zz-national", coverage: F.box([0, 0, 4, 3]))]
        let monitor = PackOfferMonitorTests.make(
            box, defaults: defaults, config: PackOfferRule.Config(outsideS: 0.05, stopS: 0.05))
        monitor.isMapVisible = true
        let live = PackOfferMonitor.LiveInputs(
            runActive: { true }, estimate: { F.inZZ02 }, speedKmh: { 0 }, roadPackNames: { ["zz-national"] })
        let task = Task { await monitor.run(live: live, tick: .milliseconds(10)) }
        defer { task.cancel() }
        #expect(await eventually { monitor.offer?.name == "zz-02" })
        #expect(monitor.offer?.context == .onlyMainRoads)
        #expect(monitor.downloadingTitle == nil)

        await monitor.download()?.value
        #expect(monitor.offer == nil)
        #expect(monitor.downloadingTitle == "En zz-02", "the banner can say it is downloading")
        #expect(box.downloads == ["zz-02"])
        task.cancel()
        monitor.update(now: 1_000, runActive: false, estimate: nil, speedKmh: nil, dialogOpen: false)
        #expect(monitor.downloadingTitle == nil, "the drive ended")
    }

    @Test("No roads in use: the offer keeps the 'no road map' wording")
    func noRoadsContext() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        let monitor = PackOfferMonitorTests.make(box, defaults: defaults)
        await monitor.refreshInputs()
        monitor.drive(0...40, F.inZZ02, speed: 50)
        monitor.drive(41...44, F.inZZ02, speed: 0)
        #expect(monitor.offer?.context == .noRoadMap)
    }
}

@Suite("Remove during a session and Download again (B5)", .serialized)
@MainActor
struct RemoveDuringRunTests {
    private func row(pending: Bool = false, hasPack: Bool = true) -> MapsRow {
        let manifest = hasPack ? MapsRowsTests.manifest : nil
        let rows = MapsRowsTests.rows(installed: [.preview("region-a", bytes: 48_000_000, hash: "a1b2c3d4", pending: pending)],
                                      manifest: manifest)
        return (rows.listed + rows.other).first { $0.id == "region-a" }!
    }

    @Test("The confirmation warns that navigation runs without the map, only while a run is active")
    func warning() {
        let r = row()
        #expect(MapsText.confirmationMessage(r, runActive: true)
                == "Navigation will run without this map until you restart the app. Frees 48.0 MB. Recordings are not affected.")
        #expect(MapsText.confirmationMessage(r, runActive: false) == "Frees 48.0 MB. Recordings are not affected.")
        #expect(MapsText.confirmationMessage(r) == MapsText.confirmationMessage(r, runActive: false))
        #expect(MapsText.removeDuringRunWarning == "Navigation will run without this map until you restart the app.")
    }

    @Test("A pack in removal pending offers Download again instead of no action")
    func downloadAgainAction() {
        let pending = row(pending: true)
        #expect(pending.status == .removalPending)
        #expect(pending.action == .downloadAgain)
        #expect(!pending.canRemove, "Remove is not offered twice")
        #expect(MapsText.actionLabel(.downloadAgain, title: "Zulu") == "Download Zulu again")
        #expect(MapsText.downloadAgain == "Download again")
        // Not in the manifest: only when the app can clear the mark itself.
        #expect(row(pending: true, hasPack: false).action == nil)
        let restorable = MapsText.rows(
            manifest: nil, installed: [.preview("region-a", pending: true)], downloads: .init(),
            preferredLanguages: ["en"], locale: Locale(identifier: "en_US"), canRestore: true)
        #expect(restorable.listed.first?.action == .downloadAgain)
        // The other states are unchanged.
        #expect(MapsText.action(status: .installed, hasPack: true, hasInstalled: true, downloadFailed: false) == nil)
        #expect(MapsText.action(status: .notInstalled, hasPack: true, hasInstalled: false, downloadFailed: false) == .download)
    }

    @Test("Download again clears the mark through the hook, no restart, no download")
    func clearsMark() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let source = try RoadPackFixture.write(try RoadPackFixture.data(), named: "c.roadpack", in: dirs.sources)
        _ = try #require(store.installer.install(from: source, name: "region-a").installed)
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        await library.setRunActivity { true }
        _ = await library.candidates()
        let cleared = ClearedNames()
        let model = MapsModel(
            library: library, runActive: { true },
            cancelRemoval: { name in await cleared.add(name); return true })
        #expect(model.runActive)
        await model.refresh()
        let listed = try #require(model.status.installedPacks.first)
        await model.remove(listed)
        let pending = try #require(model.rows.all.first { $0.id == "region-a" })
        #expect(pending.status == .removalPending && pending.action == .downloadAgain)

        await model.perform(.downloadAgain, on: pending)
        #expect(await cleared.names == ["region-a"])
    }
}

private actor ClearedNames {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

@Suite("Finding your position (C6)")
struct PositionStatusTests {
    private func nav(converged: Bool, semiMajorM: Double) -> NavDisplay {
        NavDisplay(
            position: GeoPoint(latitude: 0.001, longitude: 0.001), semiMajorM: semiMajorM, semiMinorM: semiMajorM / 2,
            orientationDeg: 0, headingDeg: converged ? 90 : nil, converged: converged)
    }

    @Test("Shown while not converged or wider than 1 km; hidden once converged and within 1 km")
    func rule() {
        #expect(PositionStatus.isFinding(nav(converged: false, semiMajorM: 40)), "no direction yet")
        #expect(PositionStatus.isFinding(nav(converged: true, semiMajorM: 1_000.5)), "roads not engaged")
        #expect(PositionStatus.isFinding(nav(converged: false, semiMajorM: 3_000)))
        #expect(!PositionStatus.isFinding(nav(converged: true, semiMajorM: 1_000)), "exactly 1 km is within")
        #expect(!PositionStatus.isFinding(nav(converged: true, semiMajorM: 12)))
        #expect(!PositionStatus.isFinding(nil), "no estimate: nothing to say")
        #expect(PositionStatus.line(nav(converged: true, semiMajorM: 12)) == nil)
    }

    @Test("The wording asks only to keep driving; it never tells the driver to touch the phone")
    func wording() {
        #expect(PositionStatus.text == "Finding your position\u{2026} \u{00B7} keep driving")
        let lower = PositionStatus.text.lowercased()
        for word in ["tap", "touch", "pin", "press", "double"] { #expect(!lower.contains(word)) }
    }

    @Test("It sits between the Navigate status and the roads warning in the bottom zone")
    func zoneOrder() {
        let items = MapBottomZone.items(
            offer: true, toast: false, status: true, positionStatus: true, roadsWarning: true, resumeHint: false,
            debugSetting: true)
        #expect(items == [.offerCard, .statusLine, .positionStatus, .roadsWarning, .debugStrip])
        let without = MapBottomZone.items(
            offer: false, toast: false, status: false, roadsWarning: false, resumeHint: false, debugSetting: false)
        #expect(without.isEmpty, "off by default: existing callers are unchanged")
    }
}

@Suite("Matched road line (C7)")
struct MatchedRoadLineTests {
    private let edge = [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0.0001, longitude: 0.0001)]

    @Test("Drawn from an on-road share of 0.9, not below; needs two points")
    func threshold() {
        #expect(MatchedRoadLine.edge(points: edge, onRoadShare: 0.9) != nil)
        #expect(MatchedRoadLine.edge(points: edge, onRoadShare: 1.0) != nil)
        #expect(MatchedRoadLine.edge(points: edge, onRoadShare: 0.89) == nil)
        #expect(MatchedRoadLine.edge(points: edge, onRoadShare: nil) == nil, "no roads: nothing")
        #expect(MatchedRoadLine.edge(points: edge, onRoadShare: .nan) == nil)
        #expect(MatchedRoadLine.edge(points: [edge[0]], onRoadShare: 1) == nil)
        #expect(MatchedRoadLine.edge(points: [], onRoadShare: 1) == nil)
    }

    @Test("Explicit colours per scheme, thin and translucent, and neither blue nor orange")
    func look() {
        let light = MatchedRoadLine.rgb(dark: false), dark = MatchedRoadLine.rgb(dark: true)
        #expect(light != dark, "own colour for each scheme (MapKit overlays ignore dynamic colours)")
        for c in [light, dark] {
            #expect(c.a < 1 && c.a > 0.4, "subtle but readable")
            #expect(!(c.b > c.g && c.b > c.r), "never the ellipse's or a route's blue")
            #expect(!(c.r > 200 && c.g < 170 && c.b < 60), "not the debug strip's orange")
        }
        #expect(light.luminance < dark.luminance, "dark line on the light map, pale on the dark")
        #expect(MatchedRoadLine.lineWidth <= 3 && MatchedRoadLine.lineWidth < 5, "thinner than the track line")
    }
}
