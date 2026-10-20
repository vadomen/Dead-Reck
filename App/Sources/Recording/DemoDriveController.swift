import DriveLoggerCore
import Foundation
import Observation
import SwiftUI

/// Why the demo drive cannot start now (`DemoDriveController.startBlocker`).
enum DemoDriveStartBlocker: Error, Hashable, Sendable {
    /// It is already running.
    case running
    /// Record is starting, running or ending; stop the recording first.
    case recordActive
    /// The demo pack is missing from the bundle or did not open; the text
    /// says why (diagnostics, not for the driver).
    case unavailable(reason: String)
}

/// The demo drive (REL-DEMO): Navigate on a simulated car, for App Review
/// and anyone without a car and an adapter. Release builds on a phone
/// included; offline; any country.
///
/// **Same pipeline as Navigate, its own instances.** The demo runs on its
/// own `RecordingSession` in Navigate mode (the same `NavigateRun`,
/// `SessionClock`, `NavigationTap`, link-row mapping and calibration rule),
/// fed by the simulated adapter (`SimulatedOBDLink` over the bench-car
/// script, its speed written in from `DemoSensorModel`) and the demo
/// sources (`DemoMotionSource`, `DemoLocationSource`), into its own
/// `NavigationService` (the same `LiveNavigationRun` and engine) whose only
/// road candidate is the bundled demo pack, opened read-only from the
/// bundle, never installed, never listed in Maps, never merged with the
/// user's packs (and it has its own grid, so it couldn't be).
///
/// **Deterministic** (App Store screenshots must reproduce): every demo
/// run has the same session ID (`DemoSensorModel.sessionID`), so the same
/// seed through the usual `NavigationSeed.derive`; the feed goes through
/// `DemoFeedSequencer`, so the engine gets the same inputs in the same
/// order whatever the live scheduling (motion from the source, OBD on the
/// model's 61 ms grid, fixes from the model); and roads are selected
/// inline (`NavigationService.useInlineRoads`), so they attach after the
/// same input every run. The engine's state at a given demo time is then
/// identical on every run. What still varies: see `DemoDrivePipeline`.
///
/// **The app's own pipeline is held meanwhile**: the app's session is held
/// (`RecordingSession.holdForDemo()`: its Navigate session ends, so its
/// sensors stop; the map-only position feed stops; Record is refused with
/// `.demoDriveRunning`) and the real link is held down
/// (`OBDLinkHolding.holdForDemo()`: disconnected, no autoconnect, no
/// reconnect; an adapter picked meanwhile waits). `stop()` releases both,
/// which is exactly the state before: Navigate enabled as it was, the
/// remembered adapter reconnects, the feed runs again when active.
///
/// **Nothing is written.** The demo session never records (Navigate's sink
/// is tap-only; its `LogStore` points at a temporary directory nothing ever
/// creates), its feed is `.navigateOnly` (no sidecar), its pack library
/// keeps the verification in memory (`cacheURL: nil`, no store, no inbox,
/// so no maintenance), the demo adapter's remembered identifier stays in
/// memory (`VolatileDefaults`), and its disk-space reading reads nothing.
///
/// **Mutual exclusion.** The demo starts only while Record is not active
/// (`startBlocker`); while it runs the app's session refuses Start.
///
/// **Lifecycle.** Backgrounding stops the demo (`handleScenePhase`): the
/// demo sources hold no background location, so iOS would suspend the app
/// and the tickers would deliver a burst of stale samples on return; and
/// a real adapter must be free to autoconnect for a real drive. Terminating
/// needs nothing (the hold is in memory; the demo session ends its own
/// Navigate on `willTerminate`).
@MainActor
@Observable
final class DemoDriveController {
    /// Tunables; tests pass short ones.
    struct Options {
        /// Simulated scan and connect delay of the demo adapter.
        var linkLatency: Duration = .milliseconds(200)
        /// The demo session's Navigate timings; nil = the app session's.
        var navigate: NavigateConfiguration?
        /// `UIApplication.isIdleTimerDisabled` for the demo session (the
        /// screen stays on while the demo runs).
        var setIdleTimerDisabled: @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
        var uptime: any UptimeSource = SystemUptimeSource()
        /// Tests: sees every sequenced input (run generation, input) just
        /// before the demo's navigation does. nil in the app.
        var observeSequencedInput: (@Sendable (Int, NavigationInput) -> Void)?
    }

    /// The demo is running (from `start()` until `stop()`).
    private(set) var isRunning = false
    /// When the running demo was started; nil when not running.
    private(set) var startedAt: ContinuousClock.Instant?
    /// Why the last `start()` failed to build the demo; nil otherwise.
    private(set) var unavailableReason: String?

    /// The HUD shows its DEMO badge exactly while this is true.
    var showsDemoBadge: Bool { isRunning }

    /// Why `start()` would be refused now; nil when it can start.
    var startBlocker: DemoDriveStartBlocker? {
        if isRunning { return .running }
        if appSession.isRecordActive { return .recordActive }
        if let unavailableReason { return .unavailable(reason: unavailableReason) }
        return nil
    }

    var canStart: Bool { startBlocker == nil }

    /// The session the map binds to while the demo runs (`navigateState`,
    /// `latestFix`, `live`, ...); nil when not running.
    var session: RecordingSession? { isRunning ? pipeline?.session : nil }
    /// The demo's (simulated) link, for the HUD's OBD status; nil when not
    /// running.
    var link: (any OBDLinkServicing)? { isRunning ? pipeline?.link : nil }
    /// The demo pack's roads for the map overlay, and the loop; nil when not
    /// running.
    var roads: DemoDriveRoads? { isRunning ? pipeline?.roads : nil }

    /// The demo's navigation (its own service, demo pack only, selected
    /// inline). Exists from init, idle until the first start.
    let navigation: NavigationService
    /// The demo pack as a library (in memory, the bundled pack only), for
    /// the map's roads warning (`RoadsWarning.current(service:library:)`)
    /// only: navigation selects from the opened pack itself.
    let roadPacks: RoadPackLibrary?

    @ObservationIgnored private let appSession: RecordingSession
    @ObservationIgnored private let appLink: any OBDLinkServicing
    @ObservationIgnored private let packURL: URL?
    @ObservationIgnored private let options: Options
    /// Built at the first start and kept for the app's run: a session and a
    /// link subscribe to each other's streams for life, so they are made
    /// once, like the app's own.
    @ObservationIgnored private(set) var pipeline: DemoDrivePipeline?

    /// - Parameters:
    ///   - session, link: the app's own (`AppServices`), held while the demo runs.
    ///   - packURL: the bundled demo pack (`DemoRoadPack.url(in: .main)`);
    ///     nil: the demo is unavailable.
    init(session: RecordingSession, link: any OBDLinkServicing, packURL: URL?, options: Options = Options()) {
        appSession = session
        appLink = link
        self.packURL = packURL
        self.options = options
        roadPacks = packURL.map { url in RoadPackLibrary(source: { [url] }, cacheURL: nil) }
        navigation = NavigationService(library: nil)
    }

    /// Seconds since the running demo's time origin (its session clock's
    /// 0); nil before its Navigate session started or when not running.
    /// Not observed: read it from a `TimelineView` or a timer.
    var elapsedSeconds: Double? {
        guard isRunning, let pipeline else { return nil }
        return pipeline.timeline.seconds(atUptime: options.uptime.uptimeSeconds)
    }

    /// Starts the demo: holds the app's session and link, then connects the
    /// demo adapter with Navigate enabled on the demo session (its Navigate
    /// session starts when the adapter polls, with the usual 5 s still
    /// phase, which the demo car spends parked). Throws `startBlocker`.
    func start() throws(DemoDriveStartBlocker) {
        if let blocker = startBlocker { throw blocker }
        let pipeline: DemoDrivePipeline
        do {
            pipeline = try self.pipeline ?? DemoDrivePipeline(packURL: packURL, navigation: navigation, library: roadPacks,
                                                              options: options)
        } catch {
            unavailableReason = String(describing: error)
            throw .unavailable(reason: String(describing: error))
        }
        self.pipeline = pipeline
        // Record can't have become active since `startBlocker`: nothing suspended.
        guard appSession.holdForDemo() else { throw .recordActive }
        (appLink as? any OBDLinkHolding)?.holdForDemo()
        pipeline.timeline.reset()
        pipeline.session.enableNavigate(options.navigate ?? appSession.navigateTimings ?? NavigateConfiguration())
        pipeline.link.connect(to: SimulatedBLECentral.adapterID)
        isRunning = true
        startedAt = .now
    }

    /// Stops the demo and returns to exactly the state before it: the demo
    /// session's Navigate ends (sources stopped, feed finished, so the demo
    /// service's run ends), the demo adapter disconnects, and the app's
    /// link and session are released. Idempotent.
    func stop() {
        guard isRunning else { return }
        if let pipeline {
            pipeline.session.disableNavigate()
            pipeline.link.disconnect()
            pipeline.timeline.reset()
        }
        isRunning = false
        startedAt = nil
        (appLink as? any OBDLinkHolding)?.releaseDemoHold()
        appSession.releaseDemoHold()
    }

    /// `.background` stops the demo (see the type's doc); `.inactive` and
    /// `.active` change nothing.
    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background { stop() }
    }
}

/// The demo pack's roads for the map (REL-DEMO overlay): every road as a
/// polyline (`RoadPack.polylines()`), the pack's bounding box and the demo
/// loop itself. WGS-84. Data: © OpenStreetMap contributors, ODbL 1.0.
struct DemoDriveRoads: Sendable {
    struct Line: Hashable, Sendable {
        var highwayClass: RoadClass
        var isOneway: Bool
        var points: [GeoPoint]
    }

    var lines: [Line]
    /// South-west and north-east corners of the pack's points.
    var southWest: GeoPoint
    var northEast: GeoPoint
    /// The loop the demo car drives, closed (first point = last point).
    var route: [GeoPoint]
    static let attribution = "© OpenStreetMap contributors"

    init(pack: RoadPack, drive: DemoDrive) {
        func geo(_ p: RoadPoint) -> GeoPoint { GeoPoint(latitude: p.latitude, longitude: p.longitude) }
        lines = pack.polylines().map { Line(highwayClass: $0.highwayClass, isOneway: $0.isOneway, points: $0.points.map(geo)) }
        let bounds = pack.pointBounds()
        southWest = bounds.map { geo($0.southWest) } ?? GeoPoint(latitude: 0, longitude: 0)
        northEast = bounds.map { geo($0.northEast) } ?? GeoPoint(latitude: 0, longitude: 0)
        route = drive.roadShape.map(geo)
    }
}

/// What the demo runs on, built once from the bundled pack.
///
/// Run-to-run variation left after the fixes in `DemoDriveController`'s
/// doc (none of it reaches the engine's inputs, seed or road attach):
/// - The map draws `snapshot()` at the frame's own time: the estimate is
///   extrapolated to that instant, so two runs agree at equal demo times,
///   and a screenshot taken a few ms apart moves the arrow by speed × Δt
///   (0.2 m per 16 ms at 50 km/h).
/// - What the HUD shows from the live streams: the OBD speed is the
///   adapter's last reply (polled on real time, so near a km/h boundary it
///   can read 1 km/h apart), the GPS chip and dot the source's fix (the
///   same values, shown within a tick of its second), the calibrating
///   countdown (wall clock), and the debug stats' timings.
/// - Manual fixes (a double tap is the driver's, at the driver's time).
/// - If the engine fell more than the taps' buffers behind (4096 live
///   inputs, then 65 536 sequenced ones) inputs would be dropped
///   (`droppedInputs`); never seen on the simulator.
@MainActor
final class DemoDrivePipeline {
    enum Failure: Error, CustomStringConvertible {
        case packMissing
        var description: String { "demo.roadpack is not in the app bundle" }
    }

    let session: RecordingSession
    let link: SimulatedOBDLink
    let sources: [any SensorSource]
    let model: DemoSensorModel
    let timeline: DemoTimeline
    let roads: DemoDriveRoads

    /// The header note of the demo session (never written: Navigate writes
    /// nothing).
    nonisolated static let note = "Demo drive (REL-DEMO): simulated car, adapter and sensors; nothing is recorded."

    init(packURL: URL?, navigation: NavigationService, library: RoadPackLibrary?,
         options: DemoDriveController.Options) throws {
        guard let packURL else { throw Failure.packMissing }
        let pack = try DemoRoadPack.open(at: packURL)
        let candidates = [try RoadPackSelection.Candidate(name: packURL.lastPathComponent, pack: pack)]
        let drive = try DemoDrive(pack: pack)
        let model = DemoSensorModel(drive: drive)
        let timeline = DemoTimeline()
        self.model = model
        self.timeline = timeline
        roads = DemoDriveRoads(pack: pack, drive: drive)
        link = SimulatedOBDLink(
            rules: DemoSensorModel.elmRules, defaults: VolatileDefaults(), uptime: options.uptime,
            latency: options.linkLatency,
            replyTransform: { command, reply, requestUptime in
                model.elmReply(command: command, scripted: reply, at: timeline.seconds(atUptime: requestUptime))
            }
        )
        sources = [
            DemoMotionSource(model: model, timeline: timeline, rateHz: SensorSuite.deviceMotionHz),
            DemoLocationSource(model: model, timeline: timeline),
        ]
        session = RecordingSession(
            link: link,
            sources: sources,
            displayLocation: nil,
            // Never created: the demo session never records.
            store: LogStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "DriveLogger-demo-never-written", directoryHint: .isDirectory)),
            uptime: options.uptime,
            diskSpace: NoDiskReading(),
            sensorConfiguration: SensorSuite.configuration,
            notes: Self.note,
            setIdleTimerDisabled: options.setIdleTimerDisabled,
            beginBackgroundTask: { _ in {} },
            // One ID for every demo run: one seed (`DemoSensorModel.navigationSeed`).
            makeSessionID: { DemoSensorModel.sessionID }
        )
        let observe = options.observeSequencedInput
        session.onNavigationFeed = { feed in
            Self.navigate(feed, model: model, candidates: candidates, on: navigation, observe: observe)
        }
        // The roads warning's library status (in memory, writes nothing).
        if let library { Task(priority: .utility) { await library.rescan() } }
    }

    /// Hands `feed` to `navigation` through `DemoFeedSequencer`: a relay
    /// task reads the session's tap, sequences, and records into a new tap
    /// that the service consumes; the inline road candidates are set before
    /// the run begins. Returns at once, like `NavigationService.start`.
    nonisolated static func navigate(_ feed: RecordingNavigationFeed, model: DemoSensorModel,
                                     candidates: [RoadPackSelection.Candidate], on navigation: NavigationService,
                                     observe: (@Sendable (Int, NavigationInput) -> Void)? = nil) {
        let tap = NavigationTap(bufferLimit: 1 << 16)
        let sequenced = RecordingNavigationFeed(generation: feed.generation, header: feed.header, clock: feed.clock,
                                                output: .navigateOnly, tap: tap)
        let generation = feed.generation
        Task.detached(priority: .userInitiated) {
            var sequencer = DemoFeedSequencer(model: model)
            for await input in feed.inputs {
                for out in sequencer.accept(input) {
                    observe?(generation, out)
                    tap.record(out.event)
                }
            }
            tap.finish()
        }
        Task(priority: .userInitiated) {
            await navigation.useInlineRoads(candidates)
            await navigation.consume(sequenced)
        }
    }
}

/// The demo session reads no disk: it never records.
private struct NoDiskReading: DiskSpaceProvider {
    struct NotRead: Error {}
    func availableBytes(for url: URL) throws -> Int64 { throw NotRead() }
}

/// `UserDefaults` that keep `string`/`object`/`set`/`removeObject` in
/// memory, for the demo adapter's remembered identifier and name: nothing
/// of the demo reaches the app's defaults or disk.
final class VolatileDefaults: UserDefaults, @unchecked Sendable {
    // @unchecked: `values` is only touched under `lock` (UserDefaults is
    // Sendable; this subclass keeps that promise with the lock).
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func string(forKey defaultName: String) -> String? {
        lock.withLock { values[defaultName] as? String }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { values[defaultName] = nil }
    }
}

/// The demo's fixes on the map (GPS dot and chip), like the simulator's
/// `SimulatedLocationSource`: display only, a copy of a fix already handed
/// to the (tap-only) sink.
extension DemoLocationSource: LiveReferenceFixReporting {}
