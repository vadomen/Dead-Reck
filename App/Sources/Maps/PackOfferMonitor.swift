import DriveLoggerCore
import Foundation
import Observation

/// "Never for this region" (UX-8 (2)): a UserDefaults set of pack names,
/// nothing else. Settings → Maps lists and resets it.
struct PackOfferNeverStore {
    static let key = "maps.offerNever"

    var defaults: UserDefaults = .standard

    var names: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func add(_ name: String) { write(names.union([name])) }

    func reset(_ name: String) { write(names.subtracting([name])) }

    func resetAll() { defaults.removeObject(forKey: Self.key) }

    private func write(_ value: Set<String>) {
        if value.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(value.sorted(), forKey: Self.key) }
    }
}

/// The at-a-stop road-pack offer (UX-8 (2), docs/BACKLOG_UX.md): "You are in
/// <region>, no road map. Download <size>?" Owns one Core `PackOfferRule`
/// per drive and supplies everything the rule reads but the live values.
///
/// **A drive** is a maximal span in which a Navigate or Record run is
/// active (`RecordingSession.hasActiveRun`). Runs that follow each other
/// without a gap are ONE drive: Start ends Navigate while `isStarting`
/// already holds `hasActiveRun`, and a recording's end starts Navigate in
/// the same main-actor step, so Navigate → Record → Navigate within a trip
/// keeps the rule: a region answered in Navigate is not offered again once
/// Record starts, and its unanswered shows (at most 3 per drive) carry over.
/// Any update that sees no run ends the drive: the next run gets a fresh
/// rule (a region may be offered again, unless "Never").
///
/// **Inputs it supplies** (refreshed every tick while a run is active;
/// each is an actor hop and a copy): installed coverages
/// (`RoadPackLibrary.coverages()`, so an install or removal is seen within
/// a tick), the cached manifest's packs (never fetched here), the excluded
/// names (installed + queued/running/paused in `PackDownloader`, + any
/// queued from the card) and the persisted "Never" set.
///
/// **Not active outside a run**: `offer` is nil and no input is read.
/// Nothing is written to the recording or the sidecar; the estimate and
/// the speed are read, never kept beyond the rule's own timers.
@MainActor
@Observable
final class PackOfferMonitor {
    /// The card's content.
    struct Offer: Identifiable, Hashable, Sendable {
        var id: String { name }
        var name: String
        /// In the app language.
        var title: String
        var sizeBytes: Int64
    }

    /// The async inputs (the app's actors; tests pass their own).
    struct Sources: Sendable {
        var installed: @Sendable () async -> [InstalledPackCoverage]
        var manifestPacks: @Sendable () async -> [PackManifest.Pack]
        /// Queued, waiting, downloading, paused or verifying.
        var activeDownloads: @Sendable () async -> Set<String>
        var download: @Sendable (PackManifest.Pack) async -> Void
    }

    /// The live values the loop reads each tick (`run(live:)`).
    struct LiveInputs {
        var runActive: @MainActor () -> Bool
        /// The navigation estimate (never a raw fix); nil when none.
        var estimate: @MainActor () async -> PackOfferRule.Estimate?
        /// The map's speed readout (OBD first, then GPS), km/h.
        var speedKmh: @MainActor () -> Double?
    }

    private(set) var offer: Offer?
    /// The "Never" names, sorted (Settings → Maps).
    private(set) var neverNames: [String]
    /// The map is on screen and the scene active (the UI sets it): the card
    /// may only appear, and count as shown, while it is (hidden is passed
    /// to the rule as "dialog open", which never turns a card on).
    var isMapVisible = false
    /// A confirmation dialog is open on the map (the UI sets it).
    var isDialogOpen = false

    @ObservationIgnored private(set) var rule: PackOfferRule?
    /// Drives started since launch (tests).
    @ObservationIgnored private(set) var drives = 0
    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private let neverStore: PackOfferNeverStore
    @ObservationIgnored private let config: PackOfferRule.Config
    @ObservationIgnored private let preferredLanguages: @Sendable () -> [String]
    @ObservationIgnored private var installed: [InstalledPackCoverage] = []
    @ObservationIgnored private var manifestPacks: [PackManifest.Pack] = []
    @ObservationIgnored private var active: Set<String> = []
    /// Queued from the card in this drive (until the downloader lists it).
    @ObservationIgnored private var queuedHere: Set<String> = []

    init(sources: Sources, neverStore: PackOfferNeverStore = PackOfferNeverStore(),
         config: PackOfferRule.Config = .default,
         preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }) {
        self.sources = sources
        self.neverStore = neverStore
        self.config = config
        self.preferredLanguages = preferredLanguages
        neverNames = neverStore.names.sorted()
    }

    /// The app's sources.
    static func sources(library: RoadPackLibrary, manifest: PackManifestService, downloader: PackDownloader) -> Sources {
        Sources(
            installed: { await library.coverages() },
            manifestPacks: { await manifest.snapshot().manifest?.packs ?? [] },
            activeDownloads: { await downloader.activeNames() },
            download: { await downloader.start($0) })
    }

    /// The names the rule must not offer now.
    var excluded: Set<String> { Set(installed.map(\.name)).union(active).union(queuedHere) }

    // MARK: Ticking

    /// Re-reads the async inputs.
    func refreshInputs() async {
        let installed = await sources.installed()
        let packs = await sources.manifestPacks()
        let active = await sources.activeDownloads()
        self.installed = installed
        manifestPacks = packs
        self.active = active
        queuedHere.subtract(active)
    }

    /// One step. `now`: monotonic seconds (any origin, one per launch).
    /// `runActive` false ends the drive. `dialogOpen`: no card may appear
    /// (a dialog is open, or the map is not visible).
    func update(now: Double, runActive: Bool, estimate: PackOfferRule.Estimate?, speedKmh: Double?, dialogOpen: Bool) {
        guard runActive else {
            rule = nil
            if offer != nil { offer = nil }
            return
        }
        if rule == nil {
            rule = PackOfferRule(config: config)
            drives += 1
            queuedHere = []
        }
        let input = PackOfferRule.Input(
            now: now, estimate: estimate, speedKmh: speedKmh, dialogOpen: dialogOpen, installed: installed,
            manifestPacks: manifestPacks, excluded: excluded, never: neverStore.names)
        let pack = rule?.update(input)
        let next = pack.map { Offer(name: $0.name, title: $0.title(preferredLanguages: preferredLanguages()), sizeBytes: $0.size) }
        if next != offer { offer = next }
    }

    /// The loop: every `tick` (1 s; the rule's 3 s stop window needs
    /// ≥ 1 Hz) while the task lives, on any tab and in the background (the
    /// card cannot appear then: `isMapVisible` is false). Inputs are read
    /// only while a run is active.
    func run(live: LiveInputs, tick: Duration = .seconds(1)) async {
        let clock = ContinuousClock()
        let origin = clock.now
        while !Task.isCancelled {
            var estimate: PackOfferRule.Estimate?
            if live.runActive() {
                await refreshInputs()
                estimate = await live.estimate()
            }
            let elapsed = origin.duration(to: clock.now).components
            let now = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            update(now: now, runActive: live.runActive(), estimate: estimate, speedKmh: live.speedKmh(),
                   dialogOpen: isDialogOpen || !isMapVisible)
            try? await Task.sleep(for: tick)
        }
    }

    // MARK: Answers

    /// "Download": queued through the downloader (its network policy
    /// applies); answered, so not offered again in this drive.
    func download() async {
        guard let shown = offer, let pack = manifestPacks.first(where: { $0.name == shown.name }) else { return }
        rule?.answer(.download, region: shown.name)
        offer = nil
        queuedHere.insert(shown.name)
        await sources.download(pack)
    }

    /// "Not now": hidden for this drive.
    func notNow() {
        guard let shown = offer else { return }
        rule?.answer(.notNow, region: shown.name)
        offer = nil
    }

    /// "Never for this region": persisted; hidden for good.
    func never() {
        guard let shown = offer else { return }
        rule?.answer(.never, region: shown.name)
        neverStore.add(shown.name)
        neverNames = neverStore.names.sorted()
        offer = nil
    }

    // MARK: Settings → Maps

    func resetNever(_ name: String) {
        neverStore.reset(name)
        neverNames = neverStore.names.sorted()
    }

    func resetAllNever() {
        neverStore.resetAll()
        neverNames = []
    }
}

extension PackOfferRule.Estimate {
    /// The map's dead-reckoning estimate: centre and 95 % semi-major axis.
    init(_ nav: NavDisplay) {
        self.init(latitude: nav.position.latitude, longitude: nav.position.longitude, semiMajorM: nav.semiMajorM)
    }
}
