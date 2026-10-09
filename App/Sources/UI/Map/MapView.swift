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
    let session: RecordingSession
    var isSelected: Bool
    /// Read once when the tab opens with no fix; the system's last position.
    var cachedLocation: @MainActor () -> CachedLocation?
    @Environment(\.scenePhase) private var scenePhase
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        GPSMapView(
            track: model.track,
            latest: model.latest,
            lastFixInstant: model.lastFixInstant,
            isReceiving: model.isReceiving,
            thermal: thermal,
            isLive: isSelected && scenePhase == .active,
            follow: $model.follow,
            headingUp: $headingUp,
            bearing: model.bearing,
            isStationary: model.isStationary,
            manualFixes: model.manualFixes,
            manual: manualActions,
            recordingFile: model.currentFile,
            cachedLocation: cachedLocation
        )
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onAppear { thermal = ProcessInfo.processInfo.thermalState }
    }
}

extension MapScreen {
    /// Closures only: nothing here reads `session.live` while `body` runs.
    fileprivate var manualActions: ManualFixActions {
        ManualFixActions(
            beginPress: { [session] in session.manualFixPressTime() },
            availability: { [session] in
                ManualFixAvailability(canRecord: session.canRecordManualFix, gate: session.manualFixGate)
            },
            confirm: { [session, model] staged, note, spanM in
                guard let press = staged.press,
                      session.recordManualFix(
                        latitude: staged.latitude, longitude: staged.longitude,
                        pressedAt: press, mapSpanM: spanM, note: note
                      ) else { return false }
                model.addManualFix(latitude: staged.latitude, longitude: staged.longitude, note: note)
                return true
            }
        )
    }
}

/// What the map needs from the recorder for manual fixes. Closures, so the
/// view stays plain and previews can fake them.
struct ManualFixActions {
    /// Call when a long-press begins; nil when not recording.
    var beginPress: @MainActor () -> ManualFixPress?
    /// Read only by the confirm panel.
    var availability: @MainActor () -> ManualFixAvailability
    /// True when the fix was recorded.
    var confirm: @MainActor (StagedFix, String?, Double?) -> Bool

    static let unavailable = ManualFixActions(
        beginPress: { nil },
        availability: { ManualFixAvailability(canRecord: false, gate: .init(speedSource: .unknown, speedKmh: nil, isAllowed: true)) },
        confirm: { _, _, _ in false }
    )
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
            .onChange(of: session.live.obdSpeedKmh, initial: true) { _, kmh in
                model.setOBDSpeed(kmh)
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

/// "last fix N s ago" / "stopped"; the only part that ticks every second.
private struct FixAgeText: View {
    let instant: ContinuousClock.Instant?
    let isReceiving: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let age = instant.map { Int((ContinuousClock.now - $0).components.seconds) } ?? 0
            Text(isReceiving ? "last fix \(max(0, age)) s ago" : "stopped")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
    var manual: ManualFixActions = .unavailable
    /// The recording the map shows; a new one (Start) clears a staged pin.
    var recordingFile: URL?
    /// Last known system position, read when the tab opens with no fix.
    var cachedLocation: @MainActor () -> CachedLocation? = { nil }

    @State private var position: MapCameraPosition = .automatic
    @State private var distance = 1500.0
    /// Visible north-south extent, metres, from the camera.
    @State private var visibleSpanM: Double?
    @State private var isStale = false
    @State private var staged: StagedFix?
    @State private var note = ""
    @State private var notRecorded = false
    @State private var toast: Int?
    @State private var pressBegan = false
    @State private var dragOrigin: CGPoint?
    @State private var smoother = HeadingSmoother()
    /// Copy of the inputs the 10 Hz heading task reads; a task closure would
    /// otherwise see the props from when it started.
    @State private var inputs = HeadingInputs()
    @State private var cameraHeading = 0.0

    struct HeadingInputs: Equatable {
        var fix: LocationSample?
        var bearing: Double?
        var frozen = false
    }

    init(
        track: GPSTrack, latest: LocationSample?, lastFixInstant: ContinuousClock.Instant?,
        isReceiving: Bool, thermal: ProcessInfo.ThermalState, isLive: Bool,
        follow: Binding<FollowController>, headingUp: Binding<Bool> = .constant(false),
        bearing: Double? = nil, isStationary: Bool = false, manualFixes: [ConfirmedFix] = [],
        manual: ManualFixActions = .unavailable,
        recordingFile: URL? = nil,
        cachedLocation: @escaping @MainActor () -> CachedLocation? = { nil },
        initialStaged: StagedFix? = nil
    ) {
        self.track = track
        self.latest = latest
        self.lastFixInstant = lastFixInstant
        self.isReceiving = isReceiving
        self.thermal = thermal
        self.isLive = isLive
        self._follow = follow
        self._headingUp = headingUp
        self.bearing = bearing
        self.isStationary = isStationary
        self.manualFixes = manualFixes
        self.manual = manual
        self.recordingFile = recordingFile
        self.cachedLocation = cachedLocation
        self._staged = State(initialValue: initialStaged)
    }

    var body: some View {
        content
            .onChange(of: latest) { old, fix in
                guard isLive, let fix else { return }
                if old == nil {
                    // First fix of a recording.
                    frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy)
                } else if follow.isFollowing {
                    recenter(fix)
                }
            }
            .onChange(of: HeadingInputs(fix: latest, bearing: bearing, frozen: isStationary), initial: true) { _, new in
                inputs = new
            }
            .onChange(of: staged != nil) { _, isStaged in
                updateFollow { $0.pinStaged(isStaged, at: FollowClock.now) }
            }
            .onChange(of: headingUp) {
                // Mode switch while following: swing the camera to the new heading.
                if follow.isFollowing { moveCameraToCar(duration: 0.6) }
            }
            // Auto-resume: sleeps until the deadline; a new deadline restarts it.
            .task(id: follow.resumeDeadline) {
                guard let deadline = follow.resumeDeadline else { return }
                let wait = deadline - FollowClock.now
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { return }
                }
                var next = follow
                if next.tick(now: FollowClock.now) {
                    follow = next
                    moveCameraToCar(duration: 0.8)
                }
            }
            .task(id: headingActive) { await runHeadingLoop() }
            // Fires on reselect/foreground too.
            .onChange(of: isLive, initial: true) { _, live in
                guard live else { return }
                if let fix = latest {
                    frame(center: fix.coordinate, accuracy: fix.horizontalAccuracy)
                } else if let cached = cachedLocation() {
                    // Camera only: no dot is drawn for it.
                    frame(
                        center: CLLocationCoordinate2D(latitude: cached.latitude, longitude: cached.longitude),
                        accuracy: cached.horizontalAccuracy
                    )
                }
            }
            // Start: a pin staged in the previous recording would be refused.
            .onChange(of: recordingFile) { cancelStaged() }
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
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { toast = nil }
            }
    }

    /// The camera turns with the car: heading-up, following, a bearing exists.
    private var headingActive: Bool {
        headingUp && follow.isFollowing && isLive && bearing != nil
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
                if toast != nil {
                    Label("Fix recorded", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity)
                }
                if isLive, staged != nil {
                    ManualFixPanel(
                        availability: manual.availability,
                        note: $note,
                        notRecorded: notRecorded,
                        onConfirm: confirm,
                        onCancel: cancelStaged
                    )
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
                ForEach(Array(track.runs.enumerated()), id: \.offset) { _, run in
                    if run.points.count >= 2 {
                        MapPolyline(coordinates: run.points.map(\.coordinate))
                            .stroke(run.band.color, lineWidth: 5)
                    }
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
                    Annotation(fix.note ?? "", coordinate: .init(latitude: fix.latitude, longitude: fix.longitude), anchor: .bottom) {
                        Image(systemName: "flag.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.indigo, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                if let staged {
                    Annotation("", coordinate: .init(latitude: staged.latitude, longitude: staged.longitude), anchor: .bottom) {
                        stagedPin(proxy: proxy, staged: staged)
                    }
                }
            }
            .coordinateSpace(.named(Self.space))
            .onMapCameraChange(frequency: .onEnd) { context in
                distance = context.camera.distance
                visibleSpanM = MapFraming.visibleSpanMeters(latitudeDelta: context.region.span.latitudeDelta)
                if abs(context.camera.heading - cameraHeading) > 0.5 { cameraHeading = context.camera.heading }
                // While following this is our own move and is ignored; while
                // paused, only the user (or pan inertia) moves the camera.
                updateFollow { $0.cameraSettled(at: FollowClock.now) }
            }
            // Touch-only gestures turn Following off. No `positionedByUser`:
            // MapKit sets it for changes the user did not make.
            .onMapUserGesture {
                updateFollow { $0.userGesture(at: FollowClock.now) }
            }
            .simultaneousGesture(longPress(proxy: proxy))
        }
    }

    private func stagedPin(proxy: MapProxy, staged: StagedFix) -> some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 44))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .orange)
            .shadow(radius: 3)
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = proxy.convert(
                                CLLocationCoordinate2D(latitude: staged.latitude, longitude: staged.longitude),
                                to: .named(Self.space)
                            )
                        }
                        guard let origin = dragOrigin else { return }
                        let point = CGPoint(
                            x: origin.x + value.translation.width,
                            y: origin.y + value.translation.height
                        )
                        if let c = proxy.convert(point, from: .named(Self.space)) {
                            self.staged?.latitude = c.latitude
                            self.staged?.longitude = c.longitude
                            notRecorded = false
                        }
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }

    /// Long-press drops the pin, only while recording (`beginPress` is nil
    /// otherwise). The press time is taken when the press is recognised.
    private func longPress(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.6)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard !pressBegan, case .second(true, let drag?) = value else { return }
                pressBegan = true
                guard let press = manual.beginPress(),
                      let c = proxy.convert(drag.startLocation, from: .named(Self.space)) else { return }
                staged = StagedFix(latitude: c.latitude, longitude: c.longitude, press: press)
                notRecorded = false
            }
            .onEnded { _ in pressBegan = false }
    }

    private func confirm() {
        guard let staged else { return }
        if manual.confirm(staged, note.isEmpty ? nil : note, visibleSpanM) {
            self.staged = nil
            note = ""
            notRecorded = false
            toast = (toast ?? 0) + 1
        } else {
            notRecorded = true
        }
    }

    private func cancelStaged() {
        staged = nil
        note = ""
        notRecorded = false
    }

    /// Applies the span rule as a region centred on `center`.
    private func frame(center: CLLocationCoordinate2D, accuracy: Double) {
        let span = MapFraming.spanMeters(horizontalAccuracy: accuracy)
        position = .region(MKCoordinateRegion(
            center: center, latitudinalMeters: span, longitudinalMeters: span
        ))
    }

    /// Camera heading for the current mode: 0 north-up, the smoothed bearing heading-up.
    private var targetHeading: Double { headingUp ? (smoother.heading ?? bearing ?? 0) : 0 }

    /// Recentres, keeping the user's current zoom and mode.
    fileprivate func recenter(_ fix: LocationSample) {
        position = .camera(MapCamera(
            centerCoordinate: fix.coordinate, distance: distance, heading: targetHeading, pitch: 0
        ))
    }

    /// Animates back to the car at the current zoom and mode.
    private func moveCameraToCar(duration: Double) {
        guard isLive, let fix = latest else { return }
        withAnimation(.easeInOut(duration: duration)) { recenter(fix) }
    }

    /// ~10 Hz while heading-up: steps the smoother and turns the camera. When
    /// the heading holds (stopped, no new bearing) it writes nothing.
    private func runHeadingLoop() async {
        guard headingActive else { return }
        var last = FollowClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            let now = FollowClock.now
            let before = smoother.heading
            var next = smoother
            let heading = next.step(target: inputs.bearing, frozen: inputs.frozen, dt: now - last)
            last = now
            guard let heading, let fix = inputs.fix else { continue }
            if let before, abs(HeadingSmoother.shortestDelta(from: before, to: heading)) < 0.05 { continue }
            smoother = next
            withAnimation(.linear(duration: 0.1)) {
                position = .camera(MapCamera(
                    centerCoordinate: fix.coordinate, distance: distance, heading: heading, pitch: 0
                ))
            }
        }
    }

    /// Dot north-up; arrow heading-up, turned by bearing minus camera heading
    /// so it points up while following and still shows true direction after
    /// the user rotates the map.
    @ViewBuilder
    private func carMarker(color: Color) -> some View {
        if headingUp, let bearing {
            let shown = follow.isFollowing ? (smoother.heading ?? cameraHeading) : cameraHeading
            Image(systemName: "location.north.fill")
                .font(.system(size: 30))
                .foregroundStyle(color)
                .shadow(color: .white, radius: 1)
                .shadow(color: .white, radius: 1)
                .rotationEffect(.degrees(bearing - shown))
        } else {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 3))
        }
    }

    private func overlay(stale: Bool) -> some View {
        VStack(spacing: 6) {
            Text("REFERENCE GPS — not used by the recorder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let latest, let band = AccuracyBand(accuracy: latest.horizontalAccuracy) {
                HStack(spacing: 10) {
                    Circle().fill(color(band, stale: stale)).frame(width: 16, height: 16)
                    Text("±\(Int(latest.horizontalAccuracy.rounded())) m · \(DisplayFormat.speed(speedKmh(latest))) km/h")
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text(band.label).font(.subheadline).foregroundStyle(.secondary)
                }
                .opacity(stale ? 0.5 : 1)
                if stale {
                    FixAgeText(instant: lastFixInstant, isReceiving: isReceiving)
                }
            } else {
                Text("No fix yet — reference GPS appears here while recording.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            Text("Thermal: \(ThermalText.label(thermal))")
                .font(.caption.weight(.medium))
                .foregroundStyle(ThermalText.tone(thermal).color)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Same rule as the recorder's `gpsSpeedKmh`: negative speed is unavailable.
    private func speedKmh(_ fix: LocationSample) -> Double? {
        fix.speed >= 0 ? fix.speed * 3.6 : nil
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if follow.resumeDeadline != nil {
                resumeHint
            }
            HStack(spacing: 12) {
                headingButton
                followButton
            }
        }
        .padding(16)
    }

    /// Ticks at 1 Hz inside its own TimelineView; the Map is not re-rendered.
    private var resumeHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("Re-centre in \(follow.countdownSeconds(now: FollowClock.now) ?? 1) s")
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
            .font(.headline)
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private var followButton: some View {
        Button {
            let was = follow.isFollowing
            updateFollow { $0.followTapped(at: FollowClock.now) }
            if follow.isFollowing, !was { moveCameraToCar(duration: 0.8) }
        } label: {
            Label(
                follow.isFollowing ? "Following" : "Follow",
                systemImage: follow.isFollowing ? "location.fill" : "location"
            )
            .font(.headline)
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(.regularMaterial, in: Capsule())
        }
    }
}

/// The confirm panel for a staged pin. It exists only while a pin is
/// staged, and it alone calls `availability()`, so the 16 Hz live status
/// invalidates just this body.
private struct ManualFixPanel: View {
    var availability: @MainActor () -> ManualFixAvailability
    @Binding var note: String
    var notRecorded: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        let state = availability()
        let reason = ManualFixText.disabledReason(state)
        VStack(spacing: 10) {
            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .onChange(of: note) { _, new in
                    if new.count > ManualFixSample.maxNoteLength {
                        note = String(new.prefix(ManualFixSample.maxNoteLength))
                    }
                }
            if let reason {
                Text(reason).font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            } else if notRecorded {
                Text("Not recorded").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 56)
                Button(action: onConfirm) {
                    Text("I'm here").font(.title3.weight(.bold)).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(reason != nil)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }
}

private extension TrackPoint {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private extension LocationSample {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
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
            ConfirmedFix(id: 0, latitude: 0.004, longitude: 0.0015, note: "Gate"),
            ConfirmedFix(id: 1, latitude: 0.009, longitude: -0.001, note: nil),
        ]
    }

    static func actions(canRecord: Bool, gate: ManualFixGate.Result) -> ManualFixActions {
        ManualFixActions(
            beginPress: { nil },
            availability: { ManualFixAvailability(canRecord: canRecord, gate: gate) },
            confirm: { _, _, _ in false }
        )
    }
}

#Preview("Staged pin, confirm enabled") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: false)), manualFixes: MapPreviewData.confirmed,
        manual: MapPreviewData.actions(
            canRecord: true, gate: .init(speedSource: .obd, speedKmh: 4, isAllowed: true)),
        initialStaged: StagedFix(latitude: 0.0115, longitude: 0.0005, press: nil)
    )
}

#Preview("Staged pin, too fast") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(FollowController(following: false)), manualFixes: MapPreviewData.confirmed,
        manual: MapPreviewData.actions(
            canRecord: false, gate: .init(speedSource: .obd, speedKmh: 23, isAllowed: false)),
        initialStaged: StagedFix(latitude: 0.0115, longitude: 0.0005, press: nil)
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
    paused.userGesture(at: FollowClock.now)
    return GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now, isReceiving: true, thermal: .nominal, isLive: true,
        follow: .constant(paused)
    )
}
