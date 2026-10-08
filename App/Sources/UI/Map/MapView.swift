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
    var isSelected: Bool
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
            followsUser: $model.followsUser
        )
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onAppear { thermal = ProcessInfo.processInfo.thermalState }
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

    var track: GPSTrack
    var latest: LocationSample?
    var lastFixInstant: ContinuousClock.Instant?
    /// False before the first fix and after Stop.
    var isReceiving: Bool
    var thermal: ProcessInfo.ThermalState
    /// Selected tab and active scene. When false no `Map` exists and the
    /// camera is not touched.
    var isLive: Bool
    @Binding var followsUser: Bool

    @State private var position: MapCameraPosition = .automatic
    @State private var distance = 1500.0

    @State private var isStale = false

    var body: some View {
        content
            .onChange(of: latest) { _, fix in
                if isLive, followsUser, let fix { recenter(fix) }
            }
            // Fires on reselect/foreground too, so following recentres then.
            .onChange(of: isLive, initial: true) { _, live in
                if live, followsUser, let fix = latest { recenter(fix) }
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
        .overlay(alignment: .bottomTrailing) { followButton }
    }

    private func color(_ band: AccuracyBand, stale: Bool) -> Color {
        stale ? .gray : band.color
    }

    private func mapBody(stale: Bool) -> some View {
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
                    Circle()
                        .fill(c)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            distance = context.camera.distance
        }
        .onChange(of: position) { _, new in
            // Only a user gesture sets this; our own recentring does not.
            if new.positionedByUser { followsUser = false }
        }
    }

    fileprivate func recenter(_ fix: LocationSample) {
        position = .camera(MapCamera(centerCoordinate: fix.coordinate, distance: distance))
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

    private var followButton: some View {
        Button {
            followsUser.toggle()
            if followsUser, isLive, let latest { recenter(latest) }
        } label: {
            Label(followsUser ? "Following" : "Follow", systemImage: followsUser ? "location.fill" : "location")
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(16)
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
        followsUser: .constant(true)
    )
}

#Preview("Stopped, stale fix") {
    GPSMapView(
        track: MapPreviewData.track,
        latest: MapPreviewData.fix(59, accuracy: 12, gapAfter: 60),
        lastFixInstant: .now - .seconds(12), isReceiving: false, thermal: .nominal,
        isLive: true, followsUser: .constant(false)
    )
}

#Preview("Empty") {
    GPSMapView(
        track: GPSTrack(), latest: nil, lastFixInstant: nil, isReceiving: false,
        thermal: .nominal, isLive: true, followsUser: .constant(true)
    )
}

#Preview("Not selected") {
    GPSMapView(
        track: MapPreviewData.track, latest: nil, lastFixInstant: nil, isReceiving: false,
        thermal: .serious, isLive: false, followsUser: .constant(false)
    )
}
