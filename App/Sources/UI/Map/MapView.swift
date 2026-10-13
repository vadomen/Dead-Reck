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
    var isSelected: Bool
    /// Read once when the tab opens with no fix; the system's last position.
    var cachedLocation: @MainActor () -> CachedLocation?
    /// Start was tapped: the app opens Settings, Recording.
    var onStart: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
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
            recordingFile: model.currentFile,
            cachedLocation: cachedLocation,
            navigation: navigation,
            showNavStats: $showNavStats,
            recordingControl: AnyView(MapRecordingButton(session: session, onStart: onStart, onStop: { [session] in await session.stop() }))
        )
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onAppear { thermal = ProcessInfo.processInfo.thermalState }
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
/// that observes `session.live`, so the 16 Hz OBD updates re-run just this
/// trivial body and not the tab hierarchy.
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
            .onChange(of: session.live.referenceFix) { _, fix in
                model.ingest(
                    fix, file: session.currentFile, isActive: scenePhase == .active,
                    elapsed: session.live.elapsed
                )
            }
            // A new Start resets the track before its first fix arrives.
            .onChange(of: session.currentFile) { _, file in
                model.ingest(
                    session.live.referenceFix, file: file, isActive: scenePhase == .active,
                    elapsed: session.live.elapsed
                )
            }
            .onChange(of: scenePhase) { _, phase in
                // Pick up a change missed while inactive.
                if phase == .active {
                    model.ingest(
                        session.live.referenceFix, file: session.currentFile, isActive: true,
                        elapsed: session.live.elapsed
                    )
                }
            }
    }
}

extension MapFeed {
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
    var recordingFile: URL?
    /// Last known system position, read when the tab opens with no fix.
    var cachedLocation: @MainActor () -> CachedLocation? = { nil }
    /// Live dead reckoning; nil in previews of the plain reference map.
    var navigation: NavigationFeed?
    @Binding var showNavStats: Bool
    /// Start button or recording indicator, left of the map controls. A view
    /// of its own (it reads the recorder), so this view stays plain values.
    var recordingControl: AnyView?

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
        recordingFile: URL? = nil,
        cachedLocation: @escaping @MainActor () -> CachedLocation? = { nil },
        initialToast: MapToast? = nil,
        navigation: NavigationFeed? = nil,
        showNavStats: Binding<Bool> = .constant(false),
        recordingControl: AnyView? = nil
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
        self.recordingFile = recordingFile
        self.cachedLocation = cachedLocation
        self.navigation = navigation
        self._showNavStats = showNavStats
        self.recordingControl = recordingControl
        self._toast = State(initialValue: initialToast)
    }

    var body: some View {
        content
            .onChange(of: latest) { old, fix in
                guard isLive, let fix else { return }
                if old == nil {
                    // First fix of a recording.
                    frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy)
                } else if follow.isFollowing, navigation?.latest == nil {
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
                while let deadline = follow.resumeDeadline {
                    if ContinuousClock.now < deadline {
                        try? await Task.sleep(until: deadline, clock: .continuous)
                        if Task.isCancelled { return }
                    }
                    if resumeIfDue() { return }
                }
            }
            // One 100 ms loop while the map is visible and the scene active:
            // polls the navigation feed, then turns/centres the camera.
            .task(id: isLive) { await runLoop() }
            // Fires on reselect/foreground too.
            .onChange(of: isLive, initial: true) { _, live in
                guard live else { return }
                // A deadline that passed while away (screen off, other tab).
                resumeIfDue()
                if let fix = latest {
                    frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy)
                } else if let nav = navigation?.latest {
                    frame(center: nav.position.coordinate, accuracy: nav.semiMajorM / 3)
                } else if let cached = cachedLocation() {
                    // Camera only: no dot is drawn for it.
                    frame(
                        center: CLLocationCoordinate2D(latitude: cached.latitude, longitude: cached.longitude),
                        accuracy: cached.horizontalAccuracy
                    )
                }
            }
            // Start: a toast from the previous recording would offer a dead Undo.
            .onChange(of: recordingFile) {
                toast = nil
                headingState.smoother = HeadingSmoother()
                headingState.gate.reset()
            }
            // No bearing: nothing to turn to; drop a stale smoothed heading.
            .onChange(of: bearing) { _, new in
                if new == nil, effectiveBearing == nil { headingState.smoother = HeadingSmoother() }
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
        let nav = navigation?.latest
        return CameraHeading.targetBearing(
            drHeading: nav?.headingDeg, converged: nav?.converged ?? false, gpsBearing: bearing
        )
    }

    /// Where Following centres: the estimate once initialised, else the GPS fix.
    private var followCenter: CLLocationCoordinate2D? {
        FollowTarget.center(dr: navigation?.latest?.position, gps: latest?.geo)?.coordinate
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

    private var stale: Bool { isStale || !isReceiving }

    private var content: some View {
        ZStack(alignment: .top) {
            if isLive {
                mapBody(stale: stale)
            } else {
                Color(.secondarySystemBackground).ignoresSafeArea()
            }
            overlay(stale: stale)
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                if let toast {
                    toastView(toast)
                }
                controls
            }
        }
    }

    private func color(_ band: AccuracyBand, stale: Bool) -> Color {
        stale ? .gray : band.color
    }

    private func mapBody(stale: Bool) -> some View {
        MapReader { proxy in
            Map(position: $position) {
                TrackOverlay(track: track)
                if let navigation {
                    NavOverlay(feed: navigation, headingUp: headingUp, cameraHeading: cameraHeading)
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
            .onMapCameraChange(frequency: .onEnd) { context in
                // Not our own write: the driver zoomed.
                headingState.zoom.cameraReported(distance: context.camera.distance)
                if let span = MapFraming.visibleSpanMeters(latitudeDelta: context.region.span.latitudeDelta),
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
                    .buttonStyle(.borderedProminent)
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
        let center = navigation?.latest?.position.coordinate ?? center
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
        let d = followDistance(navigation?.latest)
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

    /// ~10 Hz while the map is visible. Polls the navigation feed, steps the
    /// heading smoother and, while following, writes the camera: when the
    /// feed published a new estimate, or (heading-up) the heading moved
    /// enough. When nothing changed it writes nothing.
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
            let nav = navigation?.latest
            let target = CameraHeading.targetBearing(
                drHeading: nav?.headingDeg, converged: nav?.converged ?? false, gpsBearing: inputs.bearing
            )
            headingState.zoom.step(speedKmh: inputs.speedKmh.map(Double.init), dt: dt)
            guard inputs.following else { continue }
            var heading = 0.0
            var write = published
            let zoomWrite = headingState.zoom.autoWantsWrite
            if inputs.headingUp {
                if target == nil {
                    headingState.smoother = HeadingSmoother()
                } else if let h = headingState.smoother.step(target: target, frozen: inputs.frozen, dt: dt) {
                    heading = h
                    if headingState.gate.admit(h, at: now) { write = true }
                }
            }
            // Without an estimate the GPS onChange recentres north-up;
            // heading-up still turns around the fix.
            guard write || zoomWrite, let center = FollowTarget.center(dr: nav?.position, gps: inputs.fix?.geo),
                  nav != nil || (inputs.headingUp && target != nil) || zoomWrite else { continue }
            let d = followDistance(nav)
            headingState.gate.noteWrite(heading, at: now)
            withAnimation(.linear(duration: 0.25)) {
                position = .camera(MapCamera(
                    centerCoordinate: center.coordinate, distance: d, heading: heading, pitch: 0
                ))
            }
        }
    }

    /// Dot north-up; arrow heading-up, turned by bearing minus camera heading
    /// so it points up while following and still shows true direction after
    /// the user rotates the map.
    @ViewBuilder
    private func carMarker(color: Color) -> some View {
        if headingUp, let bearing, navigation?.latest == nil {
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
                if let navigation {
                    NavCalibratingIcon(feed: navigation)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(speed.summary)
            if showNavStats {
                if let navigation {
                    NavStatsView(feed: navigation)
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
            .foregroundStyle(active ? Color.white : Color.primary)
            .padding(.horizontal, 18)
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

    var body: some MapContent {
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
        Text(feed.stats?.line ?? "nav: idle")
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
