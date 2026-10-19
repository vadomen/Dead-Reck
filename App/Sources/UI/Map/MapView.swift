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
    @Environment(\.scenePhase) private var scenePhase
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        // Without OBD, Navigate shows the plain GPS position only (UX-1 (d)):
        // no dead-reckoning dot or ellipse.
        let status = NavigateStatus.make(
            navigate: session.navigateState, recording: session.state, startedAt: session.navigateStartedAt,
            timings: session.navigateTimings ?? NavigateConfiguration(), now: .now)
        GPSMapView(
            track: model.track,
            latest: model.latest,
            lastFixInstant: model.lastFixInstant,
            isReceiving: model.isReceiving,
            thermal: thermal,
            speed: model.speed,
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
            navigation: navigation,
            showsEstimate: status.showsEstimate,
            showNavStats: $showNavStats,
            roadsWarning: roadsWarning?.message,
            onRoadsWarningTap: onOpenMaps,
            onOpenSettings: onOpenSettings,
            roadsAttribution: roadsWarning?.attribution ?? false,
            offerCard: offers.map { AnyView(PackOfferCard(monitor: $0)) },
            recordingControl: AnyView(MapRecordingButton(
                session: session, offers: offers, onStop: { [session] in await session.stop() })),
            statusLine: AnyView(MapNavigateStatusLine(session: session))
        )
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onAppear { thermal = ProcessInfo.processInfo.thermalState }
        // The card may only appear while the map is on screen (UX-8).
        .onChange(of: isSelected && scenePhase == .active, initial: true) { _, visible in
            offers?.isMapVisible = visible
        }
    }
}

extension MapScreen {
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: session.live.obdSpeedKmh, initial: true) { refreshStationary() }
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
    var onRoadsWarningTap: () -> Void
    /// The Settings gear. TEMPORARY placement bottom right (UX-14); UX-32
    /// moves it into the right rail.
    var onOpenSettings: () -> Void = {}
    /// A road pack is attached to the run (`MapAttribution.visible`): the
    /// OSM credit is shown.
    var roadsAttribution = false
    /// The at-a-stop road-pack offer (UX-8), above the status line; its own
    /// view, so this one stays plain values.
    var offerCard: AnyView?
    /// Start button or recording indicator, left of the map controls. A view
    /// of its own (it reads the recorder), so this view stays plain values.
    var recordingControl: AnyView?
    /// Navigate's status line (UX-1), above the controls.
    var statusLine: AnyView?

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
        onRoadsWarningTap: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        roadsAttribution: Bool = false,
        offerCard: AnyView? = nil,
        recordingControl: AnyView? = nil,
        statusLine: AnyView? = nil
    ) {
        self.track = track
        self.latest = latest
        self.lastFixInstant = lastFixInstant
        self.isReceiving = isReceiving
        self.thermal = thermal
        self.speed = speed
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
        self.onRoadsWarningTap = onRoadsWarningTap
        self.onOpenSettings = onOpenSettings
        self.roadsAttribution = roadsAttribution
        self.offerCard = offerCard
        self.recordingControl = recordingControl
        self.statusLine = statusLine
        self._toast = State(initialValue: initialToast)
    }

    var body: some View {
        content
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
            .task(id: MapLoopKey(isLive: isLive, showsEstimate: showsEstimate)) {
                await frameOnOpen()
                await runLoop()
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
        ZStack(alignment: .top) {
            if isLive && !Self.hidesTiles {
                mapBody(stale: stale)
            } else {
                Color(.secondarySystemBackground).ignoresSafeArea()
            }
            overlay(stale: stale)
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                if roadsAttribution {
                    attributionLabel
                }
                // Above the fix toast and the controls: stacked, never overlapping.
                if let offerCard {
                    offerCard
                }
                if let statusLine {
                    statusLine
                }
                if let roadsWarning {
                    roadsWarningView(roadsWarning)
                }
                if let toast {
                    toastView(toast)
                }
                controls
            }
        }
    }

    /// Small credit above the controls, clear of Apple's logo and Legal link
    /// (bottom corners, below the controls). Material keeps it legible in
    /// light and dark.
    private var attributionLabel: some View {
        Text(MapAttribution.text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .accessibilityLabel(MapAttribution.text)
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
                TrackOverlay(track: track)
                if let estimate {
                    NavOverlay(feed: estimate, headingUp: headingUp, cameraHeading: cameraHeading, showEdge: showNavStats)
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
        Button(action: onRoadsWarningTap) {
            Label(text, systemImage: "road.lanes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.orange, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
        case .alreadyRecorded:
            Label("Already recorded, not undone", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity)
        case .zoomIn:
            Label(PinPrecision.hint, systemImage: "plus.magnifyingglass")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity)
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
                centerCoordinate: center, distance: framed, heading: targetHeading, pitch: 0
            ))
            return
        }
        headingState.zoom.frame(distance: nil)
        position = .region(MKCoordinateRegion(
            center: center, latitudinalMeters: span, longitudinalMeters: span
        ))
    }

    /// Camera heading for the current mode: 0 north-up, the smoothed bearing heading-up.
    private var targetHeading: Double {
        CameraHeading.choose(headingUp: headingUp, bearing: effectiveBearing, smoothed: headingState.smoother.heading)
    }

    /// Camera distance for a write: the driver's zoom; in heading-up with an
    /// estimate, widened to fit its ellipse (`FollowZoom`).
    private func followDistance(_ nav: NavDisplay?) -> Double {
        headingState.zoom.autoFollowDistance(headingUp: headingUp, semiMajorM: nav?.semiMajorM)
    }

    /// Recentres, keeping the user's current zoom and mode.
    fileprivate func recenter(center: CLLocationCoordinate2D) {
        let heading = targetHeading
        headingState.gate.noteWrite(heading, at: ContinuousClock.now)
        let d = followDistance(estimate?.latest)
        position = .camera(MapCamera(centerCoordinate: center, distance: d, heading: heading, pitch: 0))
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
        if let fix = latest {
            frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy)
        } else if let nav {
            frame(center: nav.position.coordinate, accuracy: nav.semiMajorM / 3)
        } else if let cached = cachedLocation() {
            // Camera only: no dot is drawn for it.
            frame(
                center: CLLocationCoordinate2D(latitude: cached.latitude, longitude: cached.longitude),
                accuracy: cached.horizontalAccuracy
            )
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
            headingState.zoom.step(speedKmh: inputs.speedKmh.map(Double.init), dt: dt)
            guard inputs.following else { continue }
            let center = FollowTarget.center(dr: nav?.position, gps: inputs.fix?.geo)
            guard let camera = FollowCameraTick.decide(
                smoother: &headingState.smoother, gate: &headingState.gate, zoom: &headingState.zoom,
                publishPending: &headingState.publishPending,
                published: published, headingUp: inputs.headingUp, frozen: inputs.frozen, target: target,
                hasEstimate: nav != nil, hasCenter: center != nil, semiMajorM: nav?.semiMajorM,
                dt: dt, now: now
            ), let center else { continue }
            withAnimation(.linear(duration: 0.25)) {
                position = .camera(MapCamera(
                    centerCoordinate: center.coordinate, distance: camera.distance, heading: camera.heading, pitch: 0
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

    /// Speed and its source only. The long-press on the number is the hidden
    /// switch for the navigation stats (and thermal) lines.
    private func overlay(stale: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(speed.valueText)
                    .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    // Hidden debug switch: long-press toggles the navigation stats lines.
                    .onLongPressGesture(minimumDuration: 1) { showNavStats.toggle() }
                Text("km/h")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let chip = speed.sourceText {
                    Text(chip)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(speed.quality.chipText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(speed.quality.chipFill, in: Capsule())
                }
                if let estimate {
                    NavCalibratingIcon(feed: estimate)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(speed.summary)
            if showNavStats {
                if let estimate {
                    NavStatsView(feed: estimate)
                }
                Text("Thermal: \(ThermalText.label(thermal))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ThermalText.tone(thermal).color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let recordingControl { recordingControl }
                Spacer(minLength: 0)
                if follow.resumeDeadline != nil {
                    resumeHint
                }
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                headingButton
                followButton
                settingsButton
            }
        }
        .padding(16)
    }

    /// Ticks at 1 Hz inside its own TimelineView; the Map is not re-rendered.
    private var resumeHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("Re-centre in \(follow.countdownSeconds(now: ContinuousClock.now) ?? 1) s")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var headingButton: some View {
        Button {
            headingUp.toggle()
        } label: {
            Label(
                headingUp ? "Heading up" : "North up",
                systemImage: headingUp ? "location.north.line.fill" : "n.circle.fill"
            )
            .mapControlStyle(active: headingUp)
        }
    }

    /// TEMPORARY (UX-14): UX-32 puts the gear at the bottom of the right rail.
    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundStyle(Color.primary)
                .frame(width: 56, height: 56)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .accessibilityLabel("Settings")
    }

    private var followButton: some View {
        Button {
            let was = follow.isFollowing
            updateFollow { $0.followTapped(at: ContinuousClock.now) }
            if follow.isFollowing, !was { moveCameraToCar(duration: 0.8) }
        } label: {
            Label(
                follow.isFollowing ? "Following" : "Follow",
                systemImage: follow.isFollowing ? "location.fill" : "location"
            )
            .mapControlStyle(active: follow.isFollowing)
        }
    }
}

private extension View {
    /// Map control capsule. The default tint (dark blue on a dark material)
    /// is unreadable in dark mode, so the colours are explicit: white on solid
    /// blue when the mode is on, primary text on material when it is off.
    func mapControlStyle(active: Bool) -> some View {
        self
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(active ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background {
                if active {
                    Capsule().fill(Color.blue)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(active ? 0 : 0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

/// The track polylines, keyed on `track` only: heading changes do not touch it.
private struct TrackOverlay: MapContent {
    var track: GPSTrack

    var body: some MapContent {
        // Fixes worse than 1000 m: faded dots, not part of the line.
        ForEach(track.faded, id: \.t) { point in
            Annotation("", coordinate: point.coordinate) {
                Circle()
                    .fill(AccuracyBand.bad.color.opacity(0.3))
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

    var body: some MapContent {
        if let edge = RoadDebugOverlay.edge(enabled: showEdge, points: feed.matchedEdge) {
            MapPolyline(coordinates: edge.map(\.coordinate))
                .stroke(Color.orange, lineWidth: 6)
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
                .accessibilityLabel("Calibrating heading")
        }
    }
}

/// The optional debug stats line.
private struct NavStatsView: View {
    var feed: NavigationFeed

    var body: some View {
        VStack(spacing: 2) {
            Text(feed.stats?.line ?? "nav: idle")
            if let share = RoadDebugOverlay.shareLine(enabled: true, share: feed.stats?.onRoadShare) {
                Text(share)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
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
    static func fix(_ i: Int, accuracy: Double, gapAfter: Double = 0) -> LocationSample {
        let t = Double(i) * 2 + gapAfter
        return LocationSample(
            latitude: Double(i) * 0.0002, longitude: sin(Double(i) / 6) * 0.002,
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
            speed: 13.9, speedAccuracy: 1, course: 0, courseAccuracy: 5,
            receivedT: MonotonicTimestamp(seconds: t), ageS: 0
        )
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
        recordingControl: AnyView(MapRecordingIndicatorLabel(elapsed: "12:34"))
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
