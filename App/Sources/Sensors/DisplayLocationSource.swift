import CoreLocation
import DriveLoggerCore
import Foundation

/// A location feed **for the map only**, running while no run owns location
/// (R61.1-4, UX-1 decision (d)): Navigate off or waiting for the adapter, no
/// recording, app active. It has no clock, no sink, no gate, no engine and
/// no tap: a fix goes to `onFix` and nowhere else, so nothing it sees can be
/// written or reach navigation. `RecordingSession` owns the lifecycle
/// (`updateDisplayLocation`): it stops this before a run's sources start
/// (Navigate's or Record's, which own location while they run) and starts it
/// again when the run has ended and the app is still active. At most one
/// location consumer runs at any time.
///
/// Never background location: no `allowsBackgroundLocationUpdates`, no
/// `CLBackgroundActivitySession`; the session stops it when the scene is not
/// active (only Navigate's and Record's own sources run with the screen
/// locked, D7 revised 2026-10-20). Never asks for permission: it starts only when When In Use (or
/// Always) is already granted; the first Navigate or Record start asks.
@MainActor
protocol DisplayLocationProviding: AnyObject {
    /// True between a successful `start` and `stop`.
    var isRunning: Bool { get }
    /// Called on the main actor with each fix while running. Never after
    /// `stop`, not even for a fix queued before it.
    var onFix: (@MainActor (LocationSample) -> Void)? { get set }
    /// Called on the main actor after an authorisation change, so the
    /// session can start the feed once the user allows location.
    var onAuthorizationChange: (@MainActor () -> Void)? { get set }
    /// Idempotent. Does nothing, and `isRunning` stays false, unless
    /// authorisation already allows location.
    func start()
    /// Idempotent. `isRunning` is false and no more fixes arrive.
    func stop()
}

/// The phone's display feed: its own `CLLocationManager`, never shared with
/// `ReferenceLocationSource`.
@MainActor
final class DisplayLocationSource: DisplayLocationProviding {
    var onFix: (@MainActor (LocationSample) -> Void)? {
        get { display.onFix }
        set { display.onFix = newValue }
    }
    var onAuthorizationChange: (@MainActor () -> Void)?
    private(set) var isRunning = false

    private let manager: CLLocationManager
    private let delegate = DisplayLocationDelegate()
    private let authorization: any LocationAuthorizationProviding
    /// The run guard of `ReferenceFixDisplay`: a fix queued before `stop`
    /// never lands after it.
    private let display = ReferenceFixDisplay()

    /// - Parameter authorization: nil reads the source's own manager; tests
    ///   pass a fake.
    init(authorization: (any LocationAuthorizationProviding)? = nil) {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorization = authorization ?? manager
        manager.delegate = delegate
        delegate.observeAuthorization { [weak self] in
            Task { @MainActor in self?.onAuthorizationChange?() }
        }
    }

    /// Whether `start` may run: When In Use or Always is granted.
    var isAuthorized: Bool {
        authorization.authorizationStatus == .authorizedWhenInUse || authorization.authorizationStatus == .authorizedAlways
    }

    func start() {
        guard !isRunning, isAuthorized else { return }
        delegate.begin(onFix: display.begin())
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        delegate.end()
        display.end()
    }
}

/// Delegate for `DisplayLocationSource`: converts a `CLLocation` to a
/// `LocationSample` and hands it to the hook. Lock-guarded, not main-actor.
final class DisplayLocationDelegate: NSObject, CLLocationManagerDelegate, Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var onFix: (@Sendable (LocationSample) -> Void)?
    private nonisolated(unsafe) var onAuthorizationChange: (@Sendable () -> Void)?

    func observeAuthorization(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onAuthorizationChange = handler }
    }

    func begin(onFix: @escaping @Sendable (LocationSample) -> Void) {
        lock.withLock { self.onFix = onFix }
    }

    func end() {
        lock.withLock { onFix = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let onFix = lock.withLock({ self.onFix }), let last = locations.last else { return }
        onFix(ReferenceFix.sample(from: last, receivedT: nil, receivedWallClock: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Display only: nothing to write. CoreLocation keeps trying.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.withLock { onAuthorizationChange }?()
    }
}

/// The simulator's twin: one fixed position (the simulated drive's centre),
/// shown at start and then every second, so the map has a dot for
/// screenshots. No CoreLocation, no permission.
@MainActor
final class SimulatedDisplayLocationSource: DisplayLocationProviding {
    var onFix: (@MainActor (LocationSample) -> Void)?
    var onAuthorizationChange: (@MainActor () -> Void)?
    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    /// The position, stamped with the wall clock like a real fix, so each
    /// one differs and the map sees it as new.
    static func fix(at date: Date = Date()) -> LocationSample {
        LocationSample(
            latitude: 50.4501, longitude: 30.5234, altitude: 170, horizontalAccuracy: 5, verticalAccuracy: 3,
            speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
            fixTime: date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            ageS: 0, simulated: true)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.onFix?(Self.fix())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }
}
