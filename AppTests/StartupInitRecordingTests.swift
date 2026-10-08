import CoreLocation
import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// M4 fixes (docs/BENCH_TEST_2026-10-08.md), recorder side:
// A — the link's start-up init is written at Start (`lastInitEvents`, with
//     the dedup contract in `OBDLinkServicing`), with negative `t`; since
//     M6.1-1 only the current connection's, from `→ connected`, and nothing
//     when the link is down at Start;
// B — location authorisation is in the file.

/// Link events as the real link would deliver them, on the uptime base.
enum InitScript {
    static func exchange(_ seq: Int, _ tx: String, rx: String? = "OK", phase: ELMPhase, at uptime: Double) -> LinkEvent {
        .session(.exchange(ELMExchange(
            seq: seq, phase: phase, tx: tx, requestUptime: uptime - 0.05, rx: rx,
            completedUptime: uptime, outcome: .ok
        )))
    }

    /// BLE `connecting → discovering → connected`, as delivered live. Only
    /// the last one is in `lastInitEvents` (M6.1-1).
    static func connection(at uptime: Double) -> [LinkEvent] {
        [
            .ble(from: .idle, to: .connecting, reason: nil, uptime: uptime),
            .ble(from: .connecting, to: .discovering, reason: nil, uptime: uptime + 0.3),
            .ble(from: .discovering, to: .connected, reason: "vgate", uptime: uptime + 0.6),
        ]
    }

    static let handshake = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0"]

    /// `→ resetting`, the handshake (`seq` from `firstSeq`), probing, one
    /// probe exchange, the `adapter` event, `ready`, `polling`: 11
    /// exchanges, 16 events. `uptime(i)` stamps event `i`.
    static func initialisation(firstSeq: Int, from: ELMState = .idle, uptime: (Int) -> Double) -> [LinkEvent] {
        var events: [LinkEvent] = [.session(.state(from: from, to: .resetting, reason: nil, uptime: uptime(0)))]
        for (offset, tx) in handshake.enumerated() {
            events.append(exchange(firstSeq + offset, tx, rx: tx == "ATZ" ? "ELM327 v2.3" : "OK", phase: .initialisation, at: uptime(events.count)))
        }
        events.append(.session(.state(from: .initialising, to: .probing, reason: nil, uptime: uptime(events.count))))
        events.append(exchange(firstSeq + handshake.count, "010D0C1", rx: "7E8064110D000C0A6C", phase: .probe, at: uptime(events.count)))
        let info = ELMAdapterInfo(elmVersion: "ELM327 v2.3", protocolNumber: "A6", voltage: 12.2, supportedPIDs: nil, plan: .baseline)
        events.append(.session(.adapter(info, uptime: uptime(events.count))))
        events.append(.session(.state(from: .probing, to: .ready, reason: nil, uptime: uptime(events.count))))
        events.append(.session(.state(from: .ready, to: .polling, reason: nil, uptime: uptime(events.count))))
        return events
    }

    /// One successful poll: its `elm` exchange and the speed reading.
    static func poll(seq: Int, speed: Double, at uptime: Double) -> [LinkEvent] {
        [
            exchange(seq, "010D0C1", rx: "7E804410D32", phase: .poll, at: uptime),
            .session(.reading(OBDReading(
                seq: seq, command: "010D0C1", ecu: "7E8",
                measurement: OBDMeasurement(pid: .vehicleSpeed, value: speed, unit: .kilometersPerHour),
                raw: "7E804410D32", requestUptime: uptime - 0.05, replyUptime: uptime
            ))),
        ]
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }
}

/// What the file says about the link.
struct LinkRows {
    let events: [LogEvent]

    var seqs: [Int] {
        events.compactMap { if case .elm(let row) = $0.payload { row.seq } else { nil } }
    }

    func elm(_ tx: String) -> [LogEvent] {
        events.filter { if case .elm(let row) = $0.payload { row.tx == tx } else { false } }
    }

    var speeds: [Double] {
        events.compactMap { if case .obd(let row) = $0.payload { row.value } else { nil } }
    }

    func count(_ kind: String) -> Int {
        events.filter { $0.payload.kind == kind }.count
    }

    func bleTransitions(to state: String) -> Int {
        events.filter { $0.payload.kind == "link" && { if case .link(let row) = $0.payload { row.layer == "ble" && row.to == state } else { false } }($0) }.count
    }

    func elmTransitions(to state: String) -> Int {
        events.filter { if case .link(let row) = $0.payload { row.layer == "elm" && row.from != row.to && row.to == state } else { false } }.count
    }
}

@Suite("RecordingSession start-up init (M4)", .serialized)
@MainActor
struct StartupInitRecordingTests {
    typealias S = InitScript

    @Test("Start while polling: the init right after the start row, from → connected, negative t, once; pre-Start polls not written; seq unique, increasing, one gap")
    func startWhilePolling() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        let base = S.now
        let connection = S.connection(at: base - 20)
        let initEvents = [connection[2]] + S.initialisation(firstSeq: 0) { base - 19 + Double($0) * 0.1 }
        link.lastInitEvents = initEvents
        for event in connection.prefix(2) + initEvents { link.send(event) }
        // Pre-Start polls (seq 11…20), consumed by the session for the
        // dashboard, never written.
        for index in 0..<10 {
            for event in S.poll(seq: 11 + index, speed: 30 + Double(index), at: base - 10 + Double(index) * 0.1) { link.send(event) }
        }
        #expect(await eventually(2) { session.live.obdSpeedKmh == 39 && session.consumedLinkEvents == link.deliveredLinkEventCount })
        // And three more (seq 21…23) delivered at the instant of the
        // snapshot: still in the stream buffer, unconsumed.
        link.onNextInitSnapshot = {
            for index in 0..<3 {
                for event in S.poll(seq: 21 + index, speed: 40 + Double(index), at: S.now - 0.01) { link.send(event) }
            }
        }

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(link.onNextInitSnapshot == nil, "the session read the snapshot during start")
        let url = try #require(session.currentFile)
        for index in 0..<5 {
            for event in S.poll(seq: 30 + index, speed: 50 + Double(index), at: S.now) { link.send(event) }
        }
        #expect(await eventually(2) { session.live.obdSpeedKmh == 54 })
        await session.stop()

        let (header, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil && !report.truncatedTail)
        #expect(events.first?.payload == .lifecycle(LifecycleSample(.start)), "the start row stays first")
        // The replay: exactly the rows the live mapping gives, on this
        // recording's clock, right after the start row.
        let clock = SessionClock(header: header)
        let replay = initEvents.flatMap { LogEvent.rows(for: $0, adapter: link.adapter, clock: clock) }
        #expect(replay.count == initEvents.count)
        #expect(Array(events.dropFirst().prefix(replay.count)) == replay)
        #expect(replay.allSatisfy { $0.timestamp.nanoseconds < 0 }, "negative t, not clamped")
        #expect(replay.first?.timestamp == MonotonicTimestamp(seconds: base - 20 + 0.6 - header.referenceUptimeSeconds))

        let rows = LinkRows(events: events)
        #expect(rows.seqs == Array(0...10) + Array(30...34), "init once, then live only")
        #expect(Set(rows.seqs).count == rows.seqs.count)
        #expect(rows.seqs == rows.seqs.sorted())
        #expect(rows.speeds == [50, 51, 52, 53, 54], "no pre-Start poll")
        #expect(rows.bleTransitions(to: "connected") == 1)
        #expect(rows.bleTransitions(to: "connecting") == 0 && rows.bleTransitions(to: "discovering") == 0)
        #expect(rows.count("adapter") == 1)
        #expect(rows.elm("ATZ").count == 1 && rows.elm("ATSH7E0").count == 1)
        #expect(events.dropFirst(replay.count + 1).allSatisfy { $0.timestamp.nanoseconds >= -50_000_000 || $0.payload.kind != "elm" })

        // The first stats window starts at the start row, not at the
        // replay's earliest `t` (20 s before Start).
        let firstStats = try #require(events.lazy.compactMap { if case .stats(let s) = $0.payload { s } else { nil } }.first)
        #expect(firstStats.windowS < 5, "windowS \(firstStats.windowS)")
        #expect((firstStats.counts["elm"] ?? 0) >= 11)
    }

    @Test("Start mid-init: every init event exactly once, its first part replayed and the rest live")
    func startMidInit() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        link.state = .initialising
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        /// What the link does: deliver, and keep it as the current init.
        func deliver(_ events: [LinkEvent]) {
            link.lastInitEvents += events
            for event in events { link.send(event) }
        }
        let base = S.now
        let initEvents = S.connection(at: base - 5) + S.initialisation(firstSeq: 0) { base - 4 + Double($0) * 0.1 }
        // Delivered and consumed: the connection (only `connected` is kept
        // in `lastInitEvents`), → resetting, ATZ, ATE0.
        for event in initEvents[0..<2] { link.send(event) }
        deliver(Array(initEvents[2..<6]))
        #expect(await eventually(2) { session.consumedLinkEvents == link.deliveredLinkEventCount })
        // Delivered at the snapshot, unconsumed: ATL0, ATS0.
        link.onNextInitSnapshot = { deliver(Array(initEvents[6..<8])) }

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        let url = try #require(session.currentFile)
        // The rest of the init after Start, then polls; the link stops
        // adding to `lastInitEvents` at `polling`.
        let rest = Array(initEvents[8...]).map { event -> LinkEvent in event }
        for event in rest { link.send(event) }
        link.state = .polling(protocolNumber: "A6", voltage: 12.2)
        for index in 0..<3 {
            for event in S.poll(seq: 11 + index, speed: 60 + Double(index), at: S.now) { link.send(event) }
        }
        #expect(await eventually(2) { session.live.obdSpeedKmh == 62 })
        await session.stop()

        let (header, events, _) = try RecordingFixtures.read(url)
        let start = try #require(RecordingFixtures.lifecycle(events).first?.sample)
        #expect(start.detail == "without OBD: link initialising")
        let rows = LinkRows(events: events)
        #expect(rows.seqs == Array(0...13), "every exchange from ATZ on, once, in order")
        for tx in S.handshake { #expect(rows.elm(tx).count == 1, "\(tx)") }
        #expect(rows.bleTransitions(to: "connected") == 1)
        #expect(rows.elmTransitions(to: "resetting") == 1)
        #expect(rows.elmTransitions(to: "polling") == 1)
        #expect(rows.count("adapter") == 1)
        #expect(rows.speeds == [60, 61, 62])
        // connected, ATZ … ATS0 were replayed (before Start); the rest are live.
        let clock = SessionClock(header: header)
        let replayed = Array(initEvents[2..<8]).flatMap { LogEvent.rows(for: $0, adapter: link.adapter, clock: clock) }
        #expect(Array(events.dropFirst().prefix(replayed.count)) == replayed)
        #expect(replayed.allSatisfy { $0.timestamp.nanoseconds < 0 })
    }

    @Test("An init during the recording arrives live and is not replayed; the next recording replays the newer init only")
    func initDuringRecording() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        let base = S.now
        let connection = S.connection(at: base - 30)
        let initA = S.initialisation(firstSeq: 0) { base - 29 + Double($0) * 0.1 }
        link.lastInitEvents = [connection[2]] + initA
        for event in connection + initA { link.send(event) }
        #expect(await eventually(2) { session.consumedLinkEvents == link.deliveredLinkEventCount })

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let first = try #require(session.currentFile)
        for index in 0..<2 {
            for event in S.poll(seq: 11 + index, speed: 20, at: S.now) { link.send(event) }
        }
        // A re-init on the same connection (seq 13…23): the link replaces
        // the init part of `lastInitEvents` and delivers it live.
        let now = S.now
        let initB = S.initialisation(firstSeq: 13, from: .polling) { now + Double($0) * 0.001 }
        link.lastInitEvents = [connection[2]] + initB
        for event in initB { link.send(event) }
        for index in 0..<2 {
            for event in S.poll(seq: 24 + index, speed: 21, at: S.now) { link.send(event) }
        }
        #expect(await eventually(2) { session.consumedLinkEvents == link.deliveredLinkEventCount })
        await session.stop()

        let (_, events, _) = try RecordingFixtures.read(first)
        let rows = LinkRows(events: events)
        #expect(rows.seqs == Array(0...25), "both inits once, polls once")
        #expect(rows.elm("ATZ").count == 2)
        #expect(rows.elm("ATZ").map { $0.timestamp.nanoseconds < 0 } == [true, false], "init A replayed, init B live")
        #expect(rows.count("adapter") == 2)
        #expect(rows.bleTransitions(to: "connected") == 1)

        // Every event was consumed before this Start: nothing to skip, and
        // the replay is the connection with init B.
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let second = try #require(session.currentFile)
        for event in S.poll(seq: 26, speed: 22, at: S.now) { link.send(event) }
        #expect(await eventually(2) { session.live.obdSpeedKmh == 22 })
        await session.stop()
        let secondRows = LinkRows(events: try RecordingFixtures.read(second).events)
        #expect(secondRows.seqs == Array(13...23) + [26])
        #expect(secondRows.elm("ATZ").count == 1)
        #expect(secondRows.bleTransitions(to: "connected") == 1)
        #expect(secondRows.speeds == [22])
    }

    @Test("No connection: nothing is replayed")
    func noConnection() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        link.state = .idle
        link.adapter = nil
        link.plan = nil
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        let url = try #require(session.currentFile)
        await session.stop()
        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(!events.contains { ["link", "elm", "adapter", "obd"].contains($0.payload.kind) })
        #expect(RecordingFixtures.lifecycle(events).map(\.sample.event) == ["start", "calibrationStart", "calibrationEnd", "stop"])
        #expect(RecordingFixtures.lifecycle(events).first?.sample.detail == "without OBD: link idle")
    }

    // MARK: M6.1-1 with the real link service (FakeBLECentral + MockELMAdapter)

    static func realLink(backoff: Duration = .milliseconds(20)) -> (OBDLinkService, FakeBLECentral) {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = OBDLinkService(
            central: central, defaults: LinkTestSupport.defaults(),
            sessionConfiguration: LinkTestSupport.configuration,
            backoff: ReconnectBackoff(initial: backoff, maximum: backoff)
        )
        return (link, central)
    }

    static func linkRows(_ events: [LogEvent]) -> [LinkSample] {
        events.compactMap { if case .link(let row) = $0.payload { row } else { nil } }
    }

    @Test("Real link, Start while polling: the replay begins at → connected; no connecting/discovering rows")
    func realLinkStartWhilePolling() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (link, _) = Self.realLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && session.consumedLinkEvents > 40 })

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(await eventually { session.consumedLinkEvents > link.lastInitEvents.count + 80 })
        await session.stop()
        link.disconnect()

        let (_, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil)
        let first = try #require(events.dropFirst().first)
        if case .link(let row) = first.payload {
            #expect(row.layer == "ble" && row.from == "discovering" && row.to == "connected")
            #expect(first.timestamp.nanoseconds < 0)
        } else {
            Issue.record("the row after start is the replayed → connected, got \(first.payload.kind)")
        }
        let rows = LinkRows(events: events)
        #expect(rows.bleTransitions(to: "connected") == 1)
        #expect(rows.bleTransitions(to: "connecting") == 0 && rows.bleTransitions(to: "discovering") == 0)
        #expect(rows.elm("ATZ").count == 1)
        #expect(rows.count("adapter") >= 1)
        #expect(rows.seqs == rows.seqs.sorted() && Set(rows.seqs).count == rows.seqs.count)
    }

    @Test("Real link dropped before Start (reconnecting): nothing replayed; the first link row is the live reconnecting → connecting")
    func realLinkStartAfterDrop() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (link, central) = Self.realLink(backoff: .milliseconds(500))
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && session.consumedLinkEvents > 40 })
        await central.loseLink()
        // The dropped session's last event (`→ failed`, transport closed)
        // is delivered and consumed before Start.
        #expect(await eventually {
            link.bleState == .reconnecting && link.console.contains { $0.text.hasSuffix("→ failed (transport closed)") }
                && session.consumedLinkEvents == link.deliveredLinkEventCount
        })

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        let url = try #require(session.currentFile)
        #expect(await eventually { link.state.isPolling && session.live.obdSpeedKmh != nil && central.adapters.count == 2 })
        #expect(await eventually { session.consumedLinkEvents == link.deliveredLinkEventCount })
        await session.stop()
        link.disconnect()

        let (_, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil)
        let start = try #require(RecordingFixtures.lifecycle(events).first?.sample)
        #expect(start.detail?.hasPrefix("without OBD: link reconnecting") == true)
        #expect(!events.contains { $0.timestamp.nanoseconds < 0 && ["link", "elm", "adapter", "obd"].contains($0.payload.kind) },
                "no replayed rows")
        let link0 = try #require(Self.linkRows(events).first)
        #expect(link0.layer == "ble" && link0.from == "reconnecting" && link0.to == "connecting")
        let rows = LinkRows(events: events)
        #expect(rows.bleTransitions(to: "connected") == 1)
        #expect(rows.elm("ATZ").count == 1, "the new connection's init only")
        #expect(rows.seqs == rows.seqs.sorted() && Set(rows.seqs).count == rows.seqs.count)
    }

    @Test("Real link, Disconnect, then Start without OBD: nothing replayed")
    func realLinkStartAfterDisconnect() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (link, _) = Self.realLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && session.consumedLinkEvents > 40 })
        link.disconnect()
        #expect(await eventually { session.consumedLinkEvents == link.deliveredLinkEventCount })

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        let url = try #require(session.currentFile)
        try await Task.sleep(for: .milliseconds(200))
        await session.stop()

        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(RecordingFixtures.lifecycle(events).first?.sample.detail == "without OBD: link idle")
        #expect(!events.contains { ["elm", "adapter", "obd"].contains($0.payload.kind) })
        #expect(LinkRows(events: events).bleTransitions(to: "connected") == 0)
    }
}

/// Lock-guarded counter for delegate callbacks, which are `@Sendable`.
final class CallCounter: Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Location authorisation in the file (M4)", .serialized)
@MainActor
struct LocationAuthorizationTests {
    static let benchError = NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue)

    static func snapshot(_ status: CLAuthorizationStatus, _ accuracy: CLAccuracyAuthorization = .fullAccuracy) -> LocationAuthorizationSnapshot {
        LocationAuthorizationSnapshot(status: status, accuracy: accuracy)
    }

    @Test("availability and the start-row detail from the authorisation provider")
    func sourceReadsProvider() {
        let cases: [(CLAuthorizationStatus, CLAccuracyAuthorization, String, Bool)] = [
            (.notDetermined, .fullAccuracy, "authorizationStatus=notDetermined, accuracyAuthorization=full", true),
            (.restricted, .fullAccuracy, "authorizationStatus=restricted, accuracyAuthorization=full", false),
            (.denied, .fullAccuracy, "authorizationStatus=denied, accuracyAuthorization=full", false),
            (.authorizedWhenInUse, .reducedAccuracy, "authorizationStatus=authorizedWhenInUse, accuracyAuthorization=reduced", true),
            (.authorizedAlways, .fullAccuracy, "authorizationStatus=authorizedAlways, accuracyAuthorization=full", true),
        ]
        for (status, accuracy, detail, available) in cases {
            let source = ReferenceLocationSource(authorization: FakeLocationAuthorization(status, accuracy: accuracy))
            #expect((source.availability == .available) == available, "\(detail)")
            // Not started: no background activity session held.
            #expect(source.locationAuthorizationDetail == detail + ", backgroundActivitySession=none")
            #expect(Self.snapshot(status, accuracy).detail == detail)
            #expect(Self.snapshot(status, accuracy).isDeniedOrRestricted == !available)
        }
    }

    @Test("kCLErrorDenied while authorised (the bench's Code=1): error row with the authorisation, no availability change, fixes keep coming")
    func transientDenied() async throws {
        let delegate = ReferenceLocationDelegate()
        let changes = CallCounter()
        delegate.observeAuthorization { changes.increment() }
        let (_, events) = try await recordedEvents { clock, sink in
            delegate.begin(gate: SampleGate(source: "referenceLocation", clock: clock, sink: sink)) { _ in }
            delegate.handleFailure(Self.benchError, authorization: Self.snapshot(.authorizedWhenInUse))
            delegate.handleFailure(Self.benchError, authorization: Self.snapshot(.authorizedWhenInUse))
            // `locationUnknown` is transient and silent.
            delegate.handleFailure(CLError(.locationUnknown), authorization: Self.snapshot(.authorizedWhenInUse))
            let fix = CLLocation(latitude: 50.45, longitude: 30.52)
            delegate.locationManager(CLLocationManager(), didUpdateLocations: [fix])
            delegate.end()
        }
        #expect(changes.count == 0, "no availability change, so no background-risk row")
        let lifecycle = RecordingFixtures.lifecycle(events).map(\.sample)
        #expect(lifecycle == [LifecycleSample(
            .error,
            detail: #"referenceLocation: Error Domain=kCLErrorDomain Code=1 "(null)" (authorizationStatus=authorizedWhenInUse, accuracyAuthorization=full)"#
        )], "once per distinct text")
        #expect(events.filter { $0.payload.kind == "location" }.count == 1, "the source was not stopped")
    }

    @Test("kCLErrorDenied while authorisation reads denied: error row and an availability change")
    func deniedForReal() async throws {
        let delegate = ReferenceLocationDelegate()
        let changes = CallCounter()
        delegate.observeAuthorization { changes.increment() }
        let (_, events) = try await recordedEvents { clock, sink in
            delegate.begin(gate: SampleGate(source: "referenceLocation", clock: clock, sink: sink)) { _ in }
            delegate.handleFailure(Self.benchError, authorization: Self.snapshot(.denied))
            // Another error while denied is not a denial: no change.
            delegate.handleFailure(CLError(.network), authorization: Self.snapshot(.denied))
            delegate.end()
        }
        #expect(changes.count == 1)
        let details = RecordingFixtures.lifecycle(events).map(\.sample.detail)
        #expect(details.first == #"referenceLocation: Error Domain=kCLErrorDomain Code=1 "(null)" (authorizationStatus=denied, accuracyAuthorization=full)"#)
        #expect(details.count == 2)
    }

    @Test("An authorisation change while recording: a locationAuthorization row, plus the error row when denied")
    func changeWhileRecording() async throws {
        let delegate = ReferenceLocationDelegate()
        let changes = CallCounter()
        delegate.observeAuthorization { changes.increment() }
        // Not recording: availability change only, no row anywhere.
        delegate.handleAuthorizationChange(Self.snapshot(.authorizedWhenInUse))
        let (_, events) = try await recordedEvents { clock, sink in
            delegate.begin(gate: SampleGate(source: "referenceLocation", clock: clock, sink: sink)) { _ in }
            delegate.handleAuthorizationChange(Self.snapshot(.authorizedWhenInUse, .reducedAccuracy))
            delegate.handleAuthorizationChange(Self.snapshot(.denied))
            delegate.end()
        }
        #expect(changes.count == 3)
        #expect(RecordingFixtures.lifecycle(events).map(\.sample) == [
            LifecycleSample(.locationAuthorization, detail: "authorizationStatus=authorizedWhenInUse, accuracyAuthorization=reduced"),
            LifecycleSample(.locationAuthorization, detail: "authorizationStatus=denied, accuracyAuthorization=full"),
            LifecycleSample(.error, detail: "referenceLocation: authorization denied while recording; no more reference fixes"),
        ])
    }

    @Test("Session: the locationAuthorization row after the source rows; with access, no background-risk row even when availability is re-checked")
    func sessionRowAuthorised() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let imu = FakeSource()
        let location = FakeLocationSource(name: "referenceLocation")
        let session = RecordingFixtures.session(sources: [imu, location], store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        // What a transient kCLErrorDenied would do if it reported a change:
        // availability still reads available, so nothing.
        location.onAvailabilityChange?()
        #expect(session.backgroundRiskWarning == nil)
        await session.stop()

        let lifecycle = RecordingFixtures.lifecycle(try RecordingFixtures.read(url).events).map(\.sample)
        #expect(lifecycle.map(\.event) == ["start", "locationAuthorization", "calibrationStart", "calibrationEnd", "stop"])
        #expect(lifecycle[1].detail == "authorizationStatus=authorizedWhenInUse, accuracyAuthorization=full, backgroundActivitySession=held")
    }

    @Test("Session, location denied: unavailable row, locationAuthorization row, then the background-risk row")
    func sessionRowDenied() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = FakeLocationSource(name: "referenceLocation")
        location.availability = .unavailable(reason: "Location access is denied")
        location.locationAuthorizationDetail = "authorizationStatus=denied, accuracyAuthorization=full, backgroundActivitySession=none"
        let session = RecordingFixtures.session(sources: [FakeSource(), location], store: scratch.store)
        #expect(session.backgroundRiskWarning != nil)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        await session.stop()

        let lifecycle = RecordingFixtures.lifecycle(try RecordingFixtures.read(url).events).map(\.sample)
        #expect(lifecycle == [
            LifecycleSample(.start),
            LifecycleSample(.error, detail: "referenceLocation unavailable: Location access is denied"),
            LifecycleSample(.locationAuthorization, detail: "authorizationStatus=denied, accuracyAuthorization=full, backgroundActivitySession=none"),
            LifecycleSample(.error, detail: RecordingSession.backgroundRiskDetail),
            LifecycleSample(.calibrationStart, detail: "keep still for 0.0 s"),
            LifecycleSample(.calibrationEnd),
            .stop(.user),
        ])
    }
}
