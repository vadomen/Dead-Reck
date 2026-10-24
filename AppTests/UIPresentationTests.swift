import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

@Suite("DisplayFormat")
struct DisplayFormatTests {
    @Test("Speed is whole km/h, -- without a reading, never negative")
    func speed() {
        #expect(DisplayFormat.speed(nil) == "--")
        #expect(DisplayFormat.speed(62.4) == "62")
        #expect(DisplayFormat.speed(62.5) == "63")
        #expect(DisplayFormat.speed(-3) == "0")
        #expect(DisplayFormat.speed(.nan) == "--")
    }

    @Test("Elapsed is m:ss, then h:mm:ss from one hour")
    func elapsed() {
        #expect(DisplayFormat.elapsed(0) == "0:00")
        #expect(DisplayFormat.elapsed(65.9) == "1:05")
        #expect(DisplayFormat.elapsed(3600) == "1:00:00")
        #expect(DisplayFormat.elapsed(7384) == "2:03:04")
        #expect(DisplayFormat.elapsed(-5) == "0:00")
        #expect(DisplayFormat.duration(nil) == "--")
    }

    @Test("Bytes use decimal units, in the locale's unit names (UX-15)")
    func bytes() {
        let en = Locale(identifier: "en_US")
        #expect(DisplayFormat.bytes(0, locale: en) == "0 bytes")
        #expect(DisplayFormat.bytes(10, locale: en) == "10 bytes")
        #expect(DisplayFormat.bytes(1_500, locale: en) == "2 kB")
        #expect(DisplayFormat.bytes(48_200_000, locale: en) == "48.2 MB")
        #expect(DisplayFormat.bytes(2_500_000_000 as Int64, locale: en) == "2.5 GB")
    }

    @Test("Hz and voltage")
    func hzAndVoltage() {
        #expect(DisplayFormat.hz(9.84) == "9.8")
        #expect(DisplayFormat.voltage(12.44) == "12.4 V")
        #expect(DisplayFormat.voltage(nil) == nil)
    }

    @Test("The countdown rounds up and never goes negative")
    func countdown() {
        #expect(DisplayFormat.secondsLeft(total: 5, elapsed: 0) == 5)
        #expect(DisplayFormat.secondsLeft(total: 5, elapsed: 0.2) == 5)
        #expect(DisplayFormat.secondsLeft(total: 5, elapsed: 4.1) == 1)
        #expect(DisplayFormat.secondsLeft(total: 5, elapsed: 9) == 0)
    }
}

@Suite("AdapterStatus")
struct AdapterStatusTests {
    @Test("Every link state maps to a title and a tone; only polling is good")
    func mapping() {
        let polling = AdapterStatus(.polling(protocolNumber: "A6", voltage: 12.4))
        #expect(polling.title == "Polling OBD")
        #expect(polling.detail == "protocol A6 · 12.4 V")
        #expect(polling.tone == .good && polling.isPolling)

        #expect(AdapterStatus(.polling(protocolNumber: "6", voltage: nil)).detail == "protocol 6")
        #expect(AdapterStatus(.scanning).tone == .caution)
        #expect(AdapterStatus(.connecting).tone == .caution)
        #expect(AdapterStatus(.discoveringServices).tone == .caution)
        #expect(AdapterStatus(.initialising).title == "Initialising adapter")
        #expect(AdapterStatus(.ready).isPolling == false)

        for lost in [OBDLinkState.idle, .reconnecting(attempt: 3), .failed(reason: "x"), .unavailable(reason: "off")] {
            #expect(AdapterStatus(lost).tone == .bad)
            #expect(AdapterStatus(lost).isPolling == false)
        }
    }

    @Test("Bluetooth unavailable says so and carries the reason")
    func unavailable() {
        let status = AdapterStatus(.unavailable(reason: "Bluetooth is off"))
        #expect(status.title == "Bluetooth unavailable")
        #expect(status.detail == "Bluetooth is off")
    }
}

@Suite("DashboardState")
struct DashboardStateTests {
    private func inputs(
        state: RecordingState = .idle,
        live: LiveStatus = LiveStatus(),
        link: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4)
    ) -> DashboardState.Inputs {
        .init(
            state: state, live: live, link: link, startBlocker: nil,
            allowsRecordingWithoutOBD: false, backgroundRisk: nil, lastStopReason: nil,
            unavailableSensors: [], simulatedAdapter: false, simulatedSensors: false, calibrationSeconds: 5
        )
    }

    @Test("Idle is red NOT RECORDING; recording is green; calibration says keep still with seconds left")
    func headlines() {
        #expect(DashboardState.make(inputs()).headline == ("NOT RECORDING", .bad))
        #expect(DashboardState.make(inputs(state: .recording)).headline == ("RECORDING", .good))
        var live = LiveStatus()
        live.elapsed = 1.5
        let calibrating = DashboardState.make(inputs(state: .calibrating, live: live))
        #expect(calibrating.phase == .calibrating(secondsLeft: 4))
        #expect(calibrating.headline == ("KEEP STILL  4 s", .caution))
        #expect(DashboardState.make(inputs(state: .stopping)).headline.tone == .caution)
    }

    @Test("Live numbers are formatted; missing speeds show --")
    func numbers() {
        var live = LiveStatus(obdSpeedKmh: 62.2, gpsSpeedKmh: nil, obdHz: 9.84, motionHz: 99.7)
        live.elapsed = 754
        live.fileBytes = 48_200_000
        let s = DashboardState.make(inputs(state: .recording, live: live))
        #expect(s.obdSpeed == "62" && s.gpsSpeed == "--")
        #expect(s.obdHz == "9.8" && s.motionHz == "99.7")
        #expect(s.elapsed == "12:34" && s.fileSize == "48.2 MB")
    }

    @Test("Recording without a polling adapter turns the OBD tile red; polling turns it green")
    func obdTone() {
        #expect(DashboardState.make(inputs(state: .recording, link: .reconnecting(attempt: 1))).obdTone == .bad)
        #expect(DashboardState.make(inputs(state: .recording)).obdTone == .good)
        #expect(DashboardState.make(inputs(state: .idle, link: .idle)).obdTone == .neutral)
    }

    @Test("Failed shows the reason and the unwritten count")
    func failed() {
        let s = DashboardState.make(inputs(state: .failed(reason: "no space left", unwrittenEvents: 42)))
        #expect(s.headline == ("RECORDING FAILED", .bad))
        let notice = try? #require(s.notices.first)
        #expect(notice?.tone == .bad)
        #expect(notice?.text.contains("no space left") == true)
        #expect(notice?.text.contains("42") == true)
    }

    @Test("Low disk warning shows only while recording; a low-disk stop is explained when idle")
    func lowDisk() {
        var live = LiveStatus()
        live.lowDiskSpaceWarning = true
        live.availableDiskBytes = 150_000_000
        #expect(DashboardState.make(inputs(state: .recording, live: live)).notices.first?.text.contains("150 MB") == true)
        #expect(DashboardState.make(inputs(state: .idle, live: live)).notices.isEmpty)

        var i = inputs()
        i.lastStopReason = .lowDiskSpace
        #expect(DashboardState.make(i).notices.first?.text.contains("disk space") == true)
    }

    @Test("Background risk and unavailable sensors become notices, using readable names")
    func warnings() {
        var i = inputs()
        i.backgroundRisk = "No background location session: denied."
        i.unavailableSensors = [("deviceMotion", "no motion hardware")]
        let texts = DashboardState.make(i).notices.map(\.text)
        #expect(texts.contains("No background location session: denied."))
        #expect(texts.contains("Motion unavailable: no motion hardware"))
    }

    @Test("Blocker and the simulation badge")
    func blockerAndBadge() {
        var i = inputs(link: .idle)
        i.startBlocker = .obdNotReady
        i.simulatedAdapter = true
        i.simulatedSensors = true
        let s = DashboardState.make(i)
        #expect(s.blocker?.offersRecordWithoutOBD == true)
        #expect(s.simulationBadge == "SIMULATED ADAPTER · SIMULATED SENSORS")
        i.simulatedAdapter = false
        #expect(DashboardState.make(i).simulationBadge == "SIMULATED SENSORS")
        i.simulatedSensors = false
        #expect(DashboardState.make(i).simulationBadge == nil)
    }

    @Test("The Record without OBD toggle is offered by the blocker and stays shown while it is on (R5.1-2)")
    func recordWithoutOBDToggle() {
        var i = inputs(link: .idle)
        i.startBlocker = .obdNotReady
        #expect(DashboardState.make(i).showsRecordWithoutOBD)
        // On: the session's blocker clears, the choice must stay visible.
        i.allowsRecordingWithoutOBD = true
        i.startBlocker = nil
        let on = DashboardState.make(i)
        #expect(on.blocker == nil && on.showsRecordWithoutOBD)
        // Off with a polling adapter: nothing to choose.
        let polling = DashboardState.make(inputs())
        #expect(!polling.showsRecordWithoutOBD)
    }
}

@Suite("Start flow")
struct StartFlowTests {
    @Test("Blockers explain themselves; only obdNotReady offers recording without OBD; recordingInProgress is silent")
    func blockers() {
        let disk = StartBlockerNotice(.lowDiskSpace(availableBytes: 120_000_000, requiredBytes: 200_000_000))
        #expect(disk?.offersRecordWithoutOBD == false)
        #expect(disk?.message.contains("120 MB") == true && disk?.message.contains("200 MB") == true)
        #expect(StartBlockerNotice(.obdNotReady)?.offersRecordWithoutOBD == true)
        #expect(StartBlockerNotice(.recordingInProgress) == nil)
        #expect(StartBlockerNotice(nil) == nil)
    }

    @Test("The gate needs both confirmations and no blocker; a blocker is reported first")
    func gate() {
        var checklist = PreDriveChecklist()
        #expect(StartGate.evaluate(checklist: checklist, blocker: nil) == .checklistIncomplete)
        checklist.mountConfirmed = true
        #expect(StartGate.evaluate(checklist: checklist, blocker: nil) == .checklistIncomplete)
        checklist.orientationConfirmed = true
        #expect(StartGate.evaluate(checklist: checklist, blocker: nil).allowsStart)
        let blocker = StartBlockerNotice(.obdNotReady)!
        #expect(StartGate.evaluate(checklist: PreDriveChecklist(), blocker: blocker) == .blocked(blocker))
    }

    @Test("Header notes: the note when given, a statement otherwise")
    func headerNotes() {
        var checklist = PreDriveChecklist()
        #expect(checklist.mountForHeader.contains("confirmed"))
        checklist.mountNote = "  vent clip  "
        checklist.vehicleNote = " Touareg "
        #expect(checklist.mountForHeader == "vent clip")
        #expect(checklist.vehicleForHeader == "Touareg")
    }

    @Test("Only the notes are persisted, not the confirmations")
    @MainActor
    func persistence() throws {
        let suite = "drivelogger.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChecklistStore(defaults: defaults)
        store.save(PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true, mountNote: "m", vehicleNote: "v"))
        let loaded = store.load()
        #expect(loaded.mountNote == "m" && loaded.vehicleNote == "v")
        #expect(!loaded.mountConfirmed && !loaded.orientationConfirmed)
    }

    @Test("Start errors read as sentences")
    func errors() {
        #expect(StartErrorText.message(for: RecordingStartBlocker.obdNotReady).contains("not polling"))
        #expect(StartErrorText.message(for: FakeStartError()).hasPrefix("Could not start"))
    }
}

@Suite("RecordingViewModel", .serialized)
@MainActor
struct RecordingViewModelTests {
    private func makeModel(link: FakeLink, scratch: ScratchStore, defaults: UserDefaults) -> (RecordingViewModel, RecordingSession) {
        let source = FakeSource()
        let session = RecordingFixtures.session(link: link, sources: [source], store: scratch.store)
        let model = RecordingViewModel(
            session: session, link: link, sources: [source], simulatedSensors: false,
            store: ChecklistStore(defaults: defaults)
        )
        return (model, session)
    }

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "drivelogger.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    @Test("Start is refused until both confirmations are ticked; then it records with the notes and resets the confirmations")
    func startFlow() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (d, cleanup) = try defaults()
        defer { cleanup() }
        let (model, session) = makeModel(link: FakeLink(), scratch: scratch, defaults: d)

        await model.start()
        #expect(session.state == .idle)
        #expect(model.gate == .checklistIncomplete)

        model.checklist = PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true, mountNote: "vent clip", vehicleNote: "Touareg")
        #expect(model.gate.allowsStart)
        await model.start()   // returns after the (short) calibration in the real flow; here 5 s
        #expect(session.state == .recording)
        #expect(model.startError == nil)
        #expect(!model.checklist.mountConfirmed)
        #expect(model.checklist.mountNote == "vent clip")

        model.mark("tunnel")
        #expect(model.lastMark == "tunnel")
        model.mark("   ")
        #expect(model.lastMark == "tunnel")
        await session.stop()

        let url = try #require(scratch.files.first)
        let header = try RecordingFixtures.read(url).header
        #expect(header.mount == "vent clip" && header.vehicle == "Touareg")
        #expect(d.string(forKey: ChecklistStore.mountKey) == "vent clip")
    }

    @Test("Without a polling adapter Start is blocked until the explicit choice, and the choice is cleared after the recording starts")
    func recordWithoutOBD() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (d, cleanup) = try defaults()
        defer { cleanup() }
        let link = FakeLink()
        link.state = .idle
        let (model, session) = makeModel(link: link, scratch: scratch, defaults: d)
        model.checklist = PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true)

        #expect(model.dashboard.blocker?.offersRecordWithoutOBD == true)
        #expect(!model.gate.allowsStart)
        await model.start()
        #expect(session.state == .idle)

        model.setRecordWithoutOBD(true)
        #expect(model.gate.allowsStart)
        await model.start()
        #expect(session.state == .recording)
        #expect(session.allowsRecordingWithoutOBD == false)
        await session.stop()
    }
}

@Suite("Console text")
struct ConsoleTextTests {
    @Test("A forbidden command is shown as rejected and not sent")
    func forbidden() {
        let r = ConsoleText.result(for: .forbiddenCommand("ATZ"), command: "ATZ")
        #expect(r.kind == .rejected)
        #expect(r.title == "Rejected: ATZ")
        #expect(r.detail?.contains("Not sent") == true)
        #expect(r.tone == .bad)
    }

    @Test("Desynchronised is its own kind, so the console offers Re-initialise")
    func desynchronised() {
        let r = ConsoleText.result(for: .desynchronised, command: "ATRV")
        #expect(r.kind == .desynchronised)
    }

    @Test("Exchanges: ok and failure outcomes")
    func exchanges() {
        var ex = ELMExchange(seq: 1, phase: .manual, tx: "ATRV", requestUptime: 1, rx: "12.4V", completedUptime: 1.1, outcome: .ok)
        #expect(ConsoleText.result(for: ex).kind == .reply)
        #expect(ConsoleText.result(for: ex).detail == "12.4V")
        ex.outcome = .timeout
        ex.rx = nil
        #expect(ConsoleText.result(for: ex).kind == .failure)
        #expect(ConsoleText.result(for: ex).title == "ATRV → timeout")
    }

    @Test("Quick commands are all accepted by the manual policy")
    func quickCommandsAreAllowed() throws {
        for command in ConsoleText.quickCommands {
            _ = try ELMCommandPolicy.validate(command, scope: .manual)
        }
    }

    @Test("Re-initialise is offered only with a connection")
    func reinitialise() {
        #expect(ConsoleText.canReinitialise(.polling(protocolNumber: "6", voltage: nil)))
        #expect(ConsoleText.canReinitialise(.ready))
        #expect(!ConsoleText.canReinitialise(.failed(reason: "x")), "R5.1-7: reinitialise() does nothing without a connection")
        #expect(!ConsoleText.canReinitialise(.reconnecting(attempt: 2)))
        #expect(!ConsoleText.canReinitialise(.initialising))
        #expect(!ConsoleText.canReinitialise(.idle))
        #expect(!ConsoleText.canReinitialise(.unavailable(reason: "off")))
    }

    @Test("Adapter summary joins what is known")
    func summary() {
        #expect(ConsoleText.adapterSummary(adapter: nil, plan: nil, pollHz: 0) == nil)
        let adapter = AdapterRecord(name: "IOS-Vlink", identifier: "x", elmVersion: "ELM327 v2.3", protocolNumber: "A6")
        #expect(ConsoleText.adapterSummary(adapter: adapter, plan: nil, pollHz: 9.84) == "IOS-Vlink · ELM327 v2.3 · protocol A6 · 9.8 Hz")
    }
}

@Suite("Sessions text")
struct SessionsTextTests {
    @Test("Summary shows duration and size; an unreadable file shows --")
    func summary() {
        let file = RecordingFile(url: URL(fileURLWithPath: "/x/a.jsonl.gz"), name: "a.jsonl.gz", sizeBytes: 42_100_000, startedAt: nil, duration: 1_240)
        #expect(SessionsText.summary(for: file) == "20:40 · 42.1 MB")
        #expect(SessionsText.title(for: file) == "a.jsonl.gz")
        let broken = RecordingFile(url: file.url, name: "a.jsonl.gz", sizeBytes: 10, startedAt: nil, duration: nil)
        #expect(SessionsText.summary(for: broken) == "-- · 10 bytes")
    }

    @Test("Deleting the active recording is explained")
    func deleteErrors() {
        #expect(SessionsText.deleteError(LogStoreError.recordingInProgress(path: "x")).contains("Stop it first"))
    }
}

@Suite("Console link gating (R5.1-1)")
@MainActor
struct ConsoleGatingTests {
    private func make(
        _ recording: RecordingState,
        link state: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4)
    ) -> (ConsoleViewModel, FakeLink) {
        let link = FakeLink()
        link.state = state
        let model = ConsoleViewModel(link: link, recordingState: { recording })
        return (model, link)
    }

    @Test("While recording, Disconnect needs confirmation and only then reaches the link")
    func disconnectWhileRecording() {
        for state in [RecordingState.calibrating, .recording, .stopping] {
            let (model, link) = make(state)
            model.disconnect()
            #expect(link.disconnectCalls == 0)
            #expect(model.pendingChange == .disconnect)
            model.cancelPendingChange()
            #expect(link.disconnectCalls == 0)
            model.disconnect()
            model.confirmPendingChange()
            #expect(link.disconnectCalls == 1)
            #expect(model.pendingChange == nil)
        }
    }

    @Test("The dialog's captured change is performed even after SwiftUI cleared the pending state first (R25.1-1)")
    func confirmCapturedChange() {
        let (model, link) = make(.recording)
        model.disconnect()
        let captured = model.pendingChange
        #expect(captured == .disconnect)
        model.isLinkChangeConfirmationPresented = false   // the setter runs before the button action
        #expect(model.pendingChange == nil)
        model.confirm(.disconnect)
        #expect(link.disconnectCalls == 1)
    }

    @Test("While recording, connecting to a different adapter needs confirmation; the targeted one is harmless")
    func connectWhileRecording() {
        let (model, link) = make(.recording)
        let current = UUID(), other = UUID()
        link.rememberedAdapterID = current

        model.connect(other)
        #expect(link.connectCalls.isEmpty)
        #expect(model.pendingChange == .connect(other))
        model.confirmPendingChange()
        #expect(link.connectCalls == [other])

        model.connect(current)
        #expect(link.connectCalls == [other, current])
        #expect(model.pendingChange == nil)
    }

    @Test("While recording, a different adapter needs confirmation whatever the link state (R5.2-1)")
    func connectWhileRecordingAnyState() {
        let states: [OBDLinkState] = [.unavailable(reason: "Bluetooth is off"), .idle, .scanning, .failed(reason: "x")]
        for state in states {
            let (model, link) = make(.recording, link: state)
            let current = UUID(), stale = UUID()
            link.rememberedAdapterID = current
            model.connect(stale)
            #expect(link.connectCalls.isEmpty, "\(state)")
            #expect(model.pendingChange == .connect(stale))
            model.connect(current)
            #expect(link.connectCalls == [current], "the targeted adapter is harmless")
        }
    }

    @Test("The confirmation says connect when no adapter is held, drop when one is (R48.1-3)")
    func dialogWording() {
        let id = UUID()
        for state in [OBDLinkState.idle, .scanning, .unavailable(reason: "off"), .failed(reason: "x")] {
            let d = ConsoleText.linkChangeDialog(for: .connect(id), link: state, adapterName: "IOS-Vlink")
            #expect(d.title == "Connect to IOS-Vlink?", "\(state)")
            #expect(d.confirm == "Connect" && d.cancel == "Cancel" && !d.confirmIsDestructive)
            #expect(d.message.contains("gains OBD"))
            #expect(!d.title.contains("Drop") && d.cancel != "Keep connection")
        }
        #expect(ConsoleText.linkChangeDialog(for: .connect(id), link: .idle, adapterName: nil).title == "Connect to this adapter?")
        for state in [OBDLinkState.connecting, .initialising, .ready, .polling(protocolNumber: "6", voltage: nil), .reconnecting(attempt: 1)] {
            let d = ConsoleText.linkChangeDialog(for: .connect(id), link: state, adapterName: "x")
            #expect(d.title == "Drop the OBD connection?" && d.confirm == "Drop OBD" && d.cancel == "Keep connection" && d.confirmIsDestructive, "\(state)")
            #expect(d.message == ConsoleText.recordingWarning)
        }
        let disconnect = ConsoleText.linkChangeDialog(for: .disconnect, link: .polling(protocolNumber: "6", voltage: nil), adapterName: nil)
        #expect(disconnect.confirm == "Drop OBD" && disconnect.confirmIsDestructive)
    }

    @Test("forget() reaches the link, also while recording; the confirmation is the view's (R5.2-4)")
    func forgetReachesLink() {
        let (model, link) = make(.recording)
        model.forget()
        #expect(link.forgetCalls == 1)
    }

    @Test("Cancelling a connect leaves the link alone; confirming a stale id after cancel does nothing (R5.2-4)")
    func cancelConnect() {
        let (model, link) = make(.recording, link: .idle)
        model.connect(UUID())
        model.cancelPendingChange()
        model.confirmPendingChange()
        #expect(link.connectCalls.isEmpty && link.disconnectCalls == 0)
    }

    @Test("A recording that has not started, or has ended, never asks (R5.2-4)")
    func notActiveNeverAsks() {
        for state in [RecordingState.idle, .failed(reason: "x", unwrittenEvents: 0)] {
            let (model, link) = make(state, link: .idle)
            model.connect(UUID())
            model.disconnect()
            #expect(model.pendingChange == nil && link.connectCalls.count == 1 && link.disconnectCalls == 1)
        }
    }

    @Test("Scan is refused while recording and while an adapter is held")
    func scanRefused() {
        let (recording, link1) = make(.recording, link: .idle)
        recording.scan()
        #expect(!recording.canScan)
        #expect(link1.startScanCalls == 0)

        for state in [OBDLinkState.connecting, .initialising, .ready, .polling(protocolNumber: "6", voltage: nil), .reconnecting(attempt: 1)] {
            let (model, link) = make(.idle, link: state)
            model.scan()
            #expect(!model.canScan)
            #expect(link.startScanCalls == 0)
        }

        // R5.2-3: `.failed` is where an unusable adapter leaves the user.
        let (failed, link3) = make(.idle, link: .failed(reason: "no usable UART characteristics"))
        failed.scan()
        #expect(failed.canScan)
        #expect(link3.startScanCalls == 1)
        let (failedRecording, link4) = make(.recording, link: .failed(reason: "x"))
        failedRecording.scan()
        #expect(!failedRecording.canScan && link4.startScanCalls == 0)
        let (off, link5) = make(.idle, link: .unavailable(reason: "Bluetooth is off"))
        off.scan()
        #expect(!off.canScan && link5.startScanCalls == 0)

        let (idle, link2) = make(.idle, link: .idle)
        idle.scan()
        #expect(idle.canScan)
        #expect(link2.startScanCalls == 1)
    }

    @Test("When not recording, Disconnect and connect go straight to the link")
    func idleIsDirect() {
        let (model, link) = make(.idle)
        let id = UUID()
        model.disconnect()
        model.connect(id)
        #expect(link.disconnectCalls == 1)
        #expect(link.connectCalls == [id])
        #expect(model.pendingChange == nil)
    }

    @Test("Starting a recording stops a scan that is still running")
    func startStopsScan() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let suite = "drivelogger.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let link = FakeLink()
        link.state = .scanning
        let source = FakeSource()
        let session = RecordingFixtures.session(link: link, sources: [source], store: scratch.store)
        session.allowsRecordingWithoutOBD = true
        let model = RecordingViewModel(
            session: session, link: link, sources: [source], simulatedSensors: false,
            store: ChecklistStore(defaults: d)
        )
        model.checklist.mountConfirmed = true
        model.checklist.orientationConfirmed = true
        await model.start()
        #expect(link.stopScanCalls == 1)
        await session.stop()
    }

    private func makeStartModel(
        _ scratch: ScratchStore, defaults d: UserDefaults, link: FakeLink
    ) -> (RecordingViewModel, RecordingSession) {
        let source = FakeSource()
        let session = RecordingFixtures.session(link: link, sources: [source], store: scratch.store)
        let model = RecordingViewModel(
            session: session, link: link, sources: [source], simulatedSensors: false,
            store: ChecklistStore(defaults: d)
        )
        model.checklist.mountConfirmed = true
        model.checklist.orientationConfirmed = true
        return (model, session)
    }

    @Test("Starting stops a scan that is pending while Bluetooth is off (R5.2-2)")
    func startStopsPendingScan() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let suite = "drivelogger.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let link = FakeLink()
        link.state = .unavailable(reason: "Bluetooth is off")
        let (model, session) = makeStartModel(scratch, defaults: d, link: link)
        session.allowsRecordingWithoutOBD = true
        await model.start()
        #expect(link.stopScanCalls == 1)
        await session.stop()
    }

    @Test("Stop during the keep-still phase frees Start at once; the next Start is not ignored and its checklist is not cleared by the first one (R5.1-3)")
    func restartDuringCalibration() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let suite = "drivelogger.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let (model, session) = makeStartModel(scratch, defaults: d, link: FakeLink())

        let first = Task { await model.start() }   // 5 s calibration
        var turns = 0
        while session.state != .calibrating, turns < 1_000 { try await Task.sleep(for: .milliseconds(10)); turns += 1 }
        #expect(session.state == .calibrating, "the first Start reached calibration")
        #expect(!model.checklist.mountConfirmed, "per-drive confirmations are reset before the wait")
        await session.stop()
        #expect(session.state == .idle)

        model.checklist.mountConfirmed = true
        model.checklist.orientationConfirmed = true
        let second = Task { await model.start() }
        turns = 0
        while session.state != .calibrating, turns < 1_000 { try await Task.sleep(for: .milliseconds(10)); turns += 1 }
        #expect(session.state == .calibrating, "the second Start reached calibration")
        #expect(scratch.files.count == 2, "the re-Start was not ignored")
        // The first start's calibration wait ends here, long before the second's.
        await first.value
        #expect(model.startError == nil)
        await session.stop()
        await second.value
    }

    @Test("A mark after a stop is neither confirmed nor counted, and closes the sheet (R5.1-6)")
    func markWhenNotRecording() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let suite = "drivelogger.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let (model, session) = makeStartModel(scratch, defaults: d, link: FakeLink())

        model.isMarkSheetPresented = true
        model.mark("tunnel")   // idle
        #expect(model.lastMark == nil && model.markCount == 0 && !model.isMarkSheetPresented)

        await model.start()
        #expect(session.state == .recording)
        model.isMarkSheetPresented = true
        model.mark("tunnel")
        #expect(model.lastMark == "tunnel" && model.markCount == 1 && !model.isMarkSheetPresented)
        await session.stop()

        model.isMarkSheetPresented = true
        model.mark("late")
        #expect(model.lastMark == "tunnel" && model.markCount == 1 && !model.isMarkSheetPresented)
        #expect(RecordingViewModel.canMark(.calibrating) && !RecordingViewModel.canMark(.stopping))
    }
}
