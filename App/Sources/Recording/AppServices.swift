import DriveLoggerCore
import Foundation
import UIKit

/// The services that live for the whole app run, created once at launch.
///
/// The link must exist at launch: CoreBluetooth state restoration only
/// reconnects to a central created with the same restore identifier during
/// `didFinishLaunching` (`OBDLinkService.restoreIdentifier`). The recording
/// session subscribes to the link's events in its `init`, so nothing the link
/// reports after launch is missed.
@MainActor
final class AppServices {
    let link: any OBDLinkServicing
    let sensors: SensorSuite
    let store: LogStore
    let session: RecordingSession
    /// Live dead reckoning for each recording (N4 B) and each Navigate
    /// session (UX-1): it consumes every feed and writes a recording's
    /// sidecar (none for Navigate).
    let navigation: NavigationService
    /// The road packs: the store in Application Support/RoadPacks (filled
    /// from the developer inbox Documents/RoadPacks at launch), verified
    /// once each.
    let roadPacks: RoadPackLibrary
    /// The road pack list (cached, fetched when Settings → Maps opens) and
    /// the downloads (UX-8). Record pauses downloads (Navigate does not):
    /// `RecordingSession.onRecordActiveChange` through `recordActivity`.
    let manifest: PackManifestService
    let downloader: PackDownloader
    /// The at-a-stop road-pack offer (UX-8 (2)); the UI runs its loop
    /// (`run(live: packOfferInputs(speedKmh:))`) and shows `offer`.
    let packOffers: PackOfferMonitor
    /// The demo drive (REL-DEMO): Navigate on a simulated car with the
    /// bundled demo pack, on its own session, link and navigation service;
    /// holds `session` and `link` while it runs. Writes nothing.
    let demo: DemoDriveController
    private let network = PackNetworkMonitor()
    private let recordActivity: RecordActivityRelay
    /// Path changes, in order, to the downloader (R66.1-8).
    private let pathRelay: OrderedRelay<PackPath>
    /// "Use cellular data" → downloader, every write, in order (UX-17).
    private let cellularSetting: CellularSettingObserver

    init(
        link: any OBDLinkServicing = OBDLinkFactory.makeDefault(),
        sensors: SensorSuite = .makeDefault()
    ) {
        self.link = link
        self.sensors = sensors
        // If Documents/logs can't be created now, `start` tries again and
        // reports the error then.
        store = (try? LogStore.documents()) ?? LogStore(directory: LogStore.defaultDirectory)
        var notes = [sensors.note]
        if link is SimulatedOBDLink {
            notes.append("Simulated OBD adapter (MockELMAdapter with the bench-car script).")
        }
        session = RecordingSession(
            link: link,
            sources: sensors.sources,
            displayLocation: sensors.displayLocation,
            store: store,
            sensorConfiguration: sensors.configuration,
            notes: notes.compactMap { $0 }.joined(separator: " ").nilIfEmpty
        )
        let roadPacks = RoadPackLibrary.makeDefault()
        self.roadPacks = roadPacks
        let navigation = NavigationService(library: roadPacks)
        self.navigation = navigation
        // Remove (Settings → Maps) deletes only when no run may have a pack
        // mapped: no recording or Navigate run in the session (starting
        // included) and none still draining in the navigation service.
        let session = session
        let runActivity: RoadPackLibrary.RunActivity = {
            if await session.hasActiveRun { return true }
            return await navigation.hasActiveRun
        }
        // The first scan runs launch maintenance (inbox install, cleanup)
        // and verification off the main actor at .utility; never awaited
        // here. Sessions map packs only via `candidates()`, which awaits it.
        Task(priority: .utility) {
            await roadPacks.setRunActivity(runActivity)
            await roadPacks.rescan()
        }
        let downloader = PackDownloader(
            directory: RoadPackStore.defaultDirectory(), library: roadPacks,
            cellularAllowed: UserDefaults.standard.bool(forKey: MapsSettings.cellularKey), runActive: runActivity)
        self.downloader = downloader
        // A fresh manifest cleans partials through the downloader (R66.1-7).
        let manifest = PackManifestService.makeDefault(downloader: downloader)
        self.manifest = manifest
        Task(priority: .utility) {
            await manifest.loadCache()
            // R67.1-7: a 404 to a pack forces one manifest refresh and takes the fresh entry.
            await downloader.setFreshEntry { name in
                await manifest.refresh(force: true)
                return await manifest.snapshot().manifest?.pack(named: name)
            }
        }
        packOffers = PackOfferMonitor(sources: PackOfferMonitor.sources(
            library: roadPacks, manifest: manifest, downloader: downloader))
        // R66.1-8: one task delivers every path change in order, so a quick
        // cellular → Wi-Fi pair can't reach the downloader reversed.
        let pathRelay = Self.pathRelay(to: downloader)
        self.pathRelay = pathRelay
        network.start { path in pathRelay.send(path) }
        cellularSetting = CellularSettingObserver(downloader: downloader)
        // UX-8: every Record-active change, in order, from the first line of
        // `start` to the end of the end path; one task delivers them, so a
        // quick true/false pair can't reach the downloader reversed.
        let recordActivity = RecordActivityRelay { active in await downloader.setRecordActive(active) }
        self.recordActivity = recordActivity
        session.onRecordActiveChange = { active in recordActivity.send(active) }
        // Synchronous inside `start`, before any row: only start the task.
        session.onNavigationFeed = { feed in navigation.start(feed) }
        // The sidecar is flushed with the log on background (R14.1-4).
        session.onFlush = { await navigation.flush() }
        // UX-1: Navigate runs whenever the link polls and Record doesn't.
        // After the feed hook is set, so the first session's feed is seen.
        session.enableNavigate()
        demo = DemoDriveController(session: session, link: link, packURL: DemoRoadPack.url(in: .main))
    }

    /// The navigation the map follows (REL-DEMO): the demo's while it has a
    /// run, else the app's. For `NavigationFeed(source:)`.
    nonisolated static func liveSnapshot(app: NavigationService, demo: NavigationService) -> NavigationFeed.Source {
        {
            if await demo.currentGeneration != nil { return await demo.snapshot() }
            return await app.snapshot()
        }
    }

    /// The path monitor's relay to the downloader (R66.1-8).
    nonisolated static func pathRelay(to downloader: PackDownloader) -> OrderedRelay<PackPath> {
        OrderedRelay { path in await downloader.setPath(path) }
    }

    /// The offer loop's live values: a run is active (Navigate or Record,
    /// starting included); the engine's estimate only when the map would
    /// show it (not without OBD, UX-1 (d)); the map's speed readout.
    func packOfferInputs(speedKmh: @escaping @MainActor () -> Double?) -> PackOfferMonitor.LiveInputs {
        let session = session
        let navigation = navigation
        return PackOfferMonitor.LiveInputs(
            runActive: { session.hasActiveRun },
            estimate: {
                let status = NavigateStatus.make(
                    navigate: session.navigateState, recording: session.state, startedAt: session.navigateStartedAt,
                    timings: session.navigateTimings ?? NavigateConfiguration(), now: .now)
                guard status.showsEstimate else { return nil }
                return NavDisplay(await navigation.snapshot()).map(PackOfferRule.Estimate.init)
            },
            speedKmh: speedKmh)
    }
}

/// Hands `RecordingSession.isRecordActive` changes to the road-pack
/// downloader (UX-8: downloads pause while Record is active; Navigate does
/// not pause them). See `OrderedRelay`.
typealias RecordActivityRelay = OrderedRelay<Bool>

/// Delivers values to an async consumer in the order sent (UX-8: the
/// Record-active signal, and the path monitor's connection, R66.1-8).
/// `send` is synchronous, never blocks and may be called from any thread
/// (the session calls it inside `start` before its first suspension; the
/// path monitor from its queue); one task delivers the values in the order
/// sent, each awaited before the next, so the consumer always ends on the
/// latest value (separate `Task`s per change could reach the actor in
/// either order).
final class OrderedRelay<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<Value>.Continuation
    private let task: Task<Void, Never>

    /// - Parameter deliver: called with each value, one at a time, in order.
    ///   Off the main actor, at `.userInitiated` so a pause is prompt (the
    ///   downloader's own I/O and hashing stay at `.utility`).
    init(deliver: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        self.continuation = continuation
        task = Task.detached(priority: .userInitiated) {
            for await value in stream { await deliver(value) }
        }
    }

    func send(_ value: Value) {
        continuation.yield(value)
    }

    deinit {
        continuation.finish()
    }
}

/// Which hardware produced a recording, for the header.
enum DeviceInfo {
    /// Model identifier (`iPhone16,1`, from `uname`; on the simulator
    /// `Simulator (iPhone16,1)`, so a simulated recording can't pass for a
    /// phone's sensor data), system name and version.
    @MainActor
    static func current() -> DeviceIdentity {
        DeviceIdentity(
            model: modelIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion
        )
    }

    nonisolated static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Simulator (\(simulated))"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
