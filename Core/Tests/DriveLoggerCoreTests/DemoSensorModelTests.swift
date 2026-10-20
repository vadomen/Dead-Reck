import Foundation
import Testing

@testable import DriveLoggerCore

/// REL-DEMO part 2: the demo drive's sensor streams (`DemoSensorModel`,
/// `DemoMotionSource`, `DemoLocationSource`) and the simulated adapter's
/// speed. The pack comes from the repository through `DemoDriveTests`; no
/// coordinates appear here, only distances, angles, speeds and counts.
@Suite("Demo drive sensors (REL-DEMO)")
struct DemoSensorModelTests {
    static func model() throws -> DemoSensorModel {
        DemoSensorModel(drive: try DemoDriveTests.fixture().drive)
    }

    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Smallest signed difference a − b, degrees, in (−180, 180].
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Distance between two positions, m.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p = LocalTangentPlane(latitude: lat1, longitude: lon1).enu(latitude: lat2, longitude: lon2)
        return (p.east * p.east + p.north * p.north).squareRoot()
    }

    // MARK: Determinism

    @Test("Deterministic: two models over two separately opened packs give identical motion, fixes and OBD speed")
    func deterministic() throws {
        let a = try Self.model()
        let b = DemoSensorModel(drive: try DemoDrive(pack: try DemoDriveTests.pack()))
        for index in [0, 1, 499, 500, 777, 12_345, 51_300, 99_999] {
            #expect(a.motionPayloads(index: index, rateHz: 100) == b.motionPayloads(index: index, rateHz: 100))
        }
        for second in 0..<1_100 {
            #expect(a.locationFix(second: second) == b.locationFix(second: second))
        }
        for t in stride(from: 0.0, to: 1_100, by: 0.37) {
            #expect(a.obdSpeedKmh(at: t) == b.obdSpeedKmh(at: t))
        }
        // And the same call twice.
        #expect(a.motionPayloads(index: 4_242, rateHz: 100) == a.motionPayloads(index: 4_242, rateHz: 100))
    }

    @MainActor
    @Test("The sources stamp sample n at n × period on the session clock (demo time = session time) and deliver the model's values; both mark the clock as the demo's origin")
    func sourcesDeliverTheModel() async throws {
        let model = try Self.model()
        let timeline = DemoTimeline()
        let clock = SessionClock()
        let sink = LogSink()
        let motion = DemoMotionSource(model: model, timeline: timeline)
        let location = DemoLocationSource(model: model, timeline: timeline)
        #expect(timeline.originUptimeSeconds == nil)
        try motion.start(clock: clock, sink: sink)
        #expect(timeline.originUptimeSeconds == clock.referenceUptimeSeconds)
        timeline.reset()
        try location.start(clock: clock, sink: sink)
        #expect(timeline.originUptimeSeconds == clock.referenceUptimeSeconds)
        try await Task.sleep(for: .milliseconds(250))
        motion.stop()
        location.stop()
        let events = await drain(sink)
        let motionEvents = events.filter { $0.payload.kind == "motion" }
        #expect(motionEvents.count >= 10)
        for (n, event) in motionEvents.enumerated() {
            #expect(event.timestamp.nanoseconds == Int64(n) * 10_000_000)
            #expect(event.payload == model.motionPayloads(index: n, rateHz: 100)[0])
        }
        let fixes = events.compactMap { event -> (MonotonicTimestamp, LocationSample)? in
            if case .location(let fix) = event.payload { return (event.timestamp, fix) }
            return nil
        }
        // Second 0 is due at once.
        let first = try #require(fixes.first)
        #expect(first.0 == .zero)
        #expect(first.1.receivedT == .zero && first.1.ageS == 0 && first.1.simulated == true)
        var expected = try #require(model.locationFix(second: 0))
        expected.receivedT = .zero
        expected.ageS = 0
        expected.fixTime = first.1.fixTime
        expected.simulated = true
        #expect(first.1 == expected)
        #expect(events.allSatisfy { $0.timestamp <= clock.now() })
    }

    // MARK: Location

    @Test("GNSS every second for the first 60 s, near the route; then network fixes only (no valid speed or course, tower accuracy), 6–18 s apart, ~12 s on average, tower-sized and minutes-correlated errors")
    func gnssThenNetworkOnly() throws {
        let model = try Self.model()
        let drive = model.drive
        for second in 0..<60 {
            let fix = try #require(model.locationFix(second: second), "GNSS at \(second) s")
            let truth = drive.state(at: Double(second))
            #expect(fix.hasValidSpeed && fix.horizontalAccuracy == 5)
            #expect(Self.distance(truth.latitude, truth.longitude, fix.latitude, fix.longitude) < 8)
            #expect(abs(fix.speed - truth.speedMps) < 0.5)
            if truth.speedMps >= 0.5 {
                #expect(fix.hasValidCourse)
                #expect(abs(Self.angleDifference(fix.course, truth.headingDeg)) < 3)
            } else {
                #expect(!fix.hasValidCourse)
            }
        }
        // Two laps.
        let end = Int((2 * drive.lapDurationS).rounded(.up))
        var seconds: [Int] = []
        var offsetsEast: [Double] = [], offsetsNorth: [Double] = []
        for second in 60...end {
            guard let fix = model.locationFix(second: second) else { continue }
            seconds.append(second)
            #expect(!fix.hasValidSpeed, "network fix at \(second) s")
            #expect(fix.speed == -1 && fix.speedAccuracy == -1 && fix.course == -1 && fix.courseAccuracy == -1)
            #expect(fix.horizontalAccuracy == DemoSensorModel.networkAccuracyM && fix.verticalAccuracy < 0)
            let truth = drive.state(at: Double(second))
            let p = LocalTangentPlane(latitude: truth.latitude, longitude: truth.longitude)
                .enu(latitude: fix.latitude, longitude: fix.longitude)
            offsetsEast.append(p.east)
            offsetsNorth.append(p.north)
            #expect((p.east * p.east + p.north * p.north).squareRoot() < 900)
        }
        let intervals = zip(seconds, seconds.dropFirst()).map { $1 - $0 }
        #expect(intervals.allSatisfy { (6...18).contains($0) }, "\(intervals)")
        let mean = Double(seconds.last! - seconds.first!) / Double(intervals.count)
        #expect(mean > 10 && mean < 14)
        #expect(seconds.first! < 60 + DemoSensorModel.networkSlotS)
        let rms = ((offsetsEast + offsetsNorth).map { $0 * $0 }.reduce(0, +) / Double(2 * offsetsEast.count)).squareRoot()
        #expect(rms > 80 && rms < 300, "per-axis RMS \(rms) m")
        // Within one tower window the error barely moves (scatter only).
        var spreads: [Double] = []
        for (i, (s0, s1)) in zip(seconds, seconds.dropFirst()).enumerated()
        where Int(Double(s0 - 60) / DemoSensorModel.towerWindowS) == Int(Double(s1 - 60) / DemoSensorModel.towerWindowS) {
            spreads.append(abs(offsetsEast[i + 1] - offsetsEast[i]))
        }
        #expect(!spreads.isEmpty && spreads.reduce(0, +) / Double(spreads.count) < 60)
    }

    // MARK: OBD

    @Test("OBD speed is the route speed truncated to whole km/h (0 stationary and with no demo running), rewritten into every speed reply of the bench script and decoded back exactly")
    func obdSpeedQuantised() throws {
        let model = try Self.model()
        let drive = model.drive
        #expect(model.obdSpeedKmh(at: nil) == 0 && model.obdRPM(at: nil) == DemoSensorModel.idleRPM)
        var sawMoving = false
        for t in stride(from: 0.0, to: drive.lapDurationS, by: 0.25) {
            let truth = drive.state(at: t)
            let kmh = model.obdSpeedKmh(at: t)
            #expect(kmh == Int((truth.speedMps * 3.6).rounded(.down)))
            #expect(Double(kmh) <= truth.speedMps * 3.6 && truth.speedMps * 3.6 < Double(kmh + 1))
            if truth.isStationary { #expect(kmh == 0) }
            sawMoving = sawMoving || kmh > 30
        }
        #expect(sawMoving)
        // Every speed-bearing reply of the script, at a moving instant.
        let t = 120.0
        let speed = model.obdSpeedKmh(at: t)
        let rpm = model.obdRPM(at: t)
        #expect(speed > 0)
        let speedRules = DemoSensorModel.elmRules.filter { $0.command.hasPrefix("010D") }
        #expect(Set(speedRules.map(\.command)) == ["010D", "010D1", "010D0C", "010D0C1"])
        #expect(speedRules.allSatisfy { $0.delay == .milliseconds(59) })
        for rule in speedRules {
            let reply = model.elmReply(command: rule.command, scripted: try #require(rule.reply), at: t)
            let replies = try ELM327ResponseParser.replies(in: reply, headers: true)
            #expect(!replies.isEmpty)
            for ecu in replies {
                let requested: [OBDPID] = rule.command.hasPrefix("010D0C") ? [.vehicleSpeed, .engineSpeed] : [.vehicleSpeed]
                let measurements = try OBDDecoder.decode(requested: requested, bytes: ecu.bytes)
                #expect(measurements.first { $0.pid == .vehicleSpeed }?.value == Double(speed), "\(rule.command) \(reply)")
                if requested.count == 2 {
                    #expect(measurements.first { $0.pid == .engineSpeed }?.value == (rpm * 4).rounded() / 4)
                }
            }
        }
        // Everything else passes unchanged.
        for rule in DemoSensorModel.elmRules where !rule.command.hasPrefix("010D") {
            let scripted = try #require(rule.reply)
            #expect(model.elmReply(command: rule.command, scripted: scripted, at: t) == scripted)
        }
        #expect(model.elmReply(command: "010D1", scripted: "NO DATA\r\r>", at: t) == "NO DATA\r\r>")
    }

    @Test("MockELMAdapter's reply transform rewrites a matched rule's reply with the request uptime; without one replies are verbatim")
    func adapterReplyTransform() async throws {
        let rules = [MockELMAdapter.Rule(command: "010D", reply: "7E803410D00\r\r>", delay: .zero)]
        let uptime = FixedUptime(41.5)
        let seen = LockedBox<[Double]>([])
        let adapter = MockELMAdapter(rules: rules, uptime: uptime) { command, reply, at in
            seen.mutate { $0.append(at) }
            return command == "010D" ? reply.replacingOccurrences(of: "410D00", with: "410D2A") : reply
        }
        _ = try await adapter.send(try ELMCommandPolicy.validate("010D", scope: .session))
        _ = try await adapter.send(try ELMCommandPolicy.validate("ATRV", scope: .session))
        await adapter.disconnect()
        var text = ""
        for await chunk in adapter.incoming { text += String(decoding: chunk.bytes, as: UTF8.self) }
        #expect(text.hasPrefix("7E803410D2A\r\r>"))
        #expect(text.hasSuffix("?\r\r>"))   // the unmatched ATRV: "?", passed through by this transform
        #expect(seen.value == [41.5, 41.5])
        let plain = MockELMAdapter(rules: rules, uptime: uptime)
        _ = try await plain.send(try ELMCommandPolicy.validate("010D", scope: .session))
        await plain.disconnect()
        var plainText = ""
        for await chunk in plain.incoming { plainText += String(decoding: chunk.bytes, as: UTF8.self) }
        #expect(plainText == "7E803410D00\r\r>")
    }

    // MARK: Motion

    @Test("Motion follows the route: the engine's yaw (rotationRate · ĝ) integrated over a lap matches the unwrapped course change (a full loop), attitude yaw matches it too, and the unwrapped heading is the route's course")
    func motionFollowsTheRoute() throws {
        let model = try Self.model()
        let drive = model.drive
        let rate = 100.0
        let start = model.unwrappedHeading(at: 0)
        var integrated = 0.0
        var worst = 0.0, worstAttitude = 0.0
        let samples = Int(drive.lapDurationS * rate)
        var previous = try #require(NavigationEngine.yawRate(model.motion(at: 0).motion))
        for n in 1...samples {
            let t = Double(n) / rate
            let m = model.motion(at: t).motion
            let rate1 = try #require(NavigationEngine.yawRate(m))
            integrated += (previous + rate1) / 2 / rate
            previous = rate1
            if n % 100 == 0 {
                let change = model.unwrappedHeading(at: t) - start
                worst = max(worst, abs(Self.degrees(integrated - change)))
                // Attitude: yaw about the vertical = −(heading change).
                let q = m.attitude
                let yaw = 2 * atan2(q.y, q.w)
                worstAttitude = max(worstAttitude, abs(Self.angleDifference(Self.degrees(yaw), -Self.degrees(change))))
                let wrapped = model.unwrappedHeading(at: t).truncatingRemainder(dividingBy: 2 * .pi)
                #expect(abs(Self.angleDifference(Self.degrees(wrapped), drive.state(at: t).headingDeg)) < 1e-6)
            }
        }
        let lapChange = model.unwrappedHeading(at: drive.lapDurationS) - start
        #expect(abs(abs(lapChange) - 2 * .pi) < 1e-6, "one loop turns 360°: \(Self.degrees(lapChange))°")
        #expect(abs(Self.degrees(integrated - lapChange)) < 0.5)
        #expect(worst < 0.5, "integrated yaw vs course change, worst \(worst)°")
        #expect(worstAttitude < 1e-6)
        // Continuous across the lap wrap, the next lap one more loop on.
        #expect(abs(model.unwrappedHeading(at: 2 * drive.lapDurationS) - start - 2 * lapChange) < 1e-6)
    }

    @Test("Stationary: no rotation, near-zero horizontal acceleration (under the engine's parked threshold); moving: lateral and longitudinal acceleration from the route, gravity 1 g, raw gyro = rate + bias")
    func stationaryAndMoving() throws {
        let model = try Self.model()
        let drive = model.drive
        let threshold = NavigationConfig().staleParkedMotionG
        for interval in drive.stationaryIntervals {
            for t in stride(from: interval.lowerBound, through: interval.upperBound, by: 0.013) {
                let m = model.motion(at: t)
                #expect(m.motion.rotationRate == .zero)
                let u = m.motion.userAcceleration
                #expect((u.x * u.x + u.z * u.z).squareRoot() < 1e-9)
                #expect(abs(u.y) < 0.002 && abs(u.y) < threshold)
            }
        }
        var sawTurn = false
        for t in stride(from: 0.0, to: drive.lapDurationS, by: 0.5) {
            let state = drive.state(at: t)
            let m = model.motion(at: t)
            #expect(m.motion.gravity == Vector3(x: 0, y: -1, z: 0))
            #expect(abs(m.motion.userAcceleration.x - state.lateralAccelerationMps2 / 9.80665) < 0.005)
            #expect(abs(m.motion.userAcceleration.z + state.accelerationMps2 / 9.80665) < 0.005)
            #expect(m.motion.magneticField == nil && m.motion.magneticAccuracy == -1)
            let b = DemoSensorModel.gyroBias
            #expect(m.gyroscope == Vector3(x: m.motion.rotationRate.x + b.x, y: m.motion.rotationRate.y + b.y,
                                           z: m.motion.rotationRate.z + b.z))
            #expect(m.accelerometer.y == -1 + m.motion.userAcceleration.y)
            sawTurn = sawTurn || abs(state.lateralAccelerationMps2) > 1
        }
        #expect(sawTurn)
    }

    // MARK: End to end

    /// The demo stream as the app's Navigate feeds it: device motion at
    /// 100 Hz, fixes at their second, and OBD speed polled every 61 ms
    /// (~16.4 Hz, the bench rate) answered 59 ms later by ECU `7E8` with the
    /// speed at the request; arrival order, as the tap delivers it.
    static func inputs(_ model: DemoSensorModel, until end: Double) -> [NavigationInput] {
        var out: [(Int64, Int, NavigationInput)] = []
        let rate = 100.0
        for n in 0...Int(end * rate) {
            let t = MonotonicTimestamp(nanoseconds: Int64(n) * 10_000_000)
            out.append((t.nanoseconds, 0, .motion(model.motion(at: Double(n) / rate).motion, at: t)))
        }
        var k = 0
        while Double(k) * 0.061 + 0.059 <= end {
            let request = Double(k) * 0.061
            let arrival = MonotonicTimestamp(seconds: request + 0.059)
            let kmh = model.obdSpeedKmh(at: request)
            let sample = OBDSample(pid: .vehicleSpeed, value: Double(kmh), unit: .kilometersPerHour,
                                   raw: String(format: "7E803410D%02X", kmh), requestT: MonotonicTimestamp(seconds: request),
                                   command: "010D1", ecu: "7E8", seq: k)
            out.append((arrival.nanoseconds, 1, .obd(sample, at: arrival)))
            k += 1
        }
        for second in 0...Int(end) {
            guard var fix = model.locationFix(second: second) else { continue }
            let t = MonotonicTimestamp(nanoseconds: Int64(second) * 1_000_000_000)
            fix.receivedT = t
            fix.ageS = 0
            fix.simulated = true
            out.append((t.nanoseconds, 2, .location(fix, at: t)))
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    @Test("End to end: two laps of the demo stream through LiveNavigationRun with the demo pack as the only road candidate stay near the route (network fixes only after 60 s)")
    func endToEndTwoLaps() throws {
        let fixture = try DemoDriveTests.fixture()
        let model = DemoSensorModel(drive: fixture.drive)
        let end = 2 * fixture.drive.lapDurationS
        let inputs = Self.inputs(model, until: end)
        var selector = RoadPackSelector(candidates: [try RoadPackSelection.Candidate(name: "demo.roadpack", pack: fixture.pack)])
        var run = LiveNavigationRun(sessionID: UUID(uuidString: "DE30D21E-0000-4000-8000-000000000002")!,
                                    config: NavigationConfig(seed: 7), appBuild: "test")
        var errors: [(t: Double, m: Double)] = []
        var headingErrors: [Double] = []
        var nextCheck = 1.0
        for input in inputs {
            run.ingest(input, selector: &selector) { _ in }
            let arrival = input.arrival.seconds
            while nextCheck <= arrival {
                if let estimate = run.engine.estimate(at: MonotonicTimestamp(seconds: nextCheck)) {
                    let truth = fixture.drive.state(at: nextCheck)
                    errors.append((nextCheck, Self.distance(truth.latitude, truth.longitude, estimate.latitude, estimate.longitude)))
                    // The engine's heading follows the route's course (the
                    // yaw sign and the attitude agree with the engine's).
                    if nextCheck >= 30, truth.speedMps > 3 {
                        headingErrors.append(abs(Self.angleDifference(estimate.headingDeg, truth.headingDeg)))
                    }
                }
                nextCheck += 1
            }
        }
        #expect(run.roads != nil, "the demo pack attached")
        let gnss = errors.filter { $0.t >= 10 && $0.t < DemoSensorModel.gnssUntilS }.map(\.m)
        let network = errors.filter { $0.t >= DemoSensorModel.gnssUntilS }.map(\.m)
        let maxGNSS = gnss.max() ?? .infinity, maxNetwork = network.max() ?? .infinity
        let rms = (network.map { $0 * $0 }.reduce(0, +) / Double(max(network.count, 1))).squareRoot()
        let final = errors.last?.m ?? .infinity
        print("REL-DEMO e2e: GNSS max \(maxGNSS) m; network-only max \(maxNetwork) m, RMS \(rms) m, final \(final) m; on-road \(run.engine.estimate(at: MonotonicTimestamp(seconds: end))?.onRoadShare ?? -1); network fixes used \(run.engine.counters.networkFixesUsed); heading max \(headingErrors.max() ?? -1)°")
        #expect(errors.count > Int(end) - 5)
        // Measured (seed 7): GNSS max 1.9 m; network-only max 8.2 m, RMS 2.9 m,
        // final 0.4 m; heading while moving (after 30 s) max 0.2°. The bounds are a lane-to-a-block margin over that, so
        // a sign or unit slip in the streams (yaw, speed, fix shape) fails.
        #expect(maxGNSS < 20)
        #expect(maxNetwork < 50)
        #expect(final < 30)
        #expect(headingErrors.count > 500 && (headingErrors.max() ?? .infinity) < 20)
    }
}

/// An uptime the test sets.
private struct FixedUptime: UptimeSource {
    let uptimeSeconds: Double
    init(_ value: Double) { uptimeSeconds = value }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    // @unchecked: `value` is only touched under `lock`.
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
