import CoreLocation
import DriveLoggerCore
import Foundation
import Observation
import Testing

@testable import DriveLogger

// Fakes for `RecordingSession` tests: a link whose state and events the test
// sets, sources that tick on the session clock, a disk the test fills, and a
// scratch `LogStore`. No hardware: what CoreMotion, CoreLocation and the
// phone's disk really do is in docs/PLAN.md §6.

/// `OBDLinkServicing` driven by the test: `state`, `adapter` and `plan` are
/// set directly, `send` yields on the one `linkEvents()` stream.
@MainActor
@Observable
final class FakeLink: OBDLinkServicing {
    var state: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4)
    var discovered: [DiscoveredAdapter] = []
    var rememberedAdapterID: UUID?
    var adapter: AdapterRecord? = AdapterRecord(
        name: "IOS-Vlink",
        identifier: "0BD0B0D0-1111-4222-8333-944455556666",
        elmVersion: "ELM327 v2.3",
        protocolNumber: "A6",
        voltage: 12.4
    )
    var plan: PollingPlan? = .baseline
    var pollHz: Double = 0
    var console: [ConsoleLine] = []
    /// Set by the test: what `lastInitEvents` returns.
    var lastInitEvents: [LinkEvent] {
        get {
            takeSnapshotHook()
            return storedInitEvents
        }
        set { storedInitEvents = newValue }
    }
    /// Events `send` delivered on the current stream.
    var deliveredLinkEventCount: Int {
        takeSnapshotHook()
        return storedDeliveredCount
    }
    /// Run once, the first time the recorder reads `lastInitEvents` or
    /// `deliveredLinkEventCount` after it is set (whichever it reads first):
    /// lets a test deliver events at that instant, so they sit in the
    /// recorder's stream buffer unconsumed while it takes its snapshot — the
    /// race the M4 dedup contract must handle.
    @ObservationIgnored var onNextInitSnapshot: (@MainActor () -> Void)?
    @ObservationIgnored private var storedInitEvents: [LinkEvent] = []
    @ObservationIgnored private var storedDeliveredCount = 0
    @ObservationIgnored private(set) var subscriptions = 0
    @ObservationIgnored private var continuation: AsyncStream<LinkEvent>.Continuation?

    @ObservationIgnored private(set) var startScanCalls = 0
    @ObservationIgnored private(set) var stopScanCalls = 0
    @ObservationIgnored private(set) var connectCalls: [UUID] = []
    @ObservationIgnored private(set) var disconnectCalls = 0
    @ObservationIgnored private(set) var forgetCalls = 0

    func startScan() { startScanCalls += 1 }
    func stopScan() { stopScanCalls += 1 }
    func connect(to id: UUID) { connectCalls.append(id) }
    func disconnect() { disconnectCalls += 1 }
    func forget() { forgetCalls += 1 }
    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange { throw .notInitialised }
    func reinitialise() async {}

    func linkEvents() -> AsyncStream<LinkEvent> {
        continuation?.finish()
        subscriptions += 1
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        self.continuation = continuation
        storedDeliveredCount = 0
        return stream
    }

    func send(_ event: LinkEvent) {
        if case .enqueued = continuation?.yield(event) { storedDeliveredCount += 1 }
    }

    private func takeSnapshotHook() {
        guard let hook = onNextInitSnapshot else { return }
        onNextInitSnapshot = nil
        hook()
    }
}

/// A source that records `accel` rows at 100 Hz on the session clock
/// (through the app's `SimulatedSampleTicker`), or fails as told.
@MainActor
class FakeSource: SensorSource {
    let name: String
    var availability: SensorAvailability = .available
    var startError: (any Error)?
    private(set) var starts = 0
    private(set) var stops = 0
    private var ticker: SimulatedSampleTicker?

    init(name: String = "fakeIMU") {
        self.name = name
    }

    var isRunning: Bool { ticker != nil }

    func start(clock: SessionClock, sink: LogSink) throws {
        if let startError { throw startError }
        starts += 1
        let ticker = SimulatedSampleTicker(label: name, clock: clock, sink: sink, period: .milliseconds(10)) { _, t in
            [LogEvent(timestamp: t, payload: .accelerometer(Vector3(x: 0, y: -1, z: 0)))]
        }
        self.ticker = ticker
        ticker.begin()
    }

    func stop() {
        stops += 1
        ticker?.stop()
        ticker = nil
    }
}

/// A `FakeSource` standing in for `ReferenceLocationSource` as the one that
/// keeps the app running while locked (R4.1-5). Setting `availability`
/// reports the change, as a location authorisation change does.
@MainActor
class FakeBackgroundSource: FakeSource, BackgroundExecutionProviding {
    var onAvailabilityChange: (@MainActor () -> Void)?

    override var availability: SensorAvailability {
        didSet { onAvailabilityChange?() }
    }
}

/// A `FakeBackgroundSource` that also reports location authorisation, as
/// `ReferenceLocationSource` does on a phone (M4).
@MainActor
final class FakeLocationSource: FakeBackgroundSource, LocationAuthorizationReporting {
    var locationAuthorizationDetail = "authorizationStatus=authorizedWhenInUse, accuracyAuthorization=full, backgroundActivitySession=held"
}

/// `LocationAuthorizationProviding` whose answers the test sets.
final class FakeLocationAuthorization: LocationAuthorizationProviding {
    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization

    init(_ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization = .fullAccuracy) {
        authorizationStatus = status
        accuracyAuthorization = accuracy
    }
}

struct FakeStartError: Error, CustomStringConvertible {
    var description: String { "permission denied" }
}

/// A `DiskSpaceProvider` whose reading the test sets (nil = throws).
final class FakeDisk: DiskSpaceProvider {
    struct Unreadable: Error {}
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var bytes: Int64?

    init(_ bytes: Int64?) {
        self.bytes = bytes
    }

    func set(_ value: Int64?) {
        lock.withLock { bytes = value }
    }

    func availableBytes(for url: URL) throws -> Int64 {
        guard let value = lock.withLock({ bytes }) else { throw Unreadable() }
        return value
    }
}

/// Records every `isIdleTimerDisabled` assignment.
@MainActor
final class IdleTimerSpy {
    private(set) var values: [Bool] = []
    func set(_ value: Bool) { values.append(value) }
}

/// A temporary directory used as the session's `LogStore`.
struct ScratchStore {
    let store: LogStore

    init(_ label: String = #function) throws {
        let safe = label.filter { $0.isLetter || $0.isNumber }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-app-\(safe)-\(UUID().uuidString)", isDirectory: true)
        store = LogStore(directory: url)
        try store.createDirectory()
    }

    var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
    }

    func remove() {
        try? FileManager.default.removeItem(at: store.directory)
    }
}

enum RecordingFixtures {
    static let roomy: Int64 = 10_000_000_000
    static let app = AppIdentity(name: "DriveLogger", version: "0.0-test", build: "0")
    static let device = DeviceIdentity(model: "iPhone16,1", systemName: "iOS", systemVersion: "17.5")
    static let sensors = SensorSuite.configuration

    @MainActor
    static func session(
        link: (any OBDLinkServicing)? = nil,
        sources: [any SensorSource]? = nil,
        store: LogStore,
        disk: FakeDisk = FakeDisk(roomy),
        idle: IdleTimerSpy? = nil,
        statsInterval: Duration = .milliseconds(300),
        flushInterval: Duration = .milliseconds(100)
    ) -> RecordingSession {
        let idle = idle ?? IdleTimerSpy()
        return RecordingSession(
            link: link ?? FakeLink(),
            sources: sources ?? [FakeSource()],
            store: store,
            diskSpace: disk,
            sensorConfiguration: sensors,
            notes: "test",
            app: app,
            device: device,
            flushInterval: flushInterval,
            statsInterval: statsInterval,
            diskRefreshInterval: .seconds(3_600),
            setIdleTimerDisabled: { idle.set($0) }
        )
    }

    /// Header, events and read report of a finished recording.
    static func read(_ url: URL) throws -> (header: LogHeader, events: [LogEvent], report: LogReadReport) {
        let reader = try LogFileReader(url: url, recovery: .strict)
        let events = Array(reader)
        return (reader.header, events, reader.report)
    }

    static func lifecycle(_ events: [LogEvent]) -> [(index: Int, sample: LifecycleSample)] {
        events.enumerated().compactMap { index, event in
            if case .lifecycle(let sample) = event.payload { (index, sample) } else { nil }
        }
    }

    static func index(of event: LifecycleSample.Event, in events: [LogEvent]) -> Int? {
        lifecycle(events).first { $0.sample.event == event.rawValue }?.index
    }

    static func kinds(_ events: [LogEvent], _ kind: LogEventKind) -> [Int] {
        events.enumerated().compactMap { $0.element.payload.kind == kind.rawValue ? $0.offset : nil }
    }
}
