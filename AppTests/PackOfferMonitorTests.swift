import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// UX-8 (2) at-a-stop offer wiring: one rule per drive, the inputs the
// monitor supplies (installed, manifest, excluded incl. queued, Never), the
// persisted Never set and its reset. Synthetic names, boxes near (0, 0).

/// What the monitor's sources answer; counts the reads.
final class OfferSourcesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _installed: [InstalledPackCoverage] = []
    private var _packs: [PackManifest.Pack]
    private var _active: Set<String> = []
    private var _downloads: [String] = []
    private var _reads = 0

    init(packs: [PackManifest.Pack]) { _packs = packs }

    var installed: [InstalledPackCoverage] {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }
    var active: Set<String> {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }
    var downloads: [String] { lock.withLock { _downloads } }
    var reads: Int { lock.withLock { _reads } }

    var sources: PackOfferMonitor.Sources {
        PackOfferMonitor.Sources(
            installed: { self.lock.withLock { self._reads += 1; return self._installed } },
            manifestPacks: { self.lock.withLock { self._packs } },
            activeDownloads: { self.lock.withLock { self._active } },
            download: { pack in self.lock.withLock { self._downloads.append(pack.name) } })
    }
}

enum OfferFixture {
    static func pack(_ name: String, _ kind: PackManifest.Pack.Kind = .region, bbox: [Double], size: Int64 = 1_000)
        -> PackManifest.Pack {
        PackManifest.Pack(
            name: name, kind: kind, titleUK: "Uk \(name)", titleEN: "En \(name)",
            bbox: .init(west: bbox[0], south: bbox[1], east: bbox[2], north: bbox[3]),
            url: URL(string: "https://stub.invalid/\(name).roadpack")!, size: size,
            sha256: String(repeating: "a", count: 64), contentHash: "0123456789abcdef", formatVersion: 1,
            osmDate: nil, osmTimestamp: 0)
    }

    static let packs = [
        pack("zz-national", .national, bbox: [0, 0, 4, 3]),
        pack("zz-01", bbox: [0, 0, 1, 1]),
        pack("zz-02", bbox: [1, 0, 2, 1], size: 2_000),
    ]

    static func box(_ b: [Double]) -> RoadPackCoverage {
        RoadPackCoverage(rings: nil, bounds: RoadPackBounds(southLatE7: Int32(b[1] * 1e7), westLonE7: Int32(b[0] * 1e7),
                                                            northLatE7: Int32(b[3] * 1e7), eastLonE7: Int32(b[2] * 1e7)))
    }

    /// National (ignored by the rule) and zz-01 installed.
    static let installed = [
        InstalledPackCoverage(name: "zz-national", coverage: box([0, 0, 4, 3])),
        InstalledPackCoverage(name: "zz-01", coverage: box([0, 0, 1, 1])),
    ]

    static let inZZ02 = PackOfferRule.Estimate(latitude: 0.3, longitude: 1.7, semiMajorM: 300)
    static let inZZ01 = PackOfferRule.Estimate(latitude: 0.5, longitude: 0.5, semiMajorM: 50)
}

@MainActor
final class RunFlag {
    var value = false
}

@MainActor
extension PackOfferMonitor {
    /// 1 Hz updates over `range`; whether an offer was up at any step.
    @discardableResult
    func drive(_ range: ClosedRange<Int>, _ estimate: PackOfferRule.Estimate?, speed: Double?, run: Bool = true,
               dialog: Bool = false) -> [String?] {
        range.map {
            update(now: Double($0), runActive: run, estimate: estimate, speedKmh: speed, dialogOpen: dialog)
            return offer?.name
        }
    }
}

@Suite("Pack offer monitor (UX-8 at a stop)")
@MainActor
struct PackOfferMonitorTests {
    typealias F = OfferFixture

    static func make(_ box: OfferSourcesBox, defaults: FirstLaunchFixture.Defaults,
                     config: PackOfferRule.Config = .default) -> PackOfferMonitor {
        PackOfferMonitor(sources: box.sources, neverStore: PackOfferNeverStore(defaults: defaults.defaults),
                         config: config, preferredLanguages: { ["en"] })
    }

    @Test("Outside coverage, at a stop: one offer per region per drive; a new drive (after a gap) may offer it again")
    func perDrive() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        box.installed = F.installed
        let monitor = Self.make(box, defaults: defaults)
        await monitor.refreshInputs()
        #expect(monitor.excluded == ["zz-national", "zz-01"], "installed packs are excluded")

        #expect(monitor.drive(0...40, F.inZZ02, speed: 50).allSatisfy { $0 == nil }, "never in motion")
        #expect(monitor.drives == 1)
        let stop = monitor.drive(41...44, F.inZZ02, speed: 0)
        #expect(stop.last == "zz-02")
        #expect(monitor.offer == PackOfferMonitor.Offer(name: "zz-02", title: "En zz-02", sizeBytes: 2_000))
        monitor.notNow()
        #expect(monitor.offer == nil)
        monitor.drive(45...60, F.inZZ02, speed: 50)
        #expect(monitor.drive(61...70, F.inZZ02, speed: 0).allSatisfy { $0 == nil }, "once per drive")

        // A tick with no run ends the drive; Navigate → Record without a gap would not.
        monitor.update(now: 71, runActive: false, estimate: F.inZZ02, speedKmh: 0, dialogOpen: false)
        #expect(monitor.rule == nil && monitor.offer == nil)
        monitor.drive(72...110, F.inZZ02, speed: 50)
        #expect(monitor.drives == 2)
        #expect(monitor.drive(111...115, F.inZZ02, speed: 0).last == "zz-02", "a new drive offers it again")
    }

    @Test("Runs that follow each other without a gap are one drive: the rule and its 'offered' set survive")
    func handoff() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        let monitor = Self.make(box, defaults: defaults)
        await monitor.refreshInputs()
        monitor.drive(0...30, F.inZZ02, speed: 50)
        #expect(monitor.drive(31...34, F.inZZ02, speed: 0).last == "zz-02")
        monitor.notNow()
        // (Navigate ends, Record starts: `hasActiveRun` holds throughout.)
        monitor.drive(35...80, F.inZZ02, speed: 50)
        #expect(monitor.drive(81...90, F.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(monitor.drives == 1)
    }

    @Test("Not active outside a run: nothing offered, no rule")
    func outsideRun() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        let monitor = Self.make(box, defaults: defaults)
        await monitor.refreshInputs()
        #expect(monitor.drive(0...100, F.inZZ02, speed: 0, run: false).allSatisfy { $0 == nil })
        #expect(monitor.rule == nil && monitor.drives == 0)
    }

    @Test("Never is persisted (names only), survives a new monitor, is respected in a new drive, and resets")
    func never() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        let monitor = Self.make(box, defaults: defaults)
        await monitor.refreshInputs()
        monitor.drive(0...30, F.inZZ02, speed: 50)
        #expect(monitor.drive(31...34, F.inZZ02, speed: 0).last == "zz-02")
        monitor.never()
        #expect(monitor.offer == nil && monitor.neverNames == ["zz-02"])
        #expect(defaults.stored as? [String: [String]] == [PackOfferNeverStore.key: ["zz-02"]], "only pack names are stored")

        let next = Self.make(box, defaults: defaults)
        #expect(next.neverNames == ["zz-02"])
        await next.refreshInputs()
        next.drive(0...40, F.inZZ02, speed: 50)
        #expect(next.drive(41...50, F.inZZ02, speed: 0).allSatisfy { $0 == nil }, "Never holds across drives")

        next.resetNever("zz-02")
        #expect(next.neverNames.isEmpty && PackOfferNeverStore(defaults: defaults.defaults).names.isEmpty)
        next.update(now: 51, runActive: false, estimate: nil, speedKmh: nil, dialogOpen: false)
        next.drive(52...90, F.inZZ02, speed: 50)
        #expect(next.drive(91...95, F.inZZ02, speed: 0).last == "zz-02", "offered again after the reset")

        let store = PackOfferNeverStore(defaults: defaults.defaults)
        store.add("zz-01")
        store.add("zz-02")
        let third = Self.make(box, defaults: defaults)
        #expect(third.neverNames == ["zz-01", "zz-02"])
        third.resetAllNever()
        #expect(third.neverNames.isEmpty && store.names.isEmpty && defaults.stored.isEmpty)
    }

    @Test("Excluded includes queued: a pack queued in the downloader is never offered; Download from the card queues it at once")
    func queuedExcluded() async throws {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let downloader = env.downloader(connection: .none)
        let sources = PackOfferMonitor.Sources(
            installed: { [] }, manifestPacks: { F.packs },
            activeDownloads: { await downloader.activeNames() }, download: { await downloader.start($0) })
        let monitor = PackOfferMonitor(sources: sources, neverStore: PackOfferNeverStore(defaults: defaults.defaults),
                                       preferredLanguages: { ["en"] })

        await downloader.start(F.packs[2])   // zz-02 queued (offline)
        await monitor.refreshInputs()
        #expect(monitor.excluded.contains("zz-02"))
        monitor.drive(0...40, F.inZZ02, speed: 50)
        #expect(monitor.drive(41...50, F.inZZ02, speed: 0).allSatisfy { $0 == nil })

        // zz-01 (not installed here) is offered; Download queues it.
        monitor.update(now: 51, runActive: false, estimate: nil, speedKmh: nil, dialogOpen: false)
        monitor.drive(52...90, F.inZZ01, speed: 50)
        #expect(monitor.drive(91...95, F.inZZ01, speed: 0).last == "zz-01")
        await monitor.download()
        #expect(monitor.offer == nil)
        #expect(monitor.excluded.contains("zz-01"), "excluded at once, before the next refresh")
        #expect(await downloader.activeNames() == ["zz-01", "zz-02"])
        #expect(await downloader.snapshot().states["zz-01"] == .offline, "the download policy applies")
    }

    @Test("The loop: no card while the map is hidden (and it does not count as shown); inputs are read only during a run")
    func loop() async {
        let defaults = FirstLaunchFixture.Defaults()
        defer { defaults.remove() }
        let box = OfferSourcesBox(packs: F.packs)
        let monitor = Self.make(box, defaults: defaults,
                                config: PackOfferRule.Config(outsideS: 0.05, stopS: 0.05))
        let runActive = RunFlag()
        let live = PackOfferMonitor.LiveInputs(runActive: { runActive.value }, estimate: { F.inZZ02 }, speedKmh: { 0 })
        let task = Task { await monitor.run(live: live, tick: .milliseconds(10)) }
        defer { task.cancel() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(box.reads == 0 && monitor.offer == nil, "no run: nothing read")
        runActive.value = true
        monitor.isMapVisible = false
        try? await Task.sleep(for: .milliseconds(300))
        #expect(box.reads > 0)
        #expect(monitor.offer == nil && monitor.rule?.offered.isEmpty == true)
        monitor.isMapVisible = true
        #expect(await eventually { monitor.offer?.name == "zz-02" })
        monitor.isDialogOpen = true
        #expect(await eventually { monitor.offer == nil }, "a dialog hides it")
    }
}
