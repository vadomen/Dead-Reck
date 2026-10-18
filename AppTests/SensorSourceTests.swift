import CoreLocation
import CoreMotion
import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// The app-boundary conversions and the simulated twins. Real CoreMotion and
// CoreLocation delivery (rates, batching, background) cannot run here: the
// simulator has no motion sensors. Those checks are in docs/PLAN.md §6.

/// Runs `body` with a real writer's sink and clock, then returns the events
/// the file holds.
@MainActor
func recordedEvents(
    uptime: any UptimeSource = SystemUptimeSource(),
    _ body: (SessionClock, LogSink) async throws -> Void
) async throws -> (clock: SessionClock, events: [LogEvent]) {
    let scratch = try ScratchStore()
    defer { scratch.remove() }
    let clock = SessionClock(source: uptime, wallClockStart: Date(timeIntervalSince1970: 1_790_000_000))
    let url = scratch.store.directory.appendingPathComponent("t.jsonl.gz")
    let writer = try LogFileWriter(
        url: url,
        header: LogHeader(clock: clock, app: RecordingFixtures.app, device: RecordingFixtures.device),
        diskSpace: FakeDisk(RecordingFixtures.roomy)
    )
    try await body(clock, writer.sink)
    _ = await writer.finish()
    return (clock, try RecordingFixtures.read(url).events)
}

final class FakeAttitude: CMAttitude {
    override var quaternion: CMQuaternion { CMQuaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.927) }
}

final class FakeDeviceMotion: CMDeviceMotion {
    let accuracy: CMMagneticFieldCalibrationAccuracy
    init(accuracy: CMMagneticFieldCalibrationAccuracy) {
        self.accuracy = accuracy
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var timestamp: TimeInterval { 1_000.25 }
    override var userAcceleration: CMAcceleration { CMAcceleration(x: 0.01, y: -0.02, z: 0.03) }
    override var gravity: CMAcceleration { CMAcceleration(x: 0, y: -0.99, z: -0.1) }
    override var rotationRate: CMRotationRate { CMRotationRate(x: 0.001, y: 0.027, z: -0.002) }
    override var attitude: CMAttitude { FakeAttitude() }
    override var magneticField: CMCalibratedMagneticField {
        CMCalibratedMagneticField(field: CMMagneticField(x: 20, y: -45, z: 5), accuracy: accuracy)
    }
}

/// Latitudes a display callback saw, in order.
@MainActor
final class LatitudeLog {
    var values: [Double] = []
}

@Suite("Sensor sources")
@MainActor
struct SensorSourceTests {
    @Test("CMDeviceMotion → motion row, field for field, stamped with CoreMotion's own uptime (negative kept)")
    func deviceMotionConversion() async throws {
        // The session started at uptime 1 000.5, after this sample: t < 0.
        let (_, events) = try await recordedEvents(uptime: FixedUptimeSource(uptimeSeconds: 1_000.5)) { clock, sink in
            let gate = SampleGate(source: "deviceMotion", clock: clock, sink: sink)
            DeviceMotionSource.handler(gate: gate)(FakeDeviceMotion(accuracy: .uncalibrated), nil)
            DeviceMotionSource.handler(gate: gate)(FakeDeviceMotion(accuracy: .high), nil)
        }
        #expect(events.count == 2)
        #expect(events[0].timestamp == MonotonicTimestamp(nanoseconds: -250_000_000))
        #expect(events[0].payload == .motion(MotionSample(
            userAcceleration: Vector3(x: 0.01, y: -0.02, z: 0.03),
            gravity: Vector3(x: 0, y: -0.99, z: -0.1),
            rotationRate: Vector3(x: 0.001, y: 0.027, z: -0.002),
            attitude: Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.927),
            magneticField: nil,
            magneticAccuracy: -1
        )))
        guard case .motion(let calibrated) = events[1].payload else {
            Issue.record("expected motion")
            return
        }
        #expect(calibrated.magneticField == Vector3(x: 20, y: -45, z: 5))
        #expect(calibrated.magneticAccuracy == 2)
    }

    @Test("A CoreMotion error is one lifecycle error row per distinct error; a closed gate delivers nothing")
    func gate() async throws {
        let (_, events) = try await recordedEvents { clock, sink in
            let gate = SampleGate(source: "rawIMU", clock: clock, sink: sink)
            let error = NSError(domain: CMErrorDomain, code: Int(CMErrorDeviceRequiresMovement.rawValue))
            RawIMUSource.gyroHandler(gate: gate)(nil, error)
            RawIMUSource.gyroHandler(gate: gate)(nil, error)
            gate.close()
            DeviceMotionSource.handler(gate: gate)(FakeDeviceMotion(accuracy: .low), nil)
            gate.report("after close")
        }
        #expect(events.count == 1)
        guard case .lifecycle(let row) = events.first?.payload else {
            Issue.record("expected one lifecycle row")
            return
        }
        #expect(row.event == "error")
        #expect(row.detail?.hasPrefix("rawIMU: ") == true)
    }

    @Test("CLLocation → location row: every field, t = receivedT − ageS, raw fixTime kept")
    func referenceFixConversion() {
        let fixTime = Date(timeIntervalSince1970: 1_790_000_000.125)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50.4501, longitude: 30.5234),
            altitude: 170.5,
            horizontalAccuracy: 4.5,
            verticalAccuracy: 3,
            course: 271,
            courseAccuracy: 6,
            speed: 13.9,
            speedAccuracy: 0.4,
            timestamp: fixTime,
            sourceInfo: CLLocationSourceInformation(softwareSimulationState: false, andExternalAccessoryState: true)
        )
        let receivedT = MonotonicTimestamp(nanoseconds: 60_000_000_000)
        let event = ReferenceFix.event(from: location, receivedT: receivedT, receivedWallClock: fixTime.addingTimeInterval(0.375))
        #expect(event.timestamp == MonotonicTimestamp(nanoseconds: 59_625_000_000))
        guard case .location(let fix) = event.payload else {
            Issue.record("expected location")
            return
        }
        #expect(fix.latitude == 50.4501 && fix.longitude == 30.5234)
        #expect(fix.altitude == 170.5 && fix.ellipsoidalAltitude == location.ellipsoidalAltitude)
        #expect(fix.horizontalAccuracy == 4.5 && fix.verticalAccuracy == 3)
        #expect(fix.speed == 13.9 && fix.speedAccuracy == 0.4)
        #expect(fix.course == 271 && fix.courseAccuracy == 6)
        #expect(fix.receivedT == receivedT)
        #expect(fix.ageS == 0.375)
        #expect(fix.fixTime == "2026-09-21T14:13:20.125Z")
        #expect(fix.simulated == location.sourceInformation?.isSimulatedBySoftware)
        #expect(fix.accessory == location.sourceInformation?.isProducedByAccessory)
        #expect(fix.simulated != nil && fix.accessory != nil)

        // Invalid fields stay negative; a fix stamped after the reading keeps
        // its negative age.
        let invalid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: 0,
            horizontalAccuracy: -1, verticalAccuracy: -1, course: -1, courseAccuracy: -1,
            speed: -1, speedAccuracy: -1, timestamp: fixTime
        )
        // 1/64 s: exact in a Date's Double, so the arithmetic is too.
        let early = ReferenceFix.event(from: invalid, receivedT: receivedT, receivedWallClock: fixTime.addingTimeInterval(-0.015625))
        #expect(early.timestamp == MonotonicTimestamp(nanoseconds: 60_015_625_000))
        guard case .location(let bad) = early.payload else { return }
        #expect(bad.ageS == -0.015625)
        #expect(bad.speed == -1 && bad.speedAccuracy == -1 && bad.course == -1 && bad.courseAccuracy == -1)
        #expect(bad.horizontalAccuracy == -1 && bad.verticalAccuracy == -1)
    }

    /// R61.1-2: the delegate hops each fix to the main actor in a `Task`. A
    /// fix queued by one run must not reach the next run's `onReferenceFix`
    /// (Navigate ended and the recording started before the hop ran), nor
    /// set `latestReferenceFix` after `stop`. The sink is not affected: every
    /// fix is in the file. Real CoreLocation may deliver fixes of its own on
    /// the simulator while the source runs, so fixes are matched by their
    /// marker latitudes and `latestReferenceFix` is checked only after
    /// `stop`; `referenceFixDisplay` checks it while running, with no
    /// CoreLocation.
    @Test("Reference fix display (R61.1-2): a fix queued by one run never reaches the next run's callback, nor latestReferenceFix after stop; the sink gets every fix")
    func referenceFixDisplayRun() async throws {
        let source = ReferenceLocationSource(
            authorization: FakeLocationAuthorization(.authorizedWhenInUse),
            lastKnownLocation: FakeLastKnownLocation(nil)
        )
        source.holdsBackgroundLocation = false
        let manager = CLLocationManager()
        let navigateRun = 11.0, recordRun = 22.0, afterStop = 33.0
        func deliver(_ latitude: Double) {
            source.delegate.locationManager(manager, didUpdateLocations: [CLLocation(latitude: latitude, longitude: 30.5)])
        }
        /// Lets every `Task` already queued on the main actor run.
        func drain() async throws { try await Task.sleep(for: .milliseconds(200)) }

        let navigateSeen = LatitudeLog()
        let recordSeen = LatitudeLog()
        let (_, events) = try await recordedEvents { clock, sink in
            source.onReferenceFix = { navigateSeen.values.append($0.latitude) }
            try source.start(clock: clock, sink: sink)
            // Queued, not yet shown; then the run ends and the next one
            // starts with its own callback before the hop runs.
            deliver(navigateRun)
            source.stop()
            source.onReferenceFix = { recordSeen.values.append($0.latitude) }
            try source.start(clock: clock, sink: sink)
            try await drain()
            #expect(!recordSeen.values.contains(navigateRun), "the ended run's fix reached the new run's callback")
            #expect(!navigateSeen.values.contains(navigateRun), "the ended run's callback was replaced; nothing reaches it either")

            deliver(recordRun)
            try await drain()
            #expect(recordSeen.values.contains(recordRun), "the current run's fix is shown")

            // Queued, then stopped: nothing shown afterwards.
            deliver(afterStop)
            source.stop()
            try await drain()
            #expect(!recordSeen.values.contains(afterStop))
            #expect(source.latestReferenceFix == nil, "stop cleared it and it stays clear")
        }
        let recorded = events.compactMap { event -> Double? in
            guard case .location(let fix) = event.payload else { return nil }
            return fix.latitude
        }
        #expect(recorded.filter { [navigateRun, recordRun, afterStop].contains($0) } == [navigateRun, recordRun, afterStop],
                "every fix reached the sink, display or not")
    }

    /// R61.1-2, the hop alone (no CoreLocation, so `latest` is exact).
    @Test("ReferenceFixDisplay: only the current run's fixes are shown; an earlier run's queued or late fix is dropped; nothing after end")
    func referenceFixDisplay() async throws {
        func fix(_ latitude: Double) -> LocationSample {
            LocationSample(
                latitude: latitude, longitude: 30.5, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                speed: 10, speedAccuracy: 1, course: -1, courseAccuracy: -1
            )
        }
        func drain() async throws { try await Task.sleep(for: .milliseconds(100)) }
        let display = ReferenceFixDisplay()
        let first = LatitudeLog()
        let second = LatitudeLog()

        display.onFix = { first.values.append($0.latitude) }
        let firstHook = display.begin()
        firstHook(fix(1)) // queued
        display.end()
        display.onFix = { second.values.append($0.latitude) }
        let secondHook = display.begin()
        try await drain()
        #expect(first.values.isEmpty && second.values.isEmpty, "the queued fix of the ended run is dropped")
        #expect(display.latest == nil)

        secondHook(fix(2))
        try await drain()
        #expect(second.values == [2])
        #expect(display.latest == fix(2))

        // A late call of the ended run's hook while the next run is live.
        firstHook(fix(3))
        try await drain()
        #expect(second.values == [2] && first.values.isEmpty)
        #expect(display.latest == fix(2))

        secondHook(fix(4)) // queued, then the run ends
        display.end()
        try await drain()
        #expect(second.values == [2])
        #expect(display.latest == nil, "end cleared it and it stays clear")
    }

    @Test("Simulated mag (10 Hz) and baro (1 Hz): exact spacing on the session clock, nothing after stop")
    func simulatedMagBaro() async throws {
        let source = SimulatedMagBaroSource()
        let (clock, events) = try await recordedEvents { clock, sink in
            try source.start(clock: clock, sink: sink)
            try await Task.sleep(for: .milliseconds(1_250))
            source.stop()
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = clock
        let mag = events.filter { $0.payload.kind == "mag" }.map(\.timestamp.nanoseconds)
        let baro = events.filter { $0.payload.kind == "baro" }.map(\.timestamp.nanoseconds)
        #expect((12...14).contains(mag.count))
        #expect(baro.count == 2)
        #expect(zip(mag, mag.dropFirst()).allSatisfy { $1 - $0 == 100_000_000 })
        #expect(baro[1] - baro[0] == 1_000_000_000)
        guard case .magnetometer(let first) = events.first(where: { $0.payload.kind == "mag" })?.payload else { return }
        #expect(first == Vector3(x: 12, y: -54, z: 6))
    }

    @Test("The simulator suite covers every sensor kind at the device's requested rates")
    func suites() {
        let simulated = SensorSuite.simulated()
        #expect(simulated.sources.map(\.name) == ["simulatedMotion", "simulatedMagBaro", "simulatedLocation"])
        #expect(simulated.note == SensorSuite.simulatedNote)
        let device = SensorSuite.device()
        #expect(device.sources.map(\.name) == ["deviceMotion", "rawIMU", "altimeter", "referenceLocation"])
        #expect(device.note == nil)
        #expect(simulated.configuration == device.configuration)
        // Live GPS speed on both (M2-S2); background execution only on the
        // phone, so the simulator makes no background claim (R4.1-5).
        #expect(simulated.sources.filter { $0 is any LiveReferenceFixReporting }.map(\.name) == ["simulatedLocation"])
        #expect(device.sources.filter { $0 is any LiveReferenceFixReporting }.map(\.name) == ["referenceLocation"])
        #expect(device.sources.filter { $0 is any BackgroundExecutionProviding }.map(\.name) == ["referenceLocation"])
        #expect(!simulated.sources.contains { $0 is any BackgroundExecutionProviding })
        #expect(device.configuration.referenceFrame == "xArbitraryZVertical")
        // No motion hardware on the simulator: the real sources say so.
        #if targetEnvironment(simulator)
        #expect(DeviceMotionSource().availability != .available)
        #endif
    }
}
