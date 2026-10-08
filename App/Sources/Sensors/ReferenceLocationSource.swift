import CoreLocation
import DriveLoggerCore
import Foundation

/// Reference GNSS → `location` rows. **Ground truth for later evaluation,
/// never an input** to anything the recorder computes — hence the name, and
/// `latestReferenceFix` is display-only. (The on-disk kind is `location`,
/// frozen since format v1; docs/LOG_FORMAT.md says the same.)
///
/// Configuration, chosen for a clean reference track rather than a pretty
/// one:
/// - `kCLLocationAccuracyBest`, not `…BestForNavigation`, which mixes in
///   other sensor data;
/// - activity type `.otherNavigation`, not `.automotiveNavigation`, so iOS
///   has no reason to snap fixes to roads — a reference that is already
///   map-matched would flatter any later map-matching;
/// - no distance filter, no automatic pausing (fixes keep coming while the
///   car waits at a light);
/// - `allowsBackgroundLocationUpdates` and a `CLBackgroundActivitySession`
///   held while recording, so the app keeps running with the screen locked
///   (the `location` background mode is in Info.plist). When-In-Use
///   authorisation is enough with the session.
///
/// Time (docs/PLAN.md §3.4): `CLLocation.timestamp` is wall clock. At
/// receipt the delegate reads `receivedT = clock.now()` and `Date()`
/// together, once per callback, and stamps each fix at `receivedT - ageS`
/// where `ageS = Date() - fix.timestamp` — the approved exception to "no
/// `Date()` per sample": a difference of two wall-clock readings taken
/// together, so clock jumps during the drive cancel out. Raw `fixTime` is
/// kept so the conversion can be redone offline. Negative `ageS` (a fix
/// stamped after the reading) is kept as is, never clamped.
///
/// Delivery: `CLLocationManager` calls its delegate on the run loop of the
/// thread that created it, which here is the main thread (the only thread
/// with a run loop, and where CoreLocation expects to be driven). The
/// delegate is a separate non-isolated object that only stamps, converts and
/// calls `sink.record` (non-blocking), about once a second. Main-thread
/// latency shows up in `receivedT` only, never in `t`: both readings are
/// taken at the same moment, so a late delivery has a larger `ageS` and the
/// same fix time.
///
/// Background execution (R4.1-5): this is the source that keeps the app
/// running while the phone is locked (`BackgroundExecutionProviding`). With
/// location denied or restricted it is unavailable, there is no background
/// session, and `RecordingSession` warns and writes a row. Authorisation
/// changes are reported through `onAvailabilityChange`.
///
/// Authorisation in the file (M4, docs/BENCH_TEST_2026-10-08.md): the
/// session writes `locationAuthorizationDetail` as a `lifecycle`
/// `locationAuthorization` row at start; the delegate writes another on
/// every authorisation change while recording; and a CoreLocation error row
/// carries the authorisation read when it arrived. A `kCLErrorDenied`
/// (`Code=1`) does not stop the source (it never did): it can be
/// transient — the bench saw fixes keep coming after one — and while
/// authorisation is really denied CoreLocation delivers nothing anyway. It is a
/// background risk only if authorisation really reads denied or restricted;
/// then the delegate reports an availability change, `availability` says
/// unavailable, and the session warns and writes its row. While
/// authorisation reads `authorizedWhenInUse`/`authorizedAlways` it is only
/// the error row.
///
/// Untested on hardware: fix rate and accuracy in the car, background
/// survival with `CLBackgroundActivitySession`, and whether `.otherNavigation`
/// avoids road snapping (docs/PLAN.md §6).
@MainActor
final class ReferenceLocationSource: SensorSource, LiveReferenceFixReporting, BackgroundExecutionProviding,
    LocationAuthorizationReporting {
    let name = "referenceLocation"

    /// The most recent fix, for the dashboard only. Never written anywhere
    /// and never an input.
    private(set) var latestReferenceFix: LocationSample?

    private let manager: CLLocationManager
    /// Internal for tests (`handleFailure(_:authorization:)`).
    let delegate = ReferenceLocationDelegate()
    /// Where authorisation is read: `manager` in the app, a fake in tests.
    private let authorization: any LocationAuthorizationProviding
    private var backgroundSession: CLBackgroundActivitySession?
    private var running = false

    /// Called on the main actor after each authorisation change
    /// (`locationManagerDidChangeAuthorization`, which CoreLocation also
    /// calls once when the manager is created).
    var onAvailabilityChange: (@MainActor () -> Void)?

    /// - Parameter authorization: nil reads the source's own
    ///   `CLLocationManager`; tests pass a fake.
    init(authorization: (any LocationAuthorizationProviding)? = nil) {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorization = authorization ?? manager
        manager.delegate = delegate
        delegate.observeAuthorization { [weak self] in
            Task { @MainActor in self?.onAvailabilityChange?() }
        }
    }

    var availability: SensorAvailability {
        switch authorization.authorizationStatus {
        case .denied:
            .unavailable(reason: "Location access is denied, or Location Services are off (Settings → Privacy & Security → Location Services)")
        case .restricted:
            .unavailable(reason: "Location access is restricted on this device")
        case .notDetermined, .authorizedWhenInUse, .authorizedAlways:
            .available
        @unknown default:
            .available
        }
    }

    /// Asks for When-In-Use authorisation if it was never asked; fixes start
    /// arriving once the user allows it.
    func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        if case .unavailable(let reason) = availability {
            throw SensorStartError(source: name, reason: reason)
        }
        let gate = SampleGate(source: name, clock: clock, sink: sink)
        delegate.begin(gate: gate) { [weak self] fix in
            Task { @MainActor in self?.latestReferenceFix = fix }
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if authorization.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        backgroundSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
        running = true
    }

    /// `detail` of the `locationAuthorization` row: authorisation now and
    /// whether this source holds a `CLBackgroundActivitySession` (`held`
    /// after a successful `start`; `none` before, after `stop`, or when it
    /// could not start). "held" means the app holds one; iOS does not
    /// confirm that it keeps the app running.
    var locationAuthorizationDetail: String {
        LocationAuthorizationSnapshot(authorization).detail(backgroundActivitySessionHeld: backgroundSession != nil)
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        delegate.end()
        latestReferenceFix = nil
    }
}

/// A source that can show its latest reference fix on the dashboard
/// (`RecordingSession.live.gpsSpeedKmh`). Display only: the fix is a copy
/// of one already handed to the sink, never written again and never an
/// input. `ReferenceLocationSource` on a phone; Core's
/// `SimulatedLocationSource` in simulator builds (M2-S2).
@MainActor
protocol LiveReferenceFixReporting: AnyObject {
    var latestReferenceFix: LocationSample? { get }
}

/// A source whose running keeps the app executing while the phone is locked
/// (R4.1-5) — on a phone, `ReferenceLocationSource` with its
/// `CLBackgroundActivitySession`. `RecordingSession` warns
/// (`backgroundRiskWarning`) and writes a `lifecycle` `error` row when every
/// such source is unavailable or did not start.
@MainActor
protocol BackgroundExecutionProviding: SensorSource {
    /// Called on the main actor whenever `availability` may have changed
    /// (the location prompt answered, authorisation changed in Settings).
    /// Set by `RecordingSession`, its one observer.
    var onAvailabilityChange: (@MainActor () -> Void)? { get set }
}

/// A source that reports location authorisation for the `lifecycle`
/// `locationAuthorization` row `RecordingSession` writes at start (M4).
@MainActor
protocol LocationAuthorizationReporting: SensorSource {
    /// Free text: `authorizationStatus=<…>, accuracyAuthorization=<…>,
    /// backgroundActivitySession=<held|none>`.
    var locationAuthorizationDetail: String { get }
}

/// Where location authorisation is read. `CLLocationManager` in the app; a
/// fake in tests.
protocol LocationAuthorizationProviding: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
}

extension CLLocationManager: LocationAuthorizationProviding {}

/// Location authorisation at one moment, as written in rows. The names are
/// the Swift case names (`authorizedWhenInUse`, not the raw number), so the
/// text stays readable without the SDK headers.
struct LocationAuthorizationSnapshot: Hashable, Sendable {
    var status: CLAuthorizationStatus
    var accuracy: CLAccuracyAuthorization

    init(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        self.status = status
        self.accuracy = accuracy
    }

    init(_ provider: any LocationAuthorizationProviding) {
        self.init(status: provider.authorizationStatus, accuracy: provider.accuracyAuthorization)
    }

    /// Denied (by the user, or Location Services off) or restricted: no
    /// fixes and no background location session.
    var isDeniedOrRestricted: Bool {
        status == .denied || status == .restricted
    }

    var statusName: String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedWhenInUse: "authorizedWhenInUse"
        case .authorizedAlways: "authorizedAlways"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    var accuracyName: String {
        switch accuracy {
        case .fullAccuracy: "full"
        case .reducedAccuracy: "reduced"
        @unknown default: "unknown(\(accuracy.rawValue))"
        }
    }

    /// `authorizationStatus=<…>, accuracyAuthorization=<…>`.
    var detail: String {
        "authorizationStatus=\(statusName), accuracyAuthorization=\(accuracyName)"
    }

    /// `detail` plus `, backgroundActivitySession=<held|none>`.
    func detail(backgroundActivitySessionHeld held: Bool) -> String {
        "\(detail), backgroundActivitySession=\(held ? "held" : "none")"
    }
}

/// `CLLocationManagerDelegate` for `ReferenceLocationSource`. Not isolated to
/// the main actor: it touches only its lock-guarded gate.
final class ReferenceLocationDelegate: NSObject, CLLocationManagerDelegate, Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`. nil while not recording.
    private nonisolated(unsafe) var gate: SampleGate?
    /// Guarded by `lock`. Display hook for each fix.
    private nonisolated(unsafe) var onFix: (@Sendable (LocationSample) -> Void)?
    /// Guarded by `lock`. Called after every authorisation change, recording
    /// or not.
    private nonisolated(unsafe) var onAuthorizationChange: (@Sendable () -> Void)?

    func observeAuthorization(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onAuthorizationChange = handler }
    }

    func begin(gate: SampleGate, onFix: @escaping @Sendable (LocationSample) -> Void) {
        lock.withLock {
            self.gate = gate
            self.onFix = onFix
        }
    }

    /// No fix reaches the sink after this returns.
    func end() {
        let gate = lock.withLock { () -> SampleGate? in
            defer {
                self.gate = nil
                self.onFix = nil
            }
            return self.gate
        }
        gate?.close()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Both readings first, together, before anything else (§3.4).
        let (gate, onFix) = lock.withLock { (self.gate, self.onFix) }
        guard let gate else { return }
        let receivedT = gate.clock.now()
        let receivedWall = Date()
        let events = locations.map {
            ReferenceFix.event(from: $0, receivedT: receivedT, receivedWallClock: receivedWall)
        }
        gate.deliver(events)
        if let last = events.last, case .location(let fix) = last.payload {
            onFix?(fix)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        handleFailure(error, authorization: LocationAuthorizationSnapshot(manager))
    }

    /// `didFailWithError` with the authorisation read when it arrived;
    /// internal so tests can pass a fake one.
    ///
    /// - `locationUnknown`: nothing (transient; CoreLocation keeps trying).
    /// - Anything else: an `error` row `referenceLocation: <error>
    ///   (authorizationStatus=<…>, accuracyAuthorization=<…>)`, once per
    ///   distinct text. Updates are never stopped here.
    /// - `denied` while authorisation reads denied or restricted: also an
    ///   availability change, so the session re-reads `availability` and
    ///   writes its background-risk row. While authorisation reads
    ///   anything else the `denied` is treated as transient: no change is
    ///   reported, so no background-risk row.
    func handleFailure(_ error: any Error, authorization: LocationAuthorizationSnapshot) {
        let (gate, onChange) = lock.withLock { (self.gate, self.onAuthorizationChange) }
        let code = (error as? CLError)?.code
        if code == .locationUnknown { return }
        gate?.report("\(String(describing: error)) (\(authorization.detail))")
        if code == .denied, authorization.isDeniedOrRestricted {
            onChange?()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange(LocationAuthorizationSnapshot(manager))
    }

    /// `locationManagerDidChangeAuthorization`; internal so tests can pass a
    /// fake authorisation. While recording: a `locationAuthorization` row
    /// with the new authorisation, plus the existing `error` row when it is
    /// denied or restricted. Always: an availability change.
    func handleAuthorizationChange(_ authorization: LocationAuthorizationSnapshot) {
        let (gate, onChange) = lock.withLock { (self.gate, self.onAuthorizationChange) }
        if let gate {
            gate.deliver(LogEvent(
                timestamp: gate.clock.now(),
                payload: .lifecycle(LifecycleSample(.locationAuthorization, detail: authorization.detail))
            ))
        }
        switch authorization.status {
        case .denied:
            gate?.report("authorization denied while recording; no more reference fixes")
        case .restricted:
            gate?.report("authorization restricted while recording; no more reference fixes")
        default:
            break
        }
        onChange?()
    }
}

/// `CLLocation` → `location` row, field for field.
enum ReferenceFix {
    /// `t = receivedT - ageS`, with `ageS = receivedWallClock - fix.timestamp`
    /// (docs/PLAN.md §3.4), never clamped. `fixTime` is `CLLocation.timestamp`
    /// in ISO 8601 with fractional seconds (millisecond resolution; `ageS`
    /// carries the full precision).
    nonisolated static func event(
        from location: CLLocation,
        receivedT: MonotonicTimestamp,
        receivedWallClock: Date
    ) -> LogEvent {
        let ageS = receivedWallClock.timeIntervalSince(location.timestamp)
        let t = MonotonicTimestamp(nanoseconds: receivedT.nanoseconds - Int64((ageS * 1_000_000_000).rounded()))
        let source = location.sourceInformation
        let sample = LocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            course: location.course,
            courseAccuracy: location.courseAccuracy,
            receivedT: receivedT,
            fixTime: location.timestamp.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            ageS: ageS,
            ellipsoidalAltitude: location.ellipsoidalAltitude,
            simulated: source?.isSimulatedBySoftware,
            accessory: source?.isProducedByAccessory
        )
        return .location(sample, at: t)
    }
}
