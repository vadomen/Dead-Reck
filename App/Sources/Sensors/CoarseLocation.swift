import CoreLocation
import DriveLoggerCore
import Foundation

/// One coarse position as CoreLocation gave it, converted at the boundary
/// (UX-8 first launch). Held in memory only to compute the first-launch
/// suggestion: never stored, logged or sent.
struct CoarseLocationReading: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    /// `CLLocation.horizontalAccuracy`, metres (negative: invalid).
    var horizontalAccuracyM: Double
    /// `CLLocation.timestamp` (wall clock: the verdict compares it with the
    /// request's wall-clock time; nothing here reaches a recording).
    var timestamp: Date
}

/// Where the first-launch coarse fix comes from: CoreLocation on a phone; a
/// fake in tests; a synthetic one for DEBUG screenshots.
@MainActor
protocol CoarseLocationSource: AnyObject {
    /// When In Use (or Always) is already granted. Never asks: the first
    /// Navigate or Record start does.
    var isAuthorized: Bool { get }
    /// Starts updates; each reading goes to `onReading` on the main actor
    /// until `stop`.
    func start(onReading: @escaping @MainActor (CoarseLocationReading) -> Void)
    /// Idempotent. No reading is delivered after it.
    func stop()
}

/// The first usable coarse fix within 10 s (UX-8 (1), docs/BACKLOG_UX.md).
///
/// - No authorisation (not determined, denied, restricted): nil at once;
///   nothing is requested.
/// - Every reading is judged by Core's `PackRegionChoice.fixVerdict`
///   against the request time: a cached fix taken before the request or
///   more than 60 s old, an inaccurate one (> 5 km or invalid) or one that
///   arrives late is ignored and the request keeps waiting.
/// - The first usable one ends the request: updates stop and it is
///   returned. After `timeout` (the config's 10 s): updates stop, nil.
///   Cancelling the calling task does the same.
/// - The fix is never stored, logged or sent; `rejected` keeps only the
///   verdicts of ignored readings (diagnostics, tests), no positions.
@MainActor
final class CoarseFixRequest {
    struct Result: Hashable, Sendable {
        var fix: PackRegionChoice.Fix
        /// When the request started (`PackRegionChoice.suggest` needs it).
        var requestedAt: Date
    }

    private let source: any CoarseLocationSource
    private let config: PackRegionChoice.Config
    private let now: @MainActor () -> Date
    private let timeout: Duration
    private var continuation: CheckedContinuation<Result?, Never>?
    private var timer: Task<Void, Never>?
    /// Why each ignored reading was ignored, in arrival order.
    private(set) var rejected: [PackRegionChoice.FixVerdict] = []

    /// - Parameters:
    ///   - now: the wall clock (the fix's own timestamp is wall-clock).
    ///   - timeout: nil uses `config.maxWaitS`.
    init(source: any CoarseLocationSource, config: PackRegionChoice.Config = .default,
         now: @escaping @MainActor () -> Date = { Date() }, timeout: Duration? = nil) {
        self.source = source
        self.config = config
        self.now = now
        self.timeout = timeout ?? .milliseconds(Int(config.maxWaitS * 1000))
    }

    /// One request; a second call while one runs returns nil.
    func run() async -> Result? {
        guard continuation == nil, !Task.isCancelled, source.isAuthorized else { return nil }
        let requestedAt = now()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
                self.continuation = continuation
                rejected = []
                source.start { [weak self] reading in self?.receive(reading, requestedAt: requestedAt) }
                let timeout = self.timeout
                timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    private func receive(_ reading: CoarseLocationReading, requestedAt: Date) {
        guard continuation != nil else { return }
        let fix = PackRegionChoice.Fix(
            latitude: reading.latitude, longitude: reading.longitude,
            horizontalAccuracyM: reading.horizontalAccuracyM, timestamp: reading.timestamp, arrivedAt: now())
        let verdict = PackRegionChoice.fixVerdict(fix, requestedAt: requestedAt, config: config)
        if verdict == .usable {
            finish(Result(fix: fix, requestedAt: requestedAt))
        } else {
            rejected.append(verdict)
        }
    }

    private func finish(_ result: Result?) {
        guard let continuation else { return }
        self.continuation = nil
        source.stop()
        timer?.cancel()
        timer = nil
        continuation.resume(returning: result)
    }
}

/// The phone's coarse source: its OWN `CLLocationManager`, never the
/// recording's (`ReferenceLocationSource`) or the map's
/// (`DisplayLocationSource`), so it changes neither what is recorded nor
/// their settings. Each manager's settings are its own; CoreLocation
/// serves every client at the best accuracy any of them asks for, so a
/// coarse request cannot degrade another.
///
/// `desiredAccuracy` is `kCLLocationAccuracyThreeKilometers`: a cell or
/// Wi-Fi fix, fast and cheap, no GNSS warm-up. Not
/// `kCLLocationAccuracyReduced`: that forces an approximate fix whose
/// reported accuracy may exceed the 5 km limit (untested on hardware);
/// with "Precise Location" off the system returns an approximate fix
/// anyway, and the verdict decides. Never background, never Always.
@MainActor
final class CoreLocationCoarseSource: CoarseLocationSource {
    private let manager = CLLocationManager()
    private let delegate = CoarseLocationDelegate()

    init() {
        manager.delegate = delegate
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func start(onReading: @escaping @MainActor (CoarseLocationReading) -> Void) {
        guard isAuthorized else { return }
        delegate.begin { reading in
            Task { @MainActor in onReading(reading) }
        }
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        delegate.end()
    }
}

/// Delegate for `CoreLocationCoarseSource`: converts each `CLLocation`;
/// lock-guarded, not main-actor (CoreLocation calls it on the manager's
/// run loop). After `end` nothing is handed on, though a `Task` already
/// queued may still reach `CoarseFixRequest`, which ignores it once
/// finished.
final class CoarseLocationDelegate: NSObject, CLLocationManagerDelegate, Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var onReading: (@Sendable (CoarseLocationReading) -> Void)?   // guarded by `lock`

    func begin(_ handler: @escaping @Sendable (CoarseLocationReading) -> Void) {
        lock.withLock { onReading = handler }
    }

    func end() {
        lock.withLock { onReading = nil }
    }

    static func reading(_ location: CLLocation) -> CoarseLocationReading {
        CoarseLocationReading(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                              horizontalAccuracyM: location.horizontalAccuracy, timestamp: location.timestamp)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let handler = lock.withLock({ onReading }) else { return }
        for location in locations { handler(Self.reading(location)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Keep waiting: the request's timeout ends it.
    }
}

/// A fixed coarse source: no CoreLocation. DEBUG screenshots and UI tests
/// (`-uiCoarseFix`), and the simulator, so they never use a real position.
/// `nil` reading: not authorised, so the request answers nil at once.
@MainActor
final class SyntheticCoarseSource: CoarseLocationSource {
    private let reading: (latitude: Double, longitude: Double, accuracyM: Double)?
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(latitude: Double, longitude: Double, accuracyM: Double, delay: Duration = .milliseconds(300)) {
        reading = (latitude, longitude, accuracyM)
        self.delay = delay
    }

    /// No fix.
    init() {
        reading = nil
        delay = .zero
    }

    var isAuthorized: Bool { reading != nil }

    func start(onReading: @escaping @MainActor (CoarseLocationReading) -> Void) {
        guard let reading else { return }
        let delay = self.delay
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Stamped now, so it is fresh.
            onReading(CoarseLocationReading(latitude: reading.latitude, longitude: reading.longitude,
                                            horizontalAccuracyM: reading.accuracyM, timestamp: Date()))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Which coarse source the app uses.
enum CoarseLocation {
    /// The DEBUG `-uiCoarseFix` override: `none` (no fix), or
    /// `<lat>,<lon>[,<accuracy m>]` (a synthetic fix, default accuracy
    /// 1000 m). Anything else: no override.
    enum Override: Hashable, Sendable {
        case none
        case fix(latitude: Double, longitude: Double, accuracyM: Double)

        static func parse(_ text: String?) -> Override? {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            if text.lowercased() == "none" { return Override.none }
            let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
            let values = parts.compactMap { $0 }
            return .fix(latitude: values[0], longitude: values[1], accuracyM: values.count == 3 ? values[2] : 1_000)
        }
    }

    static let overrideKey = "uiCoarseFix"

    /// CoreLocation on a phone. DEBUG: `-uiCoarseFix` wins; without it the
    /// simulator and a forced first-launch maps step (`-uiFirstLaunchMaps`,
    /// screenshots) get no fix, so a screenshot never shows a suggestion
    /// from a real position.
    @MainActor
    static func makeSource(defaults: UserDefaults = .standard) -> any CoarseLocationSource {
        #if DEBUG
        switch Override.parse(defaults.string(forKey: overrideKey)) {
        case .none?:
            return SyntheticCoarseSource()
        case .fix(let latitude, let longitude, let accuracyM)?:
            return SyntheticCoarseSource(latitude: latitude, longitude: longitude, accuracyM: accuracyM)
        case nil:
            if defaults.bool(forKey: FirstLaunchMapsStore.forceKey) { return SyntheticCoarseSource() }
        }
        #endif
        #if targetEnvironment(simulator)
        return SyntheticCoarseSource()
        #else
        return CoreLocationCoarseSource()
        #endif
    }
}
