import DriveLoggerCore
import MapKit
import SwiftUI

extension AccuracyBand {
    var color: Color {
        switch self {
        case .good: .green
        case .fair: .yellow
        case .poor: .orange
        case .bad: .red
        }
    }
}

/// Thermal state text, display only.
enum ThermalText {
    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func tone(_ state: ProcessInfo.ThermalState) -> Tone {
        switch state {
        case .nominal: .good
        case .fair: .caution
        case .serious, .critical: .bad
        @unknown default: .neutral
        }
    }
}

/// The Map tab: wires the model to `GPSMapView`. Reads only the model, never
/// the recorder's 16 Hz `live` status.
struct MapScreen: View {
    @Bindable var model: MapViewModel
    @AppStorage("map.headingUp") private var headingUp = false
    /// Debug overlay with the navigation engine's numbers; nothing is logged.
    @AppStorage("debug.navStats") private var showNavStats = false
    let session: RecordingSession
    let navigation: NavigationFeed
    /// False while Settings covers the map (`AppNavigation.mapIsLive`): no
    /// MapKit view, camera loop or offer card then. Navigate/Record and the
    /// root-level track feed keep running; the map re-frames on return.
    var isSelected: Bool
    /// Read once when the map opens with no fix; the system's last position.
    var cachedLocation: @MainActor () -> CachedLocation?
    /// The roads warning was tapped: the app opens Settings → Maps.
    var onOpenMaps: () -> Void = {}
    /// The gear was tapped (UX-14): the app opens Settings full screen.
    var onOpenSettings: () -> Void = {}
    var roadsWarning: RoadsWarningModel?
    /// The at-a-stop offer (UX-8); nil in previews.
    var offers: PackOfferMonitor?
    /// Read for the HUD's OBD indicator only (`HUDOBD.from(link:)`); nil in
    /// previews. Only `state` is read, so the map re-renders on link state
    /// changes, not on poll traffic.
    var link: (any OBDLinkServicing)?
    /// The one-time in-car mount card (UX-18 (2)), for the card above the
    /// Navigate status line: read `isVisible`, call `confirm()` on "Mounted".
    /// Fed by `MapFeed`, never here. nil in previews.
    var mountConfirmation: MountConfirmationModel?
    /// The running demo drive (REL-DEMO): its roads under the arrow, the DEMO
    /// badge, Stop demo. nil outside the demo.
    var demo: MapDemo?
    @Environment(\.scenePhase) private var scenePhase
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        // Without OBD, Navigate shows the plain GPS position only (UX-1 (d)):
        // no dead-reckoning dot or ellipse.
        let status = NavigateStatus.make(
            navigate: session.navigateState, recording: session.state, startedAt: session.navigateStartedAt,
            timings: session.navigateTimings ?? NavigateConfiguration(), now: .now)
        // DEBUG `-uiFakeHUD …`: synthetic HUD inputs (screenshots).
        let fake = Self.fakes
        let shown = model.shown(whileDemo: demo != nil)
        GPSMapView(
            track: fake.scatter ? MapPreviewData.stopTrack : shown.track,
            latest: fake.scatter ? MapPreviewData.stopFixes.last : shown.latest,
            lastFixInstant: fake.scatter ? .now : model.lastFixInstant,
            isReceiving: fake.isActive ? !fake.gpsLost : model.isReceiving,
            thermal: fake.thermal ? .fair : thermal,
            speed: fake.isActive ? fake.speed : model.speed,
            obd: fake.isActive ? fake.obd : HUDOBD.from(link: link?.state, everConnected: model.obdEverConnected),
            isLive: isSelected && scenePhase == .active,
            follow: $model.follow,
            headingUp: $headingUp,
            bearing: model.bearing,
            isStationary: model.isStationary,
            manualFixes: model.drawnManualFixes(excluding: session.droppedManualFixIDs),
            pendingFixIDs: Set(session.pendingManualFixes.map(\.id)),
            manual: marking,
            run: model.runKey,
            cachedLocation: cachedLocation,
            navigation: fake.nav.map(MapPreviewData.fakeNav)
                ?? (fake.debugStrip ? NavigationFeed(display: nil, stats: MapPreviewData.navStats) : navigation),
            showsEstimate: status.showsEstimate || fake.nav != nil,
            showNavStats: fake.debugStrip ? .constant(true) : $showNavStats,
            roadsWarning: warningText,
            roadsWarningDownload: warningDownload,
            onRoadsWarningDownload: { offers?.download() },
            onRoadsWarningTap: onOpenMaps,
            onOpenSettings: onOpenSettings,
            roadsAttribution: (roadsWarning?.attribution ?? false) || demo != nil,
            demo: demo,
            offerCard: bottomCard,
            offerShown: offerIsShown || showsMountCard,
            recordingControl: fake.recording
                ? AnyView(MapRecordingIndicatorLabel(elapsed: "12:34"))
                : AnyView(MapRecordingButton(
                    session: session, offers: offers, onStop: { [session] in await session.stop() })),
            hasActiveRecording: fake.isActive ? fake.recording : MapRecordingControl.isActive(session.state),
            statusLine: fake.isActive
                ? (fake.banner ? AnyView(NavigateStatusLabel(status: .waitingForOBD(secondsLeft: 272)))
                    : fake.calibrating ? AnyView(NavigateStatusLabel(status: .calibrating(secondsLeft: 24))) : nil)
                : (status.text == nil ? nil : AnyView(MapNavigateStatusLine(session: session)))
        )
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onAppear { thermal = ProcessInfo.processInfo.thermalState }
        .onChange(of: link?.state, initial: true) { _, state in model.noteLink(state, adapter: link?.rememberedAdapterID) }
        .onChange(of: link?.rememberedAdapterID) { _, id in model.noteLink(link?.state, adapter: id) }
        // The demo starts or stops: nothing of the other source stays on the
        // map (the real position, the demo's last lap), and the link memory
        // is the new link's.
        .onChange(of: demo != nil) {
            model.resetForDemo(demoOn: demo != nil)
            model.noteLink(link?.state, adapter: link?.rememberedAdapterID)
        }
        // The card may only appear while the map is on screen (UX-8).
        .onChange(of: isSelected && scenePhase == .active, initial: true) { _, visible in
            offers?.isMapVisible = visible
        }
    }
}

extension MapScreen {
    private var offerIsShown: Bool { offers.map { PackOfferCard.current(for: $0) != nil } ?? false }

    /// The roads warning line: the model's, or the DEBUG fake
    /// (`-uiFakeRoadsWarning none|packs`, screenshots).
    private var warningText: String? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "uiFakeRoadsWarning") {
        case "none": return RoadsWarning.noneCovering
        case "packs": return RoadsWarning.noPacks
        default: break
        }
        #endif
        return roadsWarning?.message
    }

    /// B3: the warning's Download, from the at-a-stop offer.
    private var warningDownload: RoadsWarningDownload? {
        guard let offers else { return nil }
        return RoadsWarningOffer.make(
            message: warningText, offer: PackOfferCard.current(for: offers), downloadingTitle: offers.downloadingTitle,
            recording: MapRecordingControl.isActive(session.state))
    }

    /// The in-car mount card shows only when no pack offer is up: one card at a
    /// time in the offer's slot, so the two never overlap and the road-ahead
    /// area stays as with an offer (`offerShown` lifts the car for either).
    private var showsMountCard: Bool { mountConfirmation?.isVisible == true && !offerIsShown }

    /// The top card of the bottom-left zone, above the Navigate status line.
    private var bottomCard: AnyView? {
        if showsMountCard, let mountConfirmation {
            return AnyView(MountConfirmationCardView(onConfirm: { mountConfirmation.confirm() })
                .transition(.move(edge: .bottom).combined(with: .opacity)))
        }
        // The roads banner hosts the offer while it says "no pack covers this area" (B3).
        if RoadsWarningOffer.hostsOffer(warningDownload) { return nil }
        return offers.map { AnyView(PackOfferCard(monitor: $0)) }
    }

    fileprivate static var fakes: HUDFakes {
        #if DEBUG
        return HUDFakes.parse(UserDefaults.standard.string(forKey: "uiFakeHUD"))
        #else
        return HUDFakes()
        #endif
    }

    /// Closures only: nothing here reads `session.live` while `body` runs.
    fileprivate var marking: ManualFixMarking {
        ManualFixMarking(
            tapTime: { [session] in session.manualFixTapTime() },
            stage: { [session, model] latitude, longitude, tapT, spanM in
                guard let id = session.stageManualFix(
                    latitude: latitude, longitude: longitude, tapT: tapT, mapSpanM: spanM
                ) else { return nil }
                model.addManualFix(id: id, latitude: latitude, longitude: longitude)
                return id
            },
            undo: { [session, model] id in
                ManualFixUndo.perform(
                    id: id, cancel: { session.cancelPendingManualFix($0) },
                    removeMarker: { model.removeManualFix(id: $0) }
                ) == .removed
            },
            undoWindow: session.manualFixUndoWindow
        )
    }
}

/// Invisible feed from the recorder to the map model. It is the only view
/// that observes `session.live` and `session.latestFix`, so the 16 Hz OBD
/// updates and each fix re-run just this trivial body and not the tab
/// hierarchy.
struct MapFeed: View {
    let session: RecordingSession
    let model: MapViewModel
    /// The in-car mount card (UX-18 (2)): fed the same OBD speed and the
    /// Navigate state; it only observes.
    var mount: MountConfirmationModel?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: session.live.obdSpeedKmh, initial: true) { refreshStationary() }
            .onChange(of: session.navigateState) { refreshStationary() }
            // A 0 that goes stale with no new reading must stop counting
            // as stopped: re-check twice a second (reads, never observes).
            .task {
                while !Task.isCancelled {
                    refreshStationary()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // Each fix as it arrives (R24.1-1), not on the 1 s live tick.
            .onChange(of: session.latestFix) { _, fix in
                model.ingest(
                    fix, file: session.currentFile, run: session.currentRunGeneration,
                    isActive: scenePhase == .active, elapsed: runElapsed
                )
            }
            // The plain GPS position while no run is live (R61.1-4).
            .onChange(of: session.displayFix) { _, fix in
                model.ingestDisplay(fix, isActive: scenePhase == .active)
            }
            // A new Start resets the track before its first fix arrives.
            .onChange(of: session.currentRunGeneration) { _, run in
                model.ingest(
                    session.latestFix, file: session.currentFile, run: run,
                    isActive: scenePhase == .active, elapsed: runElapsed
                )
            }
            .onChange(of: scenePhase) { _, phase in
                // Pick up a change missed while inactive.
                if phase == .active {
                    model.ingest(
                        session.latestFix, file: session.currentFile,
                        run: session.currentRunGeneration, isActive: true, elapsed: runElapsed
                    )
                    model.ingestDisplay(session.displayFix, isActive: true)
                }
            }
    }
}

extension MapFeed {
    /// The run's clock time now, for fix age. `live.elapsed` only ticks in
    /// Record; the run clock is right in Navigate too.
    fileprivate var runElapsed: TimeInterval {
        session.manualFixTapTime()?.seconds ?? session.live.elapsed
    }

    fileprivate func refreshStationary() {
        model.setOBDSpeed(
            session.live.obdSpeedKmh, replyUptime: session.obdSpeedReplyUptime,
            now: session.currentUptimeSeconds
        )
        mount?.update(session: session)
    }
}

/// The one toast on the map: a recorded fix (with Undo) or the zoom hint.
struct MapToast: Hashable {
    enum Kind: Hashable {
        case recorded(id: Int)
        case zoomIn
        /// Undo came too late: the row is in the file.
        case alreadyRecorded
    }

    var kind: Kind
    /// A new toast of the same kind restarts the timer.
    var serial = 0

    /// Undo lasts as long as the recorder keeps the fix pending.
    func duration(undoWindow: Duration) -> Duration {
        switch kind {
        case .recorded: undoWindow
        case .zoomIn, .alreadyRecorded: .seconds(2.5)
        }
    }
}

/// Plain-values map screen so previews can use fake data.
struct GPSMapView: View {
    /// A fix older than this is shown greyed out.
    static let staleAfter: Duration = .seconds(5)
    private static let space = "gpsMap"

    var track: GPSTrack
    var latest: LocationSample?
    var lastFixInstant: ContinuousClock.Instant?
    /// False before the first fix and after Stop.
    var isReceiving: Bool
    var thermal: ProcessInfo.ThermalState
    /// The one speed shown in the info block and where it comes from.
    var speed: MapSpeedReadout = .none
    /// The HUD's OBD indicator, from the link state.
    var obd: HUDOBD = .lost
    /// Selected tab and active scene. When false no `Map` exists and the
    /// camera is not touched.
    var isLive: Bool
    @Binding var follow: FollowController
    @Binding var headingUp: Bool
    /// Direction of travel, degrees from true north; nil until a good one.
    var bearing: Double?
    /// OBD speed is 0: the heading holds still.
    var isStationary: Bool = false
    var manualFixes: [ConfirmedFix] = []
    /// Ids of `manualFixes` still in their undo window (not yet written).
    var pendingFixIDs: Set<Int> = []
    var manual: ManualFixMarking = .unavailable
    /// The recording the map shows.
    /// The run (recording or Navigate session) the track belongs to.
    var run: MapRunKey?
    /// Last known system position, read when the tab opens with no fix.
    var cachedLocation: @MainActor () -> CachedLocation? = { nil }
    /// Live dead reckoning; nil in previews of the plain reference map.
    var navigation: NavigationFeed?
    /// False without OBD (UX-1 (d)): the feed is still passed and polled, so
    /// it is fresh the moment Navigate starts, but nothing draws or follows it.
    var showsEstimate = true
    @Binding var showNavStats: Bool
    /// One line when roads are off for a fixable reason (`RoadsWarning`).
    var roadsWarning: String?
    /// The Download on that line (B3), when the manifest has a region here.
    var roadsWarningDownload: RoadsWarningDownload?
    var onRoadsWarningDownload: () -> Void = {}
    var onRoadsWarningTap: () -> Void
    /// The gear at the bottom of the right rail (UX-14, UX-32).
    var onOpenSettings: () -> Void = {}
    /// A road pack is attached to the run (`MapAttribution.visible`): the
    /// OSM credit is shown.
    var roadsAttribution = false
    /// The running demo drive: roads overlay, DEMO badge, Stop demo; nil outside it.
    var demo: MapDemo?
    /// The at-a-stop road-pack offer (UX-8), top of the bottom-left zone; its own
    /// view, so this one stays plain values.
    var offerCard: AnyView?
    /// The offer is actually showing (not just wired): while it is, the car is
    /// centred instead of sitting in the lower third under the card (R68.1-3).
    var offerShown = false
    /// The recording row in the top-left card. A view of its own (it reads
    /// the recorder's 16 Hz status), so this view stays plain values.
    var recordingControl: AnyView?
    /// A recording is calibrating, running or stopping, so the recording row
    /// ends the HUD card (R68.1-2). `recordingControl` is always non-nil in the
    /// app (empty while idle), so it cannot tell.
    var hasActiveRecording = false
    /// Navigate's calibration / OBD-lost banner (UX-1), in the bottom-left zone; nil when it has no text.
    var statusLine: AnyView?

    @Environment(\.colorScheme) private var scheme
    @State private var position: MapCameraPosition = .automatic
    /// Visible north-south extent, metres, from the camera.
    @State private var visibleSpanM: Double?
    @State private var isStale = false
    @State private var toast: MapToast?
    @State private var toastSerial = 0
    /// Counts recorded fixes: the success haptic fires on each.
    @State private var recordedCount = 0
    /// Reference box: the 10 Hz smoother and write gate change without
    /// re-rendering the view (and its polylines).
    @State private var headingState = HeadingState()
    /// Copy of the inputs the 10 Hz heading task reads; a task closure would
    /// otherwise see the props from when it started.
    @State private var inputs = HeadingInputs()
    @State private var cameraHeading = 0.0
    /// The map's size and bottom safe area, for the ellipse fit (C8).
    @State private var mapGeometry = MapGeometry()

    struct MapGeometry: Equatable {
        var size = CGSize.zero
        var safeBottom = 0.0
    }

    @MainActor
    final class HeadingState {
        var smoother = HeadingSmoother()
        var gate = HeadingWriteGate()
        /// The driver's zoom and our latest camera write (R14.2-1).
        var zoom = FollowZoom()
        /// A feed publish the 0.25 s gate held back (R26.2-1).
        var publishPending = false
    }

    struct HeadingInputs: Equatable {
        var fix: LocationSample?
        var bearing: Double?
        var frozen = false
        var headingUp = false
        var following = false
        /// Whole km/h from `MapSpeedRule`, nil without a source (UX-6).
        var speedKmh: Int?
    }

    init(
        track: GPSTrack, latest: LocationSample?, lastFixInstant: ContinuousClock.Instant?,
        isReceiving: Bool, thermal: ProcessInfo.ThermalState, speed: MapSpeedReadout = .none,
        obd: HUDOBD = .lost,
        isLive: Bool,
        follow: Binding<FollowController>, headingUp: Binding<Bool> = .constant(false),
        bearing: Double? = nil, isStationary: Bool = false, manualFixes: [ConfirmedFix] = [],
        pendingFixIDs: Set<Int> = [],
        manual: ManualFixMarking = .unavailable,
        run: MapRunKey? = nil,
        cachedLocation: @escaping @MainActor () -> CachedLocation? = { nil },
        initialToast: MapToast? = nil,
        navigation: NavigationFeed? = nil,
        showsEstimate: Bool = true,
        showNavStats: Binding<Bool> = .constant(false),
        roadsWarning: String? = nil,
        roadsWarningDownload: RoadsWarningDownload? = nil,
        onRoadsWarningDownload: @escaping () -> Void = {},
        onRoadsWarningTap: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        roadsAttribution: Bool = false,
        demo: MapDemo? = nil,
        offerCard: AnyView? = nil,
        offerShown: Bool = false,
        recordingControl: AnyView? = nil,
        hasActiveRecording: Bool = false,
        statusLine: AnyView? = nil
    ) {
        self.track = track
        self.latest = latest
        self.lastFixInstant = lastFixInstant
        self.isReceiving = isReceiving
        self.thermal = thermal
        self.speed = speed
        self.obd = obd
        self.isLive = isLive
        self._follow = follow
        self._headingUp = headingUp
        self.bearing = bearing
        self.isStationary = isStationary
        self.manualFixes = manualFixes
        self.pendingFixIDs = pendingFixIDs
        self.manual = manual
        self.run = run
        self.cachedLocation = cachedLocation
        self.navigation = navigation
        self.showsEstimate = showsEstimate
        self._showNavStats = showNavStats
        self.roadsWarning = roadsWarning
        self.roadsWarningDownload = roadsWarningDownload
        self.onRoadsWarningDownload = onRoadsWarningDownload
        self.onRoadsWarningTap = onRoadsWarningTap
        self.onOpenSettings = onOpenSettings
        self.roadsAttribution = roadsAttribution
        self.demo = demo
        self.offerCard = offerCard
        self.offerShown = offerShown
        self.recordingControl = recordingControl
        self.hasActiveRecording = hasActiveRecording
        self.statusLine = statusLine
        self._toast = State(initialValue: initialToast)
    }

    /// Hands the ellipse fit the map's size and what covers it.
    private func applyViewport() {
        guard mapGeometry.size.width > 0, mapGeometry.size.height > 0 else { return }
        headingState.zoom.viewport = EllipseFit.Viewport.make(
            size: mapGeometry.size, safeBottom: mapGeometry.safeBottom, offerShown: offerShown)
    }

    var body: some View {
        content
            .onGeometryChange(for: MapGeometry.self) { proxy in
                MapGeometry(size: proxy.size, safeBottom: proxy.safeAreaInsets.bottom)
            } action: { geometry in
                mapGeometry = geometry
                applyViewport()
            }
            .onChange(of: latest) { old, fix in
                guard isLive, let fix else { return }
                if old == nil {
                    // First fix of a recording.
                    frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy)
                } else if follow.isFollowing, estimate?.latest == nil {
                    // With a dead-reckoning estimate the 100 ms loop follows it.
                    recenter(center: fix.coordinate)
                }
            }
            .onChange(of: HeadingInputs(
                fix: latest, bearing: bearing, frozen: isStationary,
                headingUp: headingUp, following: follow.isFollowing, speedKmh: speed.kmh
            ), initial: true) { _, new in
                inputs = new
            }
            .onChange(of: headingUp) {
                // Mode switch while following: swing the camera to the new heading.
                if follow.isFollowing { moveCameraToCar(duration: 0.6) }
            }
            // Auto-resume: sleeps on the clock the deadline is on, ticks, and
            // sleeps again while a deadline remains. A new deadline restarts it.
            .task(id: follow.resumeDeadline) {
                await FollowResumeLoop.run(
                    deadline: { follow.resumeDeadline },
                    now: { ContinuousClock.now },
                    sleep: { try? await Task.sleep(until: $0, clock: .continuous) },
                    resumeIfDue: { resumeIfDue() }
                )
            }
            // Opening the map: frame on a fresh estimate, then one 100 ms loop
            // while the map is visible and the scene active: it polls the
            // navigation feed, then turns/centres the camera.
            // Keyed on showsEstimate too: the loop's captured copy of this view
            // would otherwise keep the value from when it started (R61.1-1).
            .task(id: MapLoopKey(isLive: isLive, showsEstimate: showsEstimate, isDemo: demo != nil)) {
                await frameOnOpen()
                await runLoop()
            }
            // R68.1-3: the car moves to the middle while the offer card is up
            // and back when it goes (heading-up only; north-up is centred).
            .onChange(of: offerShown, initial: true) { _, shown in
                headingState.zoom.carFromTop = CarPlacement.carFromTop(headingUp: true, offerShown: shown)
                applyViewport()
                guard headingUp, isLive, follow.isFollowing, let center = followCenter else { return }
                withAnimation(.easeInOut(duration: 0.4)) { recenter(center: center) }
            }
            // Fires on reselect/foreground too.
            .onChange(of: isLive, initial: true) { _, live in
                guard live else { return }
                // A deadline that passed while away (screen off, other tab).
                resumeIfDue()
            }
            // A new recording or Navigate session: a toast from the previous
            // one would offer a dead Undo, and its heading must not turn the map.
            .onChange(of: run) { old, new in
                guard HeadingReset.isNewRun(from: old, to: new) else { return }
                toast = nil
                HeadingReset.newRun(
                    smoother: &headingState.smoother, gate: &headingState.gate,
                    publishPending: &headingState.publishPending)
            }
            // No bearing: nothing to turn to; drop a stale smoothed heading.
            .onChange(of: bearing) { _, new in
                HeadingReset.bearingChanged(
                    to: new, effectiveBearing: effectiveBearing, smoother: &headingState.smoother)
            }
            .task(id: lastFixInstant) {
                isStale = false
                guard let instant = lastFixInstant else { return }
                let remaining = Self.staleAfter - (ContinuousClock.now - instant)
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                    if Task.isCancelled { return }
                }
                isStale = true
            }
            // The toast lives as long as the fix is pending, not as long as a
            // view task: leaving the tab cancels the task, not the toast.
            .onChange(of: pendingFixIDs) { dismissIfWritten() }
            .task(id: toast) {
                dismissIfWritten()
                guard let shown = toast else { return }
                try? await Task.sleep(for: shown.duration(undoWindow: manual.undoWindow))
                if !Task.isCancelled { toast = nil }
            }
            .sensoryFeedback(.success, trigger: recordedCount)
    }

    /// What heading-up turns to: the dead-reckoning heading once converged,
    /// otherwise the GPS-course bearing (M4.3).
    private var effectiveBearing: Double? {
        let nav = estimate?.latest
        return CameraHeading.targetBearing(
            drHeading: nav?.headingDeg, converged: nav?.converged ?? false, gpsBearing: bearing
        )
    }

    /// Where Following centres: the estimate once initialised, else the GPS fix.
    private var followCenter: CLLocationCoordinate2D? {
        FollowTarget.center(dr: estimate?.latest?.position, gps: latest?.geo)?.coordinate
    }

    /// Resumes Following if the deadline has passed. True when it did.
    @discardableResult
    private func resumeIfDue() -> Bool {
        var next = follow
        guard next.tick(now: ContinuousClock.now) else { return false }
        follow = next
        moveCameraToCar(duration: 0.8)
        return true
    }

    private func updateFollow(_ body: (inout FollowController) -> Void) {
        var next = follow
        body(&next)
        if next != follow { follow = next }
    }

    /// The feed, for drawing and following; nil while the estimate is hidden.
    private var estimate: NavigationFeed? { showsEstimate ? navigation : nil }

    private var stale: Bool { isStale || !isReceiving }

    private var content: some View {
        ZStack {
            if isLive && !Self.hidesTiles {
                mapBody(stale: stale)
            } else {
                placeholder
            }
        }
        // Top-left card (UX-32): the only thing at the top.
        .overlay(alignment: .topLeading) { hudCard }
        // Right rail: North up / Heading up, Following, Settings.
        .overlay(alignment: .bottomTrailing) { rail }
        // REL-DEMO: the badge and Stop demo, top right, only while it runs.
        .overlay(alignment: .topTrailing) {
            if let demo {
                DemoControls(onStop: demo.onStop, elapsed: demo.elapsed)
                    .padding(.trailing, MapLayout.edgeInset)
                    .padding(.top, 8)
            }
        }
        // Bottom-left zone, left of the rail, stacked upward.
        .overlay(alignment: .bottomLeading) { bottomZone }
        // UX-33: the OSM credit, one line at the very bottom edge.
        .overlay(alignment: .bottom) {
            if roadsAttribution { MapAttributionLine() }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        #if DEBUG
        if Self.hidesTiles && isLive {
            SyntheticBasemap(
                carFromTop: headingUp && follow.isFollowing
                    ? CarPlacement.carFromTop(headingUp: true, offerShown: offerShown) : 0.5)
        } else {
            Color(.secondarySystemBackground).ignoresSafeArea()
        }
        #else
        Color(.secondarySystemBackground).ignoresSafeArea()
        #endif
    }

    // MARK: HUD

    private var hudState: MapHUDState {
        MapHUDState.make(
            speed: speed, gps: MapHUDState.gpsState(stale: stale), obd: obd,
            thermal: thermal)
    }

    /// Speed, GPS and OBD indicators, thermal when not nominal, recording row.
    private var hudCard: some View {
        MapHUDCard(
            state: hudState,
            hasRecording: hasActiveRecording,
            onSpeedLongPress: { showNavStats.toggle() },
            extra: {
                if let estimate { NavCalibratingIcon(feed: estimate) }
            },
            recording: {
                if let recordingControl { recordingControl }
            }
        )
        .padding(.leading, MapLayout.edgeInset)
        .padding(.top, 8)
    }

    private var rail: some View {
        VStack(spacing: MapLayout.railGap) {
            HUDRailButton(
                symbol: headingUp ? "location.north.line.fill" : "n.circle",
                label: headingUp ? "Heading up" : "North up", active: headingUp
            ) { headingUp.toggle() }
            HUDRailButton(
                symbol: follow.isFollowing ? "location.fill" : "location",
                label: follow.isFollowing ? "Following" : "Follow", active: follow.isFollowing
            ) {
                let was = follow.isFollowing
                updateFollow { $0.followTapped(at: ContinuousClock.now) }
                if follow.isFollowing, !was { moveCameraToCar(duration: 0.8) }
            }
            HUDRailButton(symbol: "gearshape", label: "Settings", active: false, action: onOpenSettings)
        }
        .padding(.trailing, MapLayout.edgeInset)
        .padding(.bottom, MapLayout.bottomInset())
    }

    private var bottomItems: [MapBottomItem] {
        MapBottomZone.items(
            offer: offerCard != nil, toast: toast != nil, status: statusLine != nil,
            positionStatus: estimate != nil, roadsWarning: roadsWarning != nil, resumeHint: follow.resumeDeadline != nil,
            debugSetting: showNavStats)
    }

    private var bottomZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bottomItems, id: \.self) { item in
                bottomView(item)
            }
        }
        .padding(.leading, MapLayout.edgeInset)
        .padding(.trailing, MapLayout.railReserved)
        .padding(.bottom, MapLayout.bottomInset())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bottomView(_ item: MapBottomItem) -> some View {
        switch item {
        case .offerCard: offerCard
        case .toast: if let toast { toastView(toast) }
        case .statusLine: statusLine
        case .positionStatus: if let estimate { PositionStatusLine(feed: estimate) }
        case .roadsWarning: if let roadsWarning { roadsWarningView(roadsWarning) }
        case .resumeHint: resumeHint
        case .debugStrip: MapDebugStrip(lines: DebugStrip.lines(stats: navigation?.stats))
        }
    }

    /// DEBUG `-uiNoMapTiles 1`: a plain background instead of the map, so a
    /// screenshot shows no real place (the simulator has a real location).
    private static var hidesTiles: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "uiNoMapTiles")
        #else
        return false
        #endif
    }

    /// Standard map; DEBUG `-uiBlankMap 1` uses plain imagery (no street, POI or
    /// place text) so simulator screenshots carry no place names.
    private static var baseStyle: MapStyle {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "uiBlankMap") { return .imagery }
        #endif
        return .standard
    }

    private func color(_ band: AccuracyBand, stale: Bool) -> Color {
        stale ? .gray : band.color
    }

    private func mapBody(stale: Bool) -> some View {
        MapReader { proxy in
            Map(position: $position) {
                #if DEBUG
                // `-uiBlankMap 2`: an opaque flat fill over the demo area, so
                // a screenshot shows the overlay as on a tile-less map
                // (airplane mode), with no place names.
                if UserDefaults.standard.integer(forKey: "uiBlankMap") == 2, let demo {
                    MapPolygon(coordinates: demo.flatRing)
                        .foregroundStyle(scheme == .dark
                            ? Color(red: 0.11, green: 0.13, blue: 0.18) : Color(red: 0.93, green: 0.94, blue: 0.95))
                }
                #endif
                if let demo { DemoRoadsOverlay(roads: demo.roads, dark: scheme == .dark) }
                TrackOverlay(track: track)
                if let estimate {
                    NavOverlay(
                        feed: estimate, headingUp: headingUp, cameraHeading: cameraHeading, showEdge: showNavStats,
                        dark: scheme == .dark)
                }
                if let latest, let band = AccuracyBand(accuracy: latest.horizontalAccuracy) {
                    let c = color(band, stale: stale)
                    MapCircle(center: latest.coordinate, radius: latest.horizontalAccuracy)
                        .foregroundStyle(c.opacity(0.2))
                        .stroke(c, lineWidth: 1)
                    Annotation("", coordinate: latest.coordinate) {
                        carMarker(color: c)
                    }
                }
                ForEach(manualFixes) { fix in
                    Annotation("", coordinate: .init(latitude: fix.latitude, longitude: fix.longitude), anchor: .bottom) {
                        fixMarker(pending: pendingFixIDs.contains(fix.id))
                    }
                }
            }
            .coordinateSpace(.named(Self.space))
            .mapStyle(Self.baseStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                // Not our own write: the driver zoomed.
                headingState.zoom.cameraReported(distance: context.camera.distance)
                if let span = MapFraming.visibleSpanMeters(
                    latitudeDelta: context.region.span.latitudeDelta,
                    cameraDistance: context.camera.distance, heading: context.camera.heading
                ),
                   MapChange.isSignificant(old: visibleSpanM, new: span) {
                    visibleSpanM = span
                }
                if abs(context.camera.heading - cameraHeading) > 0.5 { cameraHeading = context.camera.heading }
                // While following this is our own move and is ignored; while
                // paused, only the user (or pan inertia) moves the camera.
                updateFollow { $0.cameraSettled(at: ContinuousClock.now) }
            }
            // Touch-only gestures turn Following off. No `positionedByUser`:
            // MapKit sets it for changes the user did not make.
            .onMapUserGesture {
                updateFollow { $0.userGesture(at: ContinuousClock.now) }
            }
            // Alongside MapKit's own double-tap zoom, which still happens.
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .named(Self.space))
                    .onEnded { handleDoubleTap(at: $0.location, proxy: proxy) }
            )
        }
    }

    /// Flag for a manual fix; translucent while its undo window is open.
    private func fixMarker(pending: Bool) -> some View {
        Image(systemName: "flag.fill")
            .font(.title2)
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.indigo, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .opacity(pending ? 0.55 : 1)
    }

    /// A double tap records the point under the finger. The map zooms in on
    /// a double tap, so the coordinate (`MapProxy`), the span and the session
    /// time are all read here, before that zoom starts.
    private func handleDoubleTap(at point: CGPoint, proxy: MapProxy) {
        guard let coordinate = proxy.convert(point, from: .named(Self.space)) else { return }
        switch ManualFixTap.perform(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            visibleSpanM: visibleSpanM, marking: manual
        ) {
        case .ignored:
            break
        case .tooFarOut:
            show(.zoomIn)
        case .staged(let id, _, _):
            recordedCount += 1
            show(.recorded(id: id))
        }
    }

    /// A recorded-fix toast whose fix left the pending list goes away.
    private func dismissIfWritten() {
        if case .recorded(let id)? = toast?.kind,
           !ManualFixUndo.offersUndo(id: id, pendingIDs: pendingFixIDs) {
            toast = nil
        }
    }

    private func show(_ kind: MapToast.Kind) {
        toastSerial += 1
        toast = MapToast(kind: kind, serial: toastSerial)
    }

    /// Same look as the other toasts (material capsule, headline weight), one
    /// line; tap opens Settings → Maps, which lists the packs.
    private func roadsWarningView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            roadsWarningLine(text)
            if let download = roadsWarningDownload {
                // B3: the offer of the at-a-stop card, hosted by the banner.
                switch download.state {
                case .offer:
                    Button(action: onRoadsWarningDownload) {
                        Text(download.buttonText)
                            .font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color("AccentForeground"))
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(download.buttonText)
                case .queued:
                    Label(download.queuedText, systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .hudSurface(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roadsWarningLine(_ text: String) -> some View {
        Button(action: onRoadsWarningTap) {
            Label(text, systemImage: "road.lanes")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .hudSurface(Capsule())
                .overlay(Capsule().strokeBorder(HUDColors.warn, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private func toastView(_ toast: MapToast) -> some View {
        switch toast.kind {
        case .recorded(let id):
            HStack(spacing: 14) {
                Label("Fix recorded", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                if ManualFixUndo.offersUndo(id: id, pendingIDs: pendingFixIDs) {
                    Button("Undo") {
                        if manual.undo(id) {
                            self.toast = nil
                        } else {
                            show(.alreadyRecorded)
                        }
                    }
                    .font(.headline)
                    .prominentButton()
                    .frame(minHeight: 56)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 64)
            .hudSurface(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        case .alreadyRecorded:
            Label("Already recorded, not undone", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .hudSurface(Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
        case .zoomIn:
            Label(PinPrecision.hint, systemImage: "plus.magnifyingglass")
                .font(.headline)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 56)
                .hudSurface(RoundedRectangle(cornerRadius: 28))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Applies the span rule as a region centred on `center` (the estimate's
    /// position instead, once there is one).
    private func frame(center: CLLocationCoordinate2D, accuracy: Double) {
        reseedHeading()
        let center = estimate?.latest?.position.coordinate ?? center
        let span = MapFraming.spanMeters(horizontalAccuracy: accuracy)
        if headingUp, follow.isFollowing, effectiveBearing != nil {
            // A region would be north-up; keep the mode.
            let framed = MapFraming.cameraDistance(spanMeters: span)
            headingState.zoom.frame(distance: framed)
            position = .camera(MapCamera(
                centerCoordinate: Self.cameraCenter(
                    car: center, distance: framed, heading: targetHeading, headingUp: true,
                    carFromTop: headingState.zoom.carFromTop),
                distance: framed, heading: targetHeading, pitch: 0
            ))
            return
        }
        headingState.zoom.frame(distance: nil)
        position = .region(MKCoordinateRegion(
            center: center, latitudinalMeters: span, longitudinalMeters: span
        ))
    }

    /// The camera centre that puts the car in the lower third in heading-up
    /// (`CarPlacement`); the car itself in north-up.
    private static func cameraCenter(
        car: CLLocationCoordinate2D, distance: Double, heading: Double, headingUp: Bool, carFromTop: Double
    ) -> CLLocationCoordinate2D {
        let ahead = CarPlacement.aheadMetres(cameraDistance: distance, headingUp: headingUp, carFromTop: carFromTop)
        let c = CarPlacement.cameraCenter(
            latitude: car.latitude, longitude: car.longitude, headingDegrees: heading, aheadMetres: ahead)
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    /// Camera heading for the current mode: 0 north-up, the smoothed bearing heading-up.
    private var targetHeading: Double {
        CameraHeading.choose(headingUp: headingUp, bearing: effectiveBearing, smoothed: headingState.smoother.heading)
    }

    /// Camera distance for a write: the driver's zoom or the speed-based one,
    /// widened with an estimate to fit its whole ellipse (`FollowZoom`).
    private func followDistance(_ nav: NavDisplay?, heading: Double) -> Double {
        headingState.zoom.autoFollowDistance(
            headingUp: headingUp, ellipse: nav.map(FitEllipse.init), cameraHeading: heading)
    }

    /// Recentres, keeping the user's current zoom and mode.
    fileprivate func recenter(center: CLLocationCoordinate2D) {
        let heading = targetHeading
        headingState.gate.noteWrite(heading, at: ContinuousClock.now)
        let d = followDistance(estimate?.latest, heading: heading)
        position = .camera(MapCamera(
            centerCoordinate: Self.cameraCenter(
                car: center, distance: d, heading: heading, headingUp: headingUp,
                carFromTop: headingState.zoom.carFromTop),
            distance: d, heading: heading, pitch: 0
        ))
    }

    /// Heading-up is (re)activating: start from the last good bearing, before
    /// any camera write. Called from every path that moves the camera on
    /// activation (frame on tab return, mode toggle, resume, Follow tap).
    private func reseedHeading() {
        guard headingUp else { return }
        _ = CameraHeading.activate(
            smoother: &headingState.smoother, gate: &headingState.gate, bearing: effectiveBearing
        )
    }

    /// Animates back to the car at the current zoom and mode.
    private func moveCameraToCar(duration: Double) {
        headingState.zoom.recentre()   // back to the speed-based zoom (UX-6)
        reseedHeading()
        guard isLive, let center = followCenter else { return }
        withAnimation(.easeInOut(duration: duration)) { recenter(center: center) }
    }

    /// Frames the map when it becomes live. The estimate is polled first:
    /// the feed's `latest` is only updated while the loop runs, so after a
    /// Stop (or any recording change) while the map was away it is stale
    /// (R14.1-3). Without an estimate the last fix, then the cached location.
    private func frameOnOpen() async {
        guard isLive else { return }
        let polled = await navigation?.refreshed()
        let nav = showsEstimate ? polled : nil
        if Task.isCancelled { return }
        let cached = cachedLocation()
        switch MapFraming.chooseOpen(
            hasFix: latest != nil, hasEstimate: nav != nil, demo: demo != nil, hasCached: cached != nil
        ) {
        case .fix:
            if let fix = latest { frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy) }
        case .estimate:
            if let nav { frame(center: nav.position.coordinate, accuracy: nav.semiMajorM / 3) }
        case .demoRegion:
            // The demo area, never the user's position (REL-DEMO).
            if let demo { position = .region(demo.region) }
        case .cached:
            // Camera only: no dot is drawn for it.
            if let cached {
                frame(
                    center: CLLocationCoordinate2D(latitude: cached.latitude, longitude: cached.longitude),
                    accuracy: cached.horizontalAccuracy
                )
            }
        case .none: break
        }
    }

    /// ~10 Hz while the map is visible. Polls the navigation feed, steps the
    /// heading smoother and, while following, writes the camera: when the
    /// feed published a new estimate, (heading-up) the heading moved
    /// enough, or the auto zoom moved. At most 4 writes a second in total
    /// (`FollowCameraTick`); when nothing changed it writes nothing.
    private func runLoop() async {
        guard isLive else { return }
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            let published = await navigation?.poll() ?? false
            if Task.isCancelled { return }
            let now = ContinuousClock.now
            let dt = Double((now - last).components.seconds)
                + Double((now - last).components.attoseconds) / 1e18
            last = now
            let nav = estimate?.latest
            let target = CameraHeading.targetBearing(
                drHeading: nav?.headingDeg, converged: nav?.converged ?? false, gpsBearing: inputs.bearing
            )
            headingState.zoom.step(
                speedKmh: inputs.speedKmh.map(Double.init), dt: dt, ellipse: nav.map(FitEllipse.init),
                headingUp: inputs.headingUp, cameraHeading: headingState.smoother.heading ?? 0)
            guard inputs.following else { continue }
            let center = FollowTarget.center(dr: nav?.position, gps: inputs.fix?.geo)
            guard let camera = FollowCameraTick.decide(
                smoother: &headingState.smoother, gate: &headingState.gate, zoom: &headingState.zoom,
                publishPending: &headingState.publishPending,
                published: published, headingUp: inputs.headingUp, frozen: inputs.frozen, target: target,
                hasEstimate: nav != nil, hasCenter: center != nil, ellipse: nav.map(FitEllipse.init),
                dt: dt, now: now
            ), let center else { continue }
            withAnimation(.linear(duration: 0.25)) {
                position = .camera(MapCamera(
                    centerCoordinate: Self.cameraCenter(
                        car: center.coordinate, distance: camera.distance, heading: camera.heading,
                        headingUp: inputs.headingUp, carFromTop: headingState.zoom.carFromTop),
                    distance: camera.distance, heading: camera.heading, pitch: 0
                ))
            }
        }
    }

    /// Dot north-up; arrow heading-up, turned by bearing minus camera heading
    /// so it points up while following and still shows true direction after
    /// the user rotates the map.
    @ViewBuilder
    private func carMarker(color: Color) -> some View {
        if headingUp, let bearing, estimate?.latest == nil {
            Image(systemName: "location.north.fill")
                .font(.system(size: 30))
                .foregroundStyle(color)
                .shadow(color: .white, radius: 1)
                .shadow(color: .white, radius: 1)
                .rotationEffect(.degrees(bearing - cameraHeading))
        } else {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 3))
        }
    }

    /// Ticks at 1 Hz inside its own TimelineView; the Map is not re-rendered.
    private var resumeHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("Re-centre in \(follow.countdownSeconds(now: ContinuousClock.now) ?? 1) s")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .hudSurface(Capsule())
        }
    }
}

/// The track polylines, keyed on `track` only: heading changes do not touch it.
private struct TrackOverlay: MapContent {
    var track: GPSTrack

    var body: some MapContent {
        // Fixes over 15 m (fair, poor, bad): faded dots in their band colour,
        // never part of the line.
        ForEach(track.faded, id: \.t) { point in
            Annotation("", coordinate: point.coordinate) {
                Circle()
                    .fill(point.band.color.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
        }
        ForEach(Array(track.runs.enumerated()), id: \.offset) { _, run in
            if run.points.count >= 2 {
                MapPolyline(coordinates: run.points.map(\.coordinate))
                    .stroke(run.band.color, lineWidth: 5)
            }
        }
    }
}

/// The dead-reckoning dot and 95 % ellipse. Its own content type, so it is
/// the only map content that reads the feed's observed `display`; the
/// polylines in `TrackOverlay` depend on `track` alone.
private struct NavOverlay: MapContent {
    var feed: NavigationFeed
    var headingUp: Bool
    var cameraHeading: Double
    /// The roads debug switch (`RoadDebugOverlay`).
    var showEdge: Bool
    /// Explicit colours per scheme: MapKit overlays ignore dynamic ones.
    var dark: Bool

    var body: some MapContent {
        if let edge = RoadDebugOverlay.edge(enabled: showEdge, points: feed.matchedEdge) {
            MapPolyline(coordinates: edge.map(\.coordinate))
                .stroke(Color.orange, lineWidth: 6)
        } else if let edge = MatchedRoadLine.edge(points: feed.matchedEdge, onRoadShare: feed.stats?.onRoadShare) {
            // C7: always on in Release: thin and quiet, under the arrow.
            MapPolyline(coordinates: edge.map(\.coordinate))
                .stroke(MatchedRoadLine.color(dark: dark), style: StrokeStyle(
                    lineWidth: MatchedRoadLine.lineWidth, lineCap: .round, lineJoin: .round))
        }
        if let nav = feed.display {
            if NavLayers.showEllipse(nav) {
                MapPolygon(coordinates: EllipsePolygon.ring(nav).map(\.coordinate))
                    .foregroundStyle(Color.blue.opacity(0.15))
                    .stroke(Color.blue.opacity(0.8), lineWidth: 2)
            }
            if NavLayers.showDot(nav) {
                Annotation("", coordinate: nav.position.coordinate) {
                    NavMarker(nav: nav, headingUp: headingUp, cameraHeading: cameraHeading)
                }
            }
        }
    }
}

/// Blue dot; an arrow in heading-up once the heading has converged.
private struct NavMarker: View {
    var nav: NavDisplay
    var headingUp: Bool
    var cameraHeading: Double

    var body: some View {
        if headingUp, nav.converged, let heading = nav.headingDeg {
            Image(systemName: "location.north.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
                .shadow(color: .white, radius: 1)
                .shadow(color: .white, radius: 1)
                .rotationEffect(.degrees(heading - cameraHeading))
        } else {
            Circle()
                .fill(.blue)
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(.white, lineWidth: 3))
        }
    }
}

/// Small icon while the heading has not converged. Its own view: only it
/// re-renders when the estimate changes.
private struct NavCalibratingIcon: View {
    var feed: NavigationFeed

    var body: some View {
        if NavLayers.calibrating(feed.display) {
            Image(systemName: "scope")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HUDColors.accentOnCard)
                .accessibilityLabel("Calibrating heading")
        }
    }
}

extension MapSpeedQuality {
    /// Chip fill: green / amber by GPS accuracy, grey for network or no fix.
    var chipFill: Color {
        switch self {
        case .good: Color(red: 0.12, green: 0.62, blue: 0.25)
        case .fair: Color(red: 0.95, green: 0.65, blue: 0.0)
        case .unknown: Color(white: 0.45)
        }
    }

    var chipText: Color { self == .fair ? .black : .white }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private extension TrackPoint {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private extension LocationSample {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var geo: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}

private extension CLLocationCoordinate2D {
    var geo: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}

// MARK: - Previews (synthetic offsets around (0, 0); no real places)

enum MapPreviewData {
    /// The synthetic estimate of `-uiFakeHUD navFinding|navEllipse|navRoad`
    /// (screenshots, near (0, 0): no real place). Heading 40 degrees.
    @MainActor
    static func fakeNav(_ mode: HUDFakes.FakeNav) -> NavigationFeed {
        let position = GeoPoint(latitude: 0.0004, longitude: 0.0004)
        switch mode {
        case .finding:
            return NavigationFeed(display: NavDisplay(
                position: position, semiMajorM: 2_400, semiMinorM: 1_800, orientationDeg: 20, converged: false))
        case .ellipse:
            // 90 x 20 m, its long axis across a 40-degree heading.
            return NavigationFeed(display: NavDisplay(
                position: position, semiMajorM: 90, semiMinorM: 20, orientationDeg: 130, headingDeg: 40,
                headingStdDeg: 3, converged: true))
        case .road:
            let along = 150.0 / NavGeometry.metersPerDegree
            let (s, c) = (sin(40 * Double.pi / 180), cos(40 * Double.pi / 180))
            let edge = [
                GeoPoint(latitude: position.latitude - along * c, longitude: position.longitude - along * s),
                GeoPoint(latitude: position.latitude + along * c, longitude: position.longitude + along * s),
            ]
            var stats = navStats
            stats.onRoadShare = 0.98
            return NavigationFeed(
                display: NavDisplay(
                    position: position, semiMajorM: 8, semiMinorM: 4, orientationDeg: 40, headingDeg: 40,
                    headingStdDeg: 2, converged: true),
                stats: stats, matchedEdge: edge)
        }
    }

    static func fix(_ i: Int, accuracy: Double, gapAfter: Double = 0) -> LocationSample {
        let t = Double(i) * 2 + gapAfter
        return LocationSample(
            latitude: Double(i) * 0.0002, longitude: sin(Double(i) / 6) * 0.002,
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
            speed: 13.9, speedAccuracy: 1, course: 0, courseAccuracy: 5,
            receivedT: MonotonicTimestamp(seconds: t), ageS: 0
        )
    }

    /// A short line of good fixes, then a stop: 20 fair/poor fixes scattered
    /// about 50 m around one spot, as Wi-Fi/cell positioning gives under jamming.
    static var stopFixes: [LocationSample] {
        var out: [LocationSample] = []
        for i in 0..<12 {
            out.append(LocationSample(
                latitude: Double(i - 12) * 0.00012, longitude: 0, altitude: 0, horizontalAccuracy: 6,
                verticalAccuracy: 5, speed: 8, speedAccuracy: 1, course: 0, courseAccuracy: 5,
                receivedT: MonotonicTimestamp(seconds: Double(i) * 2), ageS: 0))
        }
        for i in 0..<20 {
            // Fixed pseudo-random offsets (no RNG, so screenshots repeat).
            let a = Double((i * 37) % 20) / 10 - 1
            let b = Double((i * 53 + 7) % 20) / 10 - 1
            out.append(LocationSample(
                latitude: a * 0.00045, longitude: b * 0.00045, altitude: 0,
                horizontalAccuracy: i % 3 == 0 ? 110 : (i % 3 == 1 ? 60 : 30),
                verticalAccuracy: 5, speed: 0, speedAccuracy: 1, course: 0, courseAccuracy: 5,
                receivedT: MonotonicTimestamp(seconds: 40 + Double(i) * 3), ageS: 0))
        }
        return out
    }

    static var stopTrack: GPSTrack {
        var track = GPSTrack()
        for f in stopFixes { track.append(f) }
        return track
    }

    static var track: GPSTrack {
        var track = GPSTrack()
        for i in 0..<60 {
            let accuracy: Double
            switch i {
            case ..<15: accuracy = 8
            case ..<30: accuracy = 50
            case ..<40: accuracy = 400
            default: accuracy = 2000
            }
            // A 60 s outage after point 49.
            track.append(fix(i, accuracy: accuracy, gapAfter: i >= 50 ? 60 : 0))
        }
        return track
    }
}

#Preview("Track, all bands + gap") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .fair, isLive: true,
        follow: .constant(FollowController(following: true))
    )
}

#Preview("Stop with scattered fixes") {
    GPSMapView(
        track: MapPreviewData.stopTrack, latest: MapPreviewData.stopFixes.last,
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true))
    )
}

#Preview("Stopped, stale fix") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now - .seconds(12), isReceiving: false, thermal: .nominal,
        isLive: true, follow: .constant(FollowController(following: false))
    )
}

#Preview("Empty") {
    GPSMapView(
        track: GPSTrack(), latest: nil, lastFixInstant: nil, isReceiving: false,
        thermal: .nominal, isLive: true, follow: .constant(FollowController(following: true))
    )
}

#Preview("Not selected") {
    GPSMapView(
        track: MapPreviewData.track, latest: nil, lastFixInstant: nil, isReceiving: false,
        thermal: .serious, isLive: false, follow: .constant(FollowController(following: false))
    )
}

extension MapPreviewData {
    static var confirmed: [ConfirmedFix] {
        [
            ConfirmedFix(id: 0, latitude: 0.004, longitude: 0.0015),
            ConfirmedFix(id: 1, latitude: 0.009, longitude: -0.001),
        ]
    }
}

#Preview("Fix recorded, Undo toast, one pending") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: false)), manualFixes: MapPreviewData.confirmed,
        pendingFixIDs: [1],
        initialToast: MapToast(kind: .recorded(id: 1))
    )
}

#Preview("Zoom in to place the pin") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: false)), manualFixes: MapPreviewData.confirmed,
        initialToast: MapToast(kind: .zoomIn)
    )
}

#Preview("Confirmed fixes") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)), manualFixes: MapPreviewData.confirmed
    )
}

#Preview("Heading up, arrow") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        headingUp: .constant(true), bearing: 40
    )
}

#Preview("Paused, re-centre hint") {
    var paused = FollowController(following: true)
    paused.userGesture(at: ContinuousClock.now)
    return GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(paused)
    )
}

// MARK: - Dead-reckoning previews (fake estimates; no service behind them)

extension MapPreviewData {
    /// Slightly off the last fix, as a live estimate would be.
    static func nav(
        converged: Bool, semiMajorM: Double = 25, semiMinorM: Double = 10, heading: Double? = 12
    ) -> NavDisplay {
        NavDisplay(
            position: GeoPoint(latitude: 59 * 0.0002 + 0.0001, longitude: sin(59.0 / 6) * 0.002 + 0.0001),
            semiMajorM: semiMajorM, semiMinorM: semiMinorM, orientationDeg: 30,
            headingDeg: heading, headingStdDeg: converged ? 3 : 25, converged: converged
        )
    }

    static let navStats = NavStatsDisplay(
        msPerStep: 0.06, maxMsPerStep: 1.4, effectiveSampleSize: 1480,
        headingStdDeg: 3.2, speedScale: 1.016, droppedInputs: 0
    )
}

#Preview("DR, calibrating heading, ellipse") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        navigation: NavigationFeed(display: MapPreviewData.nav(converged: false, semiMajorM: 80, semiMinorM: 30, heading: nil))
    )
}

#Preview("DR, converged, heading up, stats") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        headingUp: .constant(true), bearing: 40,
        navigation: NavigationFeed(display: MapPreviewData.nav(converged: true), stats: MapPreviewData.navStats),
        showNavStats: .constant(true)
    )
}

#Preview("Roads attached: attribution, matched edge, on road") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        navigation: NavigationFeed(
            display: MapPreviewData.nav(converged: true),
            stats: NavStatsDisplay(
                msPerStep: 0.06, maxMsPerStep: 1.4, effectiveSampleSize: 1480,
                headingStdDeg: 3.2, speedScale: 1.016, droppedInputs: 0, onRoadShare: 0.93),
            matchedEdge: (0..<10).map { GeoPoint(latitude: Double(55 + $0) * 0.0002, longitude: sin(Double(55 + $0) / 6) * 0.002) }),
        showNavStats: .constant(true),
        roadsAttribution: true
    )
}

#Preview("No navigation (idle recording)") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        navigation: NavigationFeed(display: nil), showNavStats: .constant(true)
    )
}

// MARK: - Speed block previews

#Preview("Speed: OBD, good GPS (green chip)") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 8, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal,
        speed: MapSpeedReadout(source: .obd, kmh: 54, quality: .good), isLive: true,
        follow: .constant(FollowController(following: true))
    )
}

#Preview("Speed: GPS, fair (amber chip)") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 60, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal,
        speed: MapSpeedReadout(source: .gps, kmh: 54, quality: .fair), isLive: true,
        follow: .constant(FollowController(following: true))
    )
}

#Preview("Speed: OBD, network fix (grey chip)") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: nil, lastFixInstant: nil, isReceiving: false, thermal: .nominal,
        speed: MapSpeedReadout(source: .obd, kmh: 54, quality: .unknown), isLive: true,
        follow: .constant(FollowController(following: true))
    )
}

#Preview("Recording indicator on the map") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 8, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal,
        speed: MapSpeedReadout(source: .obd, kmh: 54, quality: .good), isLive: true,
        follow: .constant(FollowController(following: true)),
        recordingControl: AnyView(MapRecordingIndicatorLabel(elapsed: "12:34")),
        hasActiveRecording: true
    )
}

#Preview("Speed: none") {
    GPSMapView(
        track: GPSTrack(), latest: nil, lastFixInstant: nil, isReceiving: false,
        thermal: .nominal, isLive: true, follow: .constant(FollowController(following: true))
    )
}

#Preview("Speed: stats + thermal, calibrating icon") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .serious,
        speed: MapSpeedReadout(source: .obd, kmh: 112, quality: .good), isLive: true,
        follow: .constant(FollowController(following: true)),
        navigation: NavigationFeed(
            display: MapPreviewData.nav(converged: false, heading: nil), stats: MapPreviewData.navStats
        ),
        showNavStats: .constant(true)
    )
}

#Preview("Roads warning: no packs") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        roadsWarning: RoadsWarning.noPacks
    )
}

#Preview("Roads warning: none covering, with Fix recorded toast") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: false)),
        manualFixes: MapPreviewData.confirmed, pendingFixIDs: [1],
        manual: ManualFixMarking.unavailable,
        initialToast: MapToast(kind: .recorded(id: 1)),
        roadsWarning: RoadsWarning.noneCovering
    )
}

#Preview("Roads warning: refused") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: true)),
        roadsWarning: RoadsWarning.refused
    )
}

// MARK: - HUD previews (layout E)

#Preview("HUD: GPS lost, OBD source") {
    GPSMapView(
        track: MapPreviewData.track, latest: nil, lastFixInstant: nil, isReceiving: false, thermal: .nominal,
        speed: MapSpeedReadout(source: .obd, kmh: 54, quality: .unknown), isLive: true,
        follow: .constant(FollowController(following: true)), headingUp: .constant(true)
    )
}

#Preview("HUD: OBD lost, GPS source, banner, thermal") {
    GPSMapView(
        track: MapPreviewData.track, latest: MapPreviewData.fix(59, accuracy: 8, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .serious,
        speed: MapSpeedReadout(source: .gps, kmh: 54, quality: .good), isLive: true,
        follow: .constant(FollowController(following: true)), headingUp: .constant(true),
        statusLine: AnyView(NavigateStatusLabel(status: .waitingForOBD(secondsLeft: 272)))
    )
}

#Preview("HUD: debug strip, offer, toast, roads credit, recording") {
    GPSMapView(
        track: MapPreviewData.track, latest: MapPreviewData.fix(59, accuracy: 8, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal,
        speed: MapSpeedReadout(source: .obd, kmh: 54, quality: .good), isLive: true,
        follow: .constant(FollowController(following: true)), headingUp: .constant(true),
        initialToast: MapToast(kind: .zoomIn),
        navigation: NavigationFeed(display: MapPreviewData.nav(converged: true), stats: MapPreviewData.navStats),
        showNavStats: .constant(true), roadsAttribution: true,
        offerCard: AnyView(PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))),
        offerShown: true,
        recordingControl: AnyView(MapRecordingIndicatorLabel(elapsed: "12:34")),
        hasActiveRecording: true
    )
}
