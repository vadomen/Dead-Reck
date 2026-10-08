import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// `RecordingSession` against fakes: the real `LogFileWriter` writing to a
// scratch directory, read back with `LogFileReader`. Timers are shortened
// (stats every 300 ms, flush every 100 ms); the logic is the app's.

@Suite("RecordingSession", .serialized)
@MainActor
struct RecordingSessionTests {
    @Test("A recording: header, start and calibration rows, sources and link rows, stats, stop row, final stats row")
    func recordsAndStops() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let source = FakeSource()
        let idle = IdleTimerSpy()
        let session = RecordingFixtures.session(link: link, sources: [source], store: scratch.store, idle: idle)
        #expect(link.subscriptions == 1)
        #expect(session.canStart)
        // No source provides background execution: no claim, no warning (R4.1-5).
        #expect(session.backgroundRiskWarning == nil)

        try await session.start(mount: "windscreen, portrait", vehicle: "Touareg", allowWithoutOBD: false, calibration: .milliseconds(200))
        #expect(session.state == .recording)
        #expect(session.startBlocker == .recordingInProgress)
        #expect(idle.values == [true])
        let url = try #require(session.currentFile)

        try await Task.sleep(for: .milliseconds(750))
        session.mark("tunnel")
        link.send(.session(.pollRate(hz: 20, uptime: ProcessInfo.processInfo.systemUptime)))
        #expect(await eventually(2) { session.live.obdHz == 20 })
        let uptime = ProcessInfo.processInfo.systemUptime
        link.send(.ble(from: .connected, to: .disconnected, reason: "link lost", uptime: uptime))
        #expect(await eventually(2) { session.live.obdHz == 0 && session.live.elapsed > 0.5 })
        await session.stop()

        #expect(session.state == .idle)
        #expect(session.lastStopReason == .user)
        #expect(session.currentFile == nil)
        #expect(idle.values == [true, false])
        #expect(!source.isRunning)

        let (header, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil && !report.truncatedTail)
        #expect(header.adapter == link.adapter)
        #expect(header.polling == PollingRecord(.baseline))
        #expect(header.sensors == RecordingFixtures.sensors)
        #expect(header.mount == "windscreen, portrait")
        #expect(header.vehicle == "Touareg")
        #expect(header.notes == "test")
        #expect(header.timeZone == TimeZone.current.identifier)

        let lifecycle = RecordingFixtures.lifecycle(events).map(\.sample)
        #expect(lifecycle.map(\.event) == ["start", "calibrationStart", "calibrationEnd", "stop"])
        #expect(lifecycle.first?.detail == nil)
        #expect(lifecycle.last == .stop(.user))

        // The link row is stamped from the uptime it carries, on this
        // recording's clock.
        let linkRow = try #require(events.first { $0.payload.kind == "link" })
        let expectedT = MonotonicTimestamp(seconds: uptime - header.referenceUptimeSeconds)
        #expect(abs(linkRow.timestamp.nanoseconds - expectedT.nanoseconds) <= 1)
        #expect(linkRow.payload == .link(LinkSample(layer: "ble", from: "connected", to: "disconnected", reason: "link lost")))

        #expect(events.contains { $0.payload == .marker("tunnel") })
        let stopIndex = try #require(RecordingFixtures.index(of: .stop, in: events))
        let stats = RecordingFixtures.kinds(events, .stats)
        #expect(stats.filter { $0 < stopIndex }.count >= 2)
        #expect(stats.last == events.count - 1, "the final stats row is the last row")
        // Sources stopped before the stop row (R1-9).
        let accel = RecordingFixtures.kinds(events, .accelerometer)
        #expect(accel.count > 50)
        #expect(accel.allSatisfy { $0 < stopIndex })
        // Every row counted once across the stats rows.
        let counted = events.compactMap { event -> Int? in
            if case .stats(let sample) = event.payload { sample.counts["accel"] ?? 0 } else { nil }
        }.reduce(0, +)
        #expect(counted == accel.count)
    }

    @Test("Start is refused below the warning threshold and creates nothing (rule 3)")
    func refusesBelowWarning() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let disk = FakeDisk(150_000_000)
        let session = RecordingFixtures.session(store: scratch.store, disk: disk)
        await #expect(throws: RecordingStartBlocker.lowDiskSpace(availableBytes: 150_000_000, requiredBytes: 200_000_000)) {
            try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        }
        #expect(session.state == .idle)
        #expect(scratch.files.isEmpty)
        #expect(session.startBlocker == .lowDiskSpace(availableBytes: 150_000_000, requiredBytes: 200_000_000))

        // R3-5: freeing space shows up after a refresh, without a start.
        disk.set(RecordingFixtures.roomy)
        await session.refreshDiskSpace()
        #expect(session.startBlocker == nil)
        // An unreadable volume does not block.
        disk.set(nil)
        await session.refreshDiskSpace()
        #expect(session.canStart)
    }

    @Test("Without a polling link, start needs the explicit choice; then the header has no adapter")
    func obdNotReady() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        link.state = .connecting
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        #expect(session.startBlocker == .obdNotReady)
        await #expect(throws: RecordingStartBlocker.obdNotReady) {
            try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        }
        #expect(scratch.files.isEmpty)
        session.allowsRecordingWithoutOBD = true
        #expect(session.startBlocker == nil)

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        let url = try #require(session.currentFile)
        await session.stop()
        let (header, events, _) = try RecordingFixtures.read(url)
        #expect(header.adapter == nil)
        #expect(header.polling == nil)
        #expect(header.mount == nil)
        let start = try #require(RecordingFixtures.lifecycle(events).first?.sample)
        #expect(start.event == "start")
        #expect(start.detail == "without OBD: link connecting")
        // calibration .zero: both rows, back to back.
        #expect(RecordingFixtures.lifecycle(events).map(\.sample.event).prefix(3) == ["start", "calibrationStart", "calibrationEnd"])
    }

    @Test("Free space below the floor: warning row, floor row, then a clean stop with reason lowDiskSpace (rules 1, 2; R3-1)")
    func floorStopsCleanly() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let disk = FakeDisk(RecordingFixtures.roomy)
        let session = RecordingFixtures.session(store: scratch.store, disk: disk)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        disk.set(40_000_000)   // below both thresholds in one reading
        #expect(await eventually(5) { session.state == .idle })

        #expect(session.lastStopReason == .lowDiskSpace)
        #expect(session.live.lowDiskSpaceWarning)
        #expect(session.live.availableDiskBytes == 40_000_000)
        let (_, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil)
        let lifecycle = RecordingFixtures.lifecycle(events)
        let warning = try #require(lifecycle.firstIndex { $0.sample == .lowDiskSpaceWarning(availableBytes: 40_000_000) })
        let floor = try #require(lifecycle.firstIndex { $0.sample == .lowDiskSpaceFloor(availableBytes: 40_000_000) })
        let stop = try #require(lifecycle.firstIndex { $0.sample.event == "stop" })
        #expect(warning < floor && floor < stop)
        #expect(lifecycle[stop].sample == .stop(.lowDiskSpace))
        #expect(lifecycle.filter { $0.sample.event == "lowDiskSpace" }.count == 2)
        #expect(RecordingFixtures.kinds(events, .stats).last == events.count - 1)
        // And start is now refused (rule 3).
        #expect(session.startBlocker == .lowDiskSpace(availableBytes: 40_000_000, requiredBytes: 200_000_000))
    }

    @Test("Stop during calibration ends the recording; the calibration wait then neither writes calibrationEnd nor sets recording (R3-2)")
    func stopDuringCalibration() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        let start = Task { try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .milliseconds(800)) }
        #expect(await eventually(2) { session.state == .calibrating })
        let url = try #require(session.currentFile)
        await session.stop()
        #expect(session.state == .idle)
        // Start is free at once, while the old `start` is still in its
        // calibration wait (R4.1-2).
        #expect(session.startBlocker == nil)
        #expect(!session.isStarting)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(session.state == .recording)
        let second = try #require(session.currentFile)
        #expect(second != url)
        // The old call's wake-up leaves the new recording alone.
        try await start.value
        #expect(session.state == .recording)
        #expect(session.currentFile == second)
        await session.stop()
        #expect(session.state == .idle)
        #expect(session.lastStopReason == .user)

        let (_, events, _) = try RecordingFixtures.read(url)
        let lifecycle = RecordingFixtures.lifecycle(events).map(\.sample)
        #expect(lifecycle.map(\.event) == ["start", "calibrationStart", "calibrationEnd", "stop"])
        #expect(lifecycle[2].detail == "interrupted by stop")
        let (_, secondEvents, _) = try RecordingFixtures.read(second)
        let secondLifecycle = RecordingFixtures.lifecycle(secondEvents).map(\.sample)
        #expect(secondLifecycle.map(\.event) == ["start", "calibrationStart", "calibrationEnd", "stop"])
        #expect(secondLifecycle[2].detail == nil)
    }

    @Test("Rule 2 during calibration stops cleanly too, and start returns without recording")
    func floorDuringCalibration() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let disk = FakeDisk(RecordingFixtures.roomy)
        let session = RecordingFixtures.session(store: scratch.store, disk: disk)
        let start = Task { try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .seconds(2)) }
        #expect(await eventually(2) { session.state == .calibrating })
        disk.set(10_000_000)
        #expect(await eventually(5) { session.state == .idle })
        try await start.value
        #expect(session.state == .idle)
        #expect(session.lastStopReason == .lowDiskSpace)
    }

    @Test("A write failure: error row, finish, failed; no stop row (rule 4)")
    func writeFailureEntersFailed() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let source = FakeSource()
        let idle = IdleTimerSpy()
        let session = RecordingFixtures.session(sources: [source], store: scratch.store, idle: idle)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        let generation = try #require(session.currentGeneration)
        try await Task.sleep(for: .milliseconds(200))

        await session.handleWriteFailure(.diskFull, generation: generation)
        #expect(session.state == .failed(reason: "disk full", unwrittenEvents: 0))
        #expect(session.lastStopReason == nil)
        #expect(session.currentFile == nil)
        #expect(idle.values == [true, false])
        #expect(!source.isRunning)
        // A second report, or a stop, changes nothing.
        await session.handleWriteFailure(.diskFull, generation: generation)
        await session.stop()
        #expect(session.state == .failed(reason: "disk full", unwrittenEvents: 0))

        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(events.last?.payload == .lifecycle(LifecycleSample(.error, detail: "write failed: disk full")))
        #expect(RecordingFixtures.index(of: .stop, in: events) == nil)

        // A new recording can start after a failure.
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(session.state == .recording)
        await session.stop()
        #expect(session.state == .idle)
    }

    @Test("A failure delivered while stopping ends in failed, not idle (R3-2, R3-3)")
    func failureWhileStopping() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let generation = try #require(session.currentGeneration)
        let stopping = Task { await session.stop() }
        var turns = 0
        while session.state != .stopping, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        #expect(session.state == .stopping)
        await session.handleWriteFailure(.writeFailed(description: "fsync failed: errno 5"), generation: generation)
        await stopping.value
        #expect(session.state == .failed(reason: "fsync failed: errno 5", unwrittenEvents: 0))
        #expect(session.lastStopReason == nil)
    }

    @Test("A failure delivered right after stop() is called, before its end path runs, still ends in failed (R4.1-1)")
    func failureRightAfterStop() async throws {
        // Two interleavings: the failure before `stop()` has run at all, and
        // after `stop()` has queued its end path but before that path's body
        // ran (one yield). Both must end in `failed`, never `idle`.
        for yields in 0...1 {
            let scratch = try ScratchStore("failureRightAfterStop\(yields)")
            defer { scratch.remove() }
            let session = RecordingFixtures.session(store: scratch.store)
            try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
            let url = try #require(session.currentFile)
            let generation = try #require(session.currentGeneration)
            let stopping = Task { await session.stop() }
            for _ in 0..<yields { await Task.yield() }
            await session.handleWriteFailure(.writeFailed(description: "EIO"), generation: generation)
            await stopping.value
            #expect(session.state == .failed(reason: "EIO", unwrittenEvents: 0), "yields: \(yields)")
            #expect(session.lastStopReason == nil)
            #expect(session.currentFile == nil)

            let (_, events, _) = try RecordingFixtures.read(url)
            let errors = RecordingFixtures.lifecycle(events).filter { $0.sample.event == "error" }.map(\.sample.detail)
            #expect(errors == ["write failed: EIO"], "yields: \(yields)")
        }
    }

    @Test("Notices and failures from an earlier recording's writer are ignored (R3-2)")
    func staleWriterIgnored() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let first = try #require(session.currentGeneration)
        await session.stop()
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)

        await session.handleWriteFailure(.diskFull, generation: first)
        await session.handleDiskSpaceNotice(.critical(availableBytes: 1), generation: first)
        await session.handleDiskSpaceNotice(.low(availableBytes: 1), generation: first)
        #expect(session.state == .recording)
        #expect(!session.live.lowDiskSpaceWarning)
        await session.stop()
        #expect(session.state == .idle)
        #expect(session.lastStopReason == .user)

        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(!RecordingFixtures.lifecycle(events).contains { $0.sample.event == "lowDiskSpace" || $0.sample.event == "error" })
        // Two recordings started in the same second get distinct files.
        #expect(scratch.files.count == 2)
    }

    @Test("A notice after the stop row is queued is ignored (R3-1)")
    func noticeAfterStopRowIgnored() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        let generation = try #require(session.currentGeneration)
        let stopping = Task { await session.stop() }
        // Once the user's stop is under way, deliver a floor notice at every
        // main-actor turn until it completes. Before the stop row is queued
        // a notice may still write its row (it then precedes the stop row);
        // after, nothing.
        var turns = 0
        while session.state != .stopping, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        #expect(session.state == .stopping)
        while session.state != .idle {
            await session.handleDiskSpaceNotice(.critical(availableBytes: 7), generation: generation)
            await Task.yield()
        }
        await stopping.value
        #expect(session.lastStopReason == .user)
        let (_, events, _) = try RecordingFixtures.read(url)
        let stop = try #require(RecordingFixtures.index(of: .stop, in: events))
        #expect(!RecordingFixtures.lifecycle(events).contains { $0.index > stop })
    }

    @Test("Background and foreground rows, memory warning, flush on background")
    func lifecycleRows() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store, flushInterval: .seconds(3_600))
        session.handleScenePhase(.background)   // not recording: nothing
        session.handleScenePhase(.active)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        session.handleScenePhase(.inactive)     // active → inactive: no row
        session.handleScenePhase(.background)
        // The background flush writes a member although the timer is an hour.
        #expect(await eventually(2) {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0) > before
        })
        session.handleScenePhase(.inactive)
        session.handleScenePhase(.active)
        session.handleMemoryWarning()
        await session.stop()

        let (_, events, _) = try RecordingFixtures.read(url)
        let names = RecordingFixtures.lifecycle(events).map(\.sample.event)
        #expect(names == ["start", "calibrationStart", "calibrationEnd", "background", "foreground", "memoryWarning", "stop"])
    }

    @Test("Unavailable or failing sources are error rows; the recording runs")
    func sourceProblemsAreRows() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let missing = FakeSource(name: "gyro")
        missing.availability = .unavailable(reason: "no gyroscope")
        let refused = FakeSource(name: "altimeter")
        refused.startError = FakeStartError()
        let working = FakeSource(name: "accel")
        let session = RecordingFixtures.session(sources: [missing, refused, working], store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(session.state == .recording)
        #expect(working.isRunning && missing.starts == 0)
        await session.stop()
        #expect(missing.stops == 0 && refused.stops == 0 && working.stops == 1)

        let (_, events, _) = try RecordingFixtures.read(url)
        let errors = RecordingFixtures.lifecycle(events).filter { $0.sample.event == "error" }.map(\.sample.detail)
        #expect(errors == ["gyro unavailable: no gyroscope", "altimeter failed to start: permission denied"])
    }

    @Test("Location unavailable: warning before Start (not a blocker), one error row after the source rows, the recording runs (R4.1-5)")
    func noBackgroundSession() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let imu = FakeSource()
        let location = FakeBackgroundSource(name: "referenceLocation")
        location.availability = .unavailable(reason: "Location access is denied")
        let session = RecordingFixtures.session(sources: [imu, location], store: scratch.store)
        let prefix = "No background location session, so the recording may pause while the phone is locked."
        #expect(session.backgroundRiskWarning == "\(prefix) Location access is denied.")
        #expect(session.canStart)

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(session.state == .recording)
        #expect(imu.isRunning && location.starts == 0)
        // Allowing location now doesn't give this recording a background
        // session: its source never started. No second row.
        location.availability = .available
        #expect(session.backgroundRiskWarning == "\(prefix) referenceLocation did not start.")
        await session.stop()
        // Idle, and location is available: no warning for the next one.
        #expect(session.backgroundRiskWarning == nil)

        let (_, events, _) = try RecordingFixtures.read(url)
        let lifecycle = RecordingFixtures.lifecycle(events).map(\.sample)
        #expect(lifecycle.map(\.event) == ["start", "error", "error", "calibrationStart", "calibrationEnd", "stop"])
        #expect(lifecycle[1].detail == "referenceLocation unavailable: Location access is denied")
        #expect(lifecycle[2].detail == RecordingSession.backgroundRiskDetail)
        #expect(RecordingSession.backgroundRiskDetail == "no background location session; recording may pause while locked")
    }

    @Test("Location lost mid-recording: warning and one error row; none while it is available (R4.1-5)")
    func backgroundSessionLost() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = FakeBackgroundSource(name: "referenceLocation")
        let session = RecordingFixtures.session(sources: [location], store: scratch.store)
        #expect(session.backgroundRiskWarning == nil)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(location.isRunning)
        #expect(session.backgroundRiskWarning == nil)

        location.availability = .unavailable(reason: "Location access is denied")
        #expect(session.backgroundRiskWarning?.hasSuffix("Location access is denied.") == true)
        location.availability = .unavailable(reason: "Location access is restricted on this device")
        session.handleScenePhase(.active)
        #expect(session.backgroundRiskWarning?.hasSuffix("Location access is restricted on this device.") == true)
        #expect(session.state == .recording)
        await session.stop()
        // Still unavailable once idle.
        #expect(session.backgroundRiskWarning?.hasSuffix("Location access is restricted on this device.") == true)
        location.availability = .available
        #expect(session.backgroundRiskWarning == nil)

        let (_, events, _) = try RecordingFixtures.read(url)
        let lifecycle = RecordingFixtures.lifecycle(events).map(\.sample)
        #expect(lifecycle.map(\.event) == ["start", "calibrationStart", "calibrationEnd", "error", "stop"])
        #expect(lifecycle[3].detail == RecordingSession.backgroundRiskDetail)
    }

    @Test("A background source that fails to start: its error row, then the background row (R4.1-5)")
    func backgroundSourceFailsToStart() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = FakeBackgroundSource(name: "referenceLocation")
        location.startError = FakeStartError()
        let session = RecordingFixtures.session(sources: [location], store: scratch.store)
        #expect(session.backgroundRiskWarning == nil)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(session.backgroundRiskWarning?.hasSuffix("referenceLocation did not start.") == true)
        await session.stop()
        #expect(session.backgroundRiskWarning == nil)

        let (_, events, _) = try RecordingFixtures.read(url)
        let errors = RecordingFixtures.lifecycle(events).filter { $0.sample.event == "error" }.map(\.sample.detail)
        #expect(errors == ["referenceLocation failed to start: permission denied", RecordingSession.backgroundRiskDetail])
    }

    @Test("Simulator GPS speed: live.gpsSpeedKmh from the simulated location source, display only (M2-S2)")
    func simulatedGPSSpeed() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = SimulatedLocationSource(interval: .milliseconds(100))
        let session = RecordingFixtures.session(sources: [location], store: scratch.store)
        #expect(session.live.gpsSpeedKmh == nil)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(await eventually(3) { session.live.gpsSpeedKmh != nil })
        #expect(abs((session.live.gpsSpeedKmh ?? 0) - 13.9 * 3.6) < 1e-9)
        await session.stop()
        #expect(session.live.gpsSpeedKmh == nil)
        #expect(location.latestReferenceFix == nil)

        // What is recorded is the simulated source's rows and nothing else:
        // simulated fixes at exactly 100 ms spacing.
        let (_, events, _) = try RecordingFixtures.read(url)
        let fixes = events.filter { $0.payload.kind == "location" }
        #expect(fixes.count >= 10)
        #expect(fixes.allSatisfy { if case .location(let fix) = $0.payload { fix.simulated == true } else { false } })
        let times = fixes.map(\.timestamp.nanoseconds)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 100_000_000 })
    }

    @Test("Map fix: live.referenceFix is the simulated source's latest fix while recording, nil after stop")
    func simulatedReferenceFix() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        // A long interval: only fix 0 (delivered at start) exists while the
        // test runs, so the 1 Hz live copy and the source cannot race.
        let location = SimulatedLocationSource(interval: .seconds(60))
        let session = RecordingFixtures.session(sources: [location], store: scratch.store)
        #expect(session.live.referenceFix == nil)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(await eventually(3) { session.live.referenceFix != nil })
        let shown = try #require(session.live.referenceFix)
        #expect(shown == location.latestReferenceFix)
        await session.stop()
        #expect(session.live.referenceFix == nil)
        #expect(location.latestReferenceFix == nil)

        // Display only: the fix shown is the one recorded, and nothing extra
        // was written for it.
        let (_, events, _) = try RecordingFixtures.read(url)
        let recorded = events.compactMap { if case .location(let fix) = $0.payload { fix } else { nil } }
        #expect(recorded == [shown])
    }

    @Test("Link events: written only while recording; OBD speed from the engine ECU only")
    func linkEvents() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        func reading(_ value: Double, ecu: String) -> LinkEvent {
            let now = ProcessInfo.processInfo.systemUptime
            return .session(.reading(OBDReading(
                seq: 1, command: "010D0C1", ecu: ecu,
                measurement: OBDMeasurement(pid: .vehicleSpeed, value: value, unit: .kilometersPerHour),
                raw: "7E804410D32", requestUptime: now - 0.04, replyUptime: now
            )))
        }
        link.send(reading(50, ecu: "7E8"))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 50 })
        link.send(reading(80, ecu: "7E9"))
        link.send(.session(.pollRate(hz: 21.5, uptime: ProcessInfo.processInfo.systemUptime)))
        #expect(await eventually(2) { session.live.obdHz == 21.5 })
        #expect(session.live.obdSpeedKmh == 50)

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        link.send(reading(51, ecu: "7E8"))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 51 })
        await session.stop()
        link.send(reading(52, ecu: "7E8"))
        #expect(await eventually(2) { session.live.obdSpeedKmh == 52 })

        let (_, events, _) = try RecordingFixtures.read(url)
        let obd = events.compactMap { event -> Double? in
            if case .obd(let sample) = event.payload { sample.value } else { nil }
        }
        #expect(obd == [51])
    }

    @Test("The recording being written can't be deleted; a finished one can, and free space is refreshed")
    func deleteRecording() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let disk = FakeDisk(RecordingFixtures.roomy)
        let session = RecordingFixtures.session(store: scratch.store, disk: disk)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let current = try #require(try scratch.store.list().first)
        await #expect(throws: LogStoreError.recordingInProgress(path: current.url.path)) {
            try await session.deleteRecording(current)
        }
        await session.stop()
        disk.set(RecordingFixtures.roomy + 1)
        try await session.deleteRecording(current)
        #expect(scratch.files.isEmpty)
        #expect(session.availableDiskBytes == RecordingFixtures.roomy + 1)
    }
}
