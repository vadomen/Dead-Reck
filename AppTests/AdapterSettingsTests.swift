import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// UX-34: Settings → OBD adapter. Pure logic only: the state → words mapping,
// the controls, and that every action goes through the Console's guards
// (`ConsoleViewModel`, `ConsoleText`). No hardware: what a real adapter does
// is in docs/PLAN.md §6.

private let allLinkStates: [OBDLinkState] = [
    .unavailable(reason: BLEAvailability.Reason.poweredOff), .idle, .scanning, .connecting, .discoveringServices,
    .initialising, .ready, .polling(protocolNumber: "A6", voltage: 12.4), .reconnecting(attempt: 2),
    .failed(reason: "x"),
]

private let allRecordingStates: [RecordingState] = [
    .idle, .calibrating, .recording, .stopping, .failed(reason: "x", unwrittenEvents: 0),
]

@Suite("Settings → OBD adapter: state and wording (UX-34)")
struct AdapterSettingsTextTests {
    private func status(
        _ link: OBDLinkState, name: String? = "OBDII", remembered: Bool = true,
        found: Bool = false, waitedLong: Bool = false
    ) -> AdapterScreenStatus {
        AdapterSettingsText.status(
            link: link, adapterName: name, hasRemembered: remembered, foundAdapter: found, waitedLong: waitedLong)
    }

    @Test("Bluetooth reasons map to plain words; the reason strings are the BLE layer's own")
    func bluetooth() {
        let off = status(.unavailable(reason: BLEAvailability.Reason.poweredOff))
        #expect(off.phase == .bluetoothOff)
        #expect(off.title == "Bluetooth is off")
        #expect(off.tone == .bad)
        let denied = status(.unavailable(reason: BLEAvailability.Reason.unauthorized))
        #expect(denied.phase == .bluetoothNotAllowed)
        #expect(denied.title == "Bluetooth not allowed")
        #expect(denied.detail?.contains("Privacy & Security → Bluetooth") == true)
        for reason in [BLEAvailability.Reason.unsupported, BLEAvailability.Reason.resetting, BLEAvailability.Reason.unknown, "Bluetooth state 9"] {
            let s = status(.unavailable(reason: reason))
            #expect(s.phase == .bluetoothUnavailable, "\(reason)")
            #expect(s.title == "Bluetooth not available")
            #expect(s.detail == reason)
        }
        // The BLE layer's strings are on disk (`link` rows): frozen.
        #expect(BLEAvailability.Reason.poweredOff == "Bluetooth is off")
        #expect(BLEAvailability.Reason.unauthorized == "Bluetooth permission denied")
    }

    @Test("Connected only while polling; setting up, connecting, lost and failed say so with the name")
    func linkStates() {
        let connected = status(.polling(protocolNumber: "A6", voltage: 12.4))
        #expect(connected.phase == .connected)
        #expect(connected.title == "Connected")
        #expect(connected.detail == "OBDII · reading the car")
        #expect(connected.tone == .good)

        for state in [OBDLinkState.connecting, .discoveringServices] {
            #expect(status(state).phase == .connecting)
            #expect(status(state).title == "Connecting to OBDII")
            #expect(status(state).tone == .caution)
        }
        for state in [OBDLinkState.initialising, .ready] {
            #expect(status(state).phase == .settingUp)
            #expect(status(state).title == "Setting up OBDII")
        }
        let lost = status(.reconnecting(attempt: 3))
        #expect(lost.phase == .reconnecting)
        #expect(lost.title == "Adapter lost")
        #expect(lost.detail == "Reconnecting to OBDII")
        #expect(lost.tone == .bad)

        let failed = status(.failed(reason: "no usable UART characteristics"))
        #expect(failed.phase == .failed)
        #expect(failed.title == "Connection failed")
        #expect(failed.detail == "no usable UART characteristics")
        #expect(failed.tone == .bad)
    }

    @Test("Without a name the screen says 'your adapter'")
    func noName() {
        #expect(status(.connecting, name: nil).title == "Connecting to your adapter")
        #expect(status(.polling(protocolNumber: "6", voltage: nil), name: nil).detail == "reading the car")
    }

    @Test("Idle: no adapter chosen vs. disconnected from the paired one")
    func idle() {
        let none = status(.idle, name: nil, remembered: false)
        #expect(none.phase == .noAdapter)
        #expect(none.title == "No adapter chosen")
        #expect(none.showsHelp)
        let off = status(.idle)
        #expect(off.phase == .notConnected)
        #expect(off.title == "Not connected")
        #expect(!off.showsHelp)
    }

    @Test("Searching becomes not found after a long wait with no adapter-like name; a found one stays searching")
    func searchingAndNotFound() {
        #expect(status(.scanning).phase == .searching)
        #expect(status(.scanning).title == "Searching for adapters")
        #expect(!status(.scanning).showsHelp)
        let notFound = status(.scanning, waitedLong: true)
        #expect(notFound.phase == .notFound)
        #expect(notFound.title == "No adapter found")
        #expect(notFound.showsHelp)
        #expect(status(.scanning, found: true, waitedLong: true).phase == .searching)
    }

    @Test("Connecting or reconnecting for a long time means the adapter is not around: not found, with help")
    func waitingForAdapter() {
        for state in [OBDLinkState.connecting, .reconnecting(attempt: 4)] {
            let s = status(state, waitedLong: true)
            #expect(s.phase == .notFound, "\(state)")
            #expect(s.title == "OBDII not found")
            #expect(s.showsHelp)
        }
        // In range and talking: never "not found", however long it takes.
        for state in [OBDLinkState.discoveringServices, .initialising, .ready, .polling(protocolNumber: "6", voltage: nil)] {
            #expect(status(state, waitedLong: true).phase != .notFound, "\(state)")
        }
    }

    @Test("Help is short and names the BLE adapter's real causes")
    func help() {
        let help = AdapterSettingsText.help
        #expect(help.count <= 5)
        #expect(help.contains { $0.contains("OBD port") })
        #expect(help.contains { $0.contains("ignition") })
        #expect(help.contains { $0.contains("Bluetooth") })
        #expect(help.contains { $0.contains("iOS Settings") }, "a BLE adapter is not paired in iOS Settings")
        for line in help { #expect(line.count < 90, "\(line)") }
    }

    @Test("Every phase has a symbol; failed ones are slashed or warning glyphs")
    func symbols() {
        for state in allLinkStates {
            #expect(!status(state).symbol.isEmpty)
        }
        #expect(status(.unavailable(reason: BLEAvailability.Reason.poweredOff)).symbol.contains("slash"))
    }

    @Test("The waiting timer restarts with each phase key; only scanning and connecting wait")
    func waitKey() {
        #expect(AdapterSettingsText.waitKey(.scanning) == "scanning")
        #expect(AdapterSettingsText.waitKey(.connecting) == "connecting")
        #expect(AdapterSettingsText.waitKey(.reconnecting(attempt: 1)) == "connecting")
        #expect(AdapterSettingsText.waitKey(.reconnecting(attempt: 5)) == "connecting", "backoff attempts don't restart it")
        #expect(AdapterSettingsText.waitKey(.idle) == nil)
        #expect(AdapterSettingsText.waitKey(.polling(protocolNumber: "6", voltage: nil)) == nil)
    }
}

@Suite("Settings → OBD adapter: controls (UX-34)")
struct AdapterSettingsControlsTests {
    @Test("Scan gating is exactly the Console's, for every link and recording state")
    func scanMatchesConsole() {
        for link in allLinkStates {
            for recording in allRecordingStates {
                let active = ConsoleText.isRecordingActive(recording)
                let c = AdapterSettingsText.controls(link: link, recording: active, remembered: UUID())
                #expect(c.canScan == ConsoleText.canScan(link: link, recording: active), "\(link) \(recording)")
                #expect(c.isScanning == (link == .scanning))
            }
        }
    }

    @Test("Disconnect is enabled exactly when the Console enables it (an adapter is held)")
    func disconnectMatchesConsole() {
        for link in allLinkStates {
            let c = AdapterSettingsText.controls(link: link, recording: false, remembered: UUID())
            #expect(c.canDisconnect == ConsoleText.holdsAdapter(link), "\(link)")
        }
    }

    @Test("Connect needs a paired adapter, Bluetooth, and no connection held; Forget needs a paired adapter")
    func connectAndForget() {
        let id = UUID()
        #expect(AdapterSettingsText.controls(link: .idle, recording: false, remembered: id).canConnect)
        #expect(AdapterSettingsText.controls(link: .failed(reason: "x"), recording: true, remembered: id).canConnect)
        #expect(AdapterSettingsText.controls(link: .scanning, recording: false, remembered: id).canConnect)
        #expect(!AdapterSettingsText.controls(link: .idle, recording: false, remembered: nil).canConnect)
        #expect(!AdapterSettingsText.controls(link: .unavailable(reason: "off"), recording: false, remembered: id).canConnect)
        for held in [OBDLinkState.connecting, .initialising, .ready, .polling(protocolNumber: "6", voltage: nil), .reconnecting(attempt: 1)] {
            #expect(!AdapterSettingsText.controls(link: held, recording: false, remembered: id).canConnect, "\(held)")
        }
        #expect(AdapterSettingsText.controls(link: .idle, recording: false, remembered: id).canForget)
        #expect(!AdapterSettingsText.controls(link: .idle, recording: false, remembered: nil).canForget)
    }

    @Test("Why Scan is off: recording, an adapter held, or Bluetooth; nothing when it is on")
    func scanFootnote() {
        #expect(AdapterSettingsText.scanNote(link: .idle, recording: false) == nil)
        #expect(AdapterSettingsText.scanNote(link: .idle, recording: true) == "Scanning is off while recording.")
        #expect(AdapterSettingsText.scanNote(link: .polling(protocolNumber: "6", voltage: nil), recording: false)
            == "Disconnect first to look for another adapter.")
        #expect(AdapterSettingsText.scanNote(link: .unavailable(reason: "off"), recording: false) == "Needs Bluetooth.")
        #expect(AdapterSettingsText.scanNote(link: .scanning, recording: false) == nil)
        // Never a note while Scan is enabled.
        for link in allLinkStates {
            for recording in [false, true] where ConsoleText.canScan(link: link, recording: recording) {
                #expect(AdapterSettingsText.scanNote(link: link, recording: recording) == nil, "\(link)")
            }
        }
    }
}

@Suite("Settings → OBD adapter goes through the Console's guards (UX-34)")
@MainActor
struct AdapterSettingsGuardTests {
    private func make(
        _ recording: RecordingState, link state: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4)
    ) -> (ConsoleViewModel, FakeLink) {
        let link = FakeLink()
        link.state = state
        return (ConsoleViewModel(link: link, recordingState: { recording }), link)
    }

    /// What a sequence of taps did to the link and the model.
    private struct Outcome: Equatable {
        var pending: LinkChange?
        var connects: [UUID]
        var disconnects: Int
        var forgets: Int
        var scans: Int
    }

    private func outcome(_ model: ConsoleViewModel, _ link: FakeLink) -> Outcome {
        Outcome(pending: model.pendingChange, connects: link.connectCalls, disconnects: link.disconnectCalls,
                forgets: link.forgetCalls, scans: link.startScanCalls)
    }

    @Test("The same taps through Settings and through Console give the same link calls and confirmations")
    func sameAsConsole() {
        let current = UUID(), other = UUID()
        for recording in allRecordingStates {
            for state in allLinkStates {
                let taps: [(LinkActions) -> Void] = [
                    { $0.scan() }, { $0.disconnect() }, { $0.connect(other) }, { $0.connect(current) }, { $0.forget() },
                ]
                for tap in taps {
                    let (consoleModel, consoleLink) = make(recording, link: state)
                    let (settingsModel, settingsLink) = make(recording, link: state)
                    consoleLink.rememberedAdapterID = current
                    settingsLink.rememberedAdapterID = current
                    // Console: the model's own methods, as `ConsoleScreen` wires them.
                    let console = ConsoleActions.make(consoleModel)
                    tap(LinkActions(scan: console.scan, stopScan: console.stopScan, connect: console.connect,
                                    disconnect: console.disconnect, forget: console.forget,
                                    confirmLinkChange: console.confirmLinkChange))
                    // Settings → OBD adapter.
                    tap(AdapterSettingsScreen.actions(settingsModel))
                    #expect(outcome(consoleModel, consoleLink) == outcome(settingsModel, settingsLink), "\(recording) \(state)")
                }
            }
        }
    }

    @Test("While recording, Disconnect from Settings asks first and only the confirmation reaches the link")
    func disconnectAsks() {
        let (model, link) = make(.recording)
        let actions = AdapterSettingsScreen.actions(model)
        actions.disconnect()
        #expect(link.disconnectCalls == 0)
        #expect(model.pendingChange == .disconnect)
        let dialog = ConsoleText.linkChangeDialog(for: model.pendingChange, link: link.state, adapterName: nil)
        #expect(dialog.confirm == "Drop OBD" && dialog.confirmIsDestructive)
        actions.confirmLinkChange(.disconnect)
        #expect(link.disconnectCalls == 1 && model.pendingChange == nil)
    }

    @Test("Connect from Settings targets the paired adapter: harmless while recording, like Console's row")
    func connectRemembered() {
        let (model, link) = make(.recording, link: .idle)
        let id = UUID()
        link.rememberedAdapterID = id
        model.connectRemembered()
        #expect(link.connectCalls == [id])
        #expect(model.pendingChange == nil)

        let (none, link2) = make(.idle, link: .idle)
        none.connectRemembered()
        #expect(link2.connectCalls.isEmpty, "nothing paired: nothing to connect")
    }

    @Test("Scan from Settings is refused while recording and while an adapter is held")
    func scanRefused() {
        let (recording, link1) = make(.recording, link: .idle)
        AdapterSettingsScreen.actions(recording).scan()
        #expect(link1.startScanCalls == 0)
        let (held, link2) = make(.idle)
        AdapterSettingsScreen.actions(held).scan()
        #expect(link2.startScanCalls == 0)
        let (free, link3) = make(.idle, link: .idle)
        AdapterSettingsScreen.actions(free).scan()
        #expect(link3.startScanCalls == 1)
    }

    @Test("The forget confirmation says the same in both screens")
    func forgetWording() {
        #expect(ConsoleText.forgetMessage(isRecording: false)
            == "The app will stop reconnecting to it. You can pick it again from a scan.")
        #expect(ConsoleText.forgetMessage(isRecording: true)
            == "The app will stop reconnecting to it. \(ConsoleText.recordingWarning)")
    }

    @Test("The name shown is the paired adapter's record's, else the remembered name; another adapter's record is ignored")
    func name() {
        let (model, link) = make(.idle, link: .idle)
        let paired = UUID()
        link.adapter = nil
        link.rememberedAdapterID = paired
        link.rememberedAdapterName = "OBDII"
        #expect(model.adapterName == "OBDII")
        link.adapter = AdapterRecord(name: "Other", identifier: paired.uuidString)
        #expect(model.adapterName == "Other", "the paired adapter's record, e.g. a name learnt on connecting")
        link.adapter = AdapterRecord(name: "Other", identifier: paired.uuidString.lowercased())
        #expect(model.adapterName == "Other", "identifiers compare as UUIDs, not strings")
        link.adapter = AdapterRecord(name: "Stale", identifier: UUID().uuidString)
        #expect(model.adapterName == "OBDII", "R68.1-4: a record of another adapter is not the paired one's")
        link.rememberedAdapterName = nil
        #expect(model.adapterName == nil)
        link.adapter = nil
        #expect(model.adapterName == nil)
    }
}

/// R68.1-4: the link keeps the last initialised adapter's record
/// (`OBDLinkServicing.adapter`) through Forget and a switch to another
/// adapter. Settings → OBD adapter and the Console header name the adapter
/// the link targets, never that record's.
@Suite("Settings → OBD adapter and Console name the targeted adapter (R68.1-4)")
@MainActor
struct AdapterNameTargetTests {
    private let idA = UUID(), idB = UUID()

    private func settingsTitle(_ model: ConsoleViewModel, waitedLong: Bool = false) -> String {
        AdapterSettingsText.status(
            link: model.state, adapterName: model.adapterName, hasRemembered: model.remembered != nil,
            foundAdapter: false, waitedLong: waitedLong
        ).title
    }

    /// Polling on A: A's record, A paired.
    private func pollingOnA() -> (ConsoleViewModel, FakeLink) {
        let link = FakeLink()
        link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        link.adapter = AdapterRecord(name: "Adapter A", identifier: idA.uuidString, elmVersion: "ELM327 v2.3",
                                     protocolNumber: "A6")
        link.rememberedAdapterID = idA
        link.rememberedAdapterName = "Adapter A"
        link.pollHz = 16.4
        return (ConsoleViewModel(link: link, recordingState: { .idle }), link)
    }

    /// What `OBDLinkService.forget()` leaves: idle, nothing paired, the
    /// record kept.
    private func forget(_ link: FakeLink) {
        link.state = .idle
        link.rememberedAdapterID = nil
        link.rememberedAdapterName = nil
        link.pollHz = 0
    }

    @Test("Polling on A: both screens name A")
    func pollingNamesA() {
        let (model, _) = pollingOnA()
        #expect(model.adapterName == "Adapter A")
        #expect(AdapterSettingsText.status(
            link: model.state, adapterName: model.adapterName, hasRemembered: true, foundAdapter: false,
            waitedLong: false).detail == "Adapter A · reading the car")
        #expect(model.summary?.hasPrefix("Adapter A · ELM327 v2.3 · protocol A6") == true)
    }

    @Test("Forget A with nothing targeted: Settings says no adapter chosen, Console's header drops A")
    func forgetShowsNoA() {
        let (model, link) = pollingOnA()
        forget(link)
        #expect(link.adapter?.name == "Adapter A", "the link still holds A's record")
        #expect(model.adapterName == nil)
        #expect(settingsTitle(model) == "No adapter chosen")
        #expect(model.summary == nil, "no A, no A's poll plan")
        // Even a connecting state with nothing paired never says A.
        link.state = .connecting
        #expect(settingsTitle(model) == "Connecting to your adapter")
        #expect(settingsTitle(model, waitedLong: true) == "Adapter not found")
    }

    @Test("Forget A, tap B: Settings and Console name B while B connects, and when B is never found")
    func forgetThenTapB() {
        let (model, link) = pollingOnA()
        forget(link)
        // `connect(to: B)` from a scan row: B paired with its scan name.
        model.connect(idB)
        #expect(link.connectCalls == [idB])
        link.rememberedAdapterID = idB
        link.rememberedAdapterName = "Adapter B"
        link.state = .connecting
        #expect(model.adapterName == "Adapter B")
        #expect(settingsTitle(model) == "Connecting to Adapter B")
        #expect(settingsTitle(model, waitedLong: true) == "Adapter B not found")
        #expect(model.summary?.contains("Adapter A") != true)
        #expect(model.summary?.contains("010D") != true, "A's poll plan is not B's")
        link.state = .initialising
        #expect(settingsTitle(model) == "Setting up Adapter B")

        // B initialises: its own record replaces A's.
        link.adapter = AdapterRecord(name: "Adapter B", identifier: idB.uuidString, elmVersion: "ELM327 v1.5")
        link.state = .polling(protocolNumber: "6", voltage: nil)
        #expect(model.summary?.hasPrefix("Adapter B · ELM327 v1.5") == true)
    }

    @Test("Tap B without a scan row (name not known yet): 'your adapter', never A")
    func retargetWithoutName() {
        let (model, link) = pollingOnA()
        link.rememberedAdapterID = idB
        link.rememberedAdapterName = nil
        link.state = .connecting
        #expect(model.adapterName == nil)
        #expect(settingsTitle(model) == "Connecting to your adapter")
        #expect(model.summary?.contains("Adapter A") != true)
    }

    @Test("Disconnect keeps A paired: both screens still name A, and a reconnect to A says A")
    func disconnectKeepsA() {
        let (model, link) = pollingOnA()
        link.state = .idle
        link.pollHz = 0
        #expect(model.adapterName == "Adapter A")
        #expect(settingsTitle(model) == "Not connected")
        #expect(model.summary?.hasPrefix("Adapter A") == true)
        link.state = .reconnecting(attempt: 1)
        #expect(AdapterSettingsText.status(
            link: model.state, adapterName: model.adapterName, hasRemembered: true, foundAdapter: false,
            waitedLong: false).detail == "Reconnecting to Adapter A")
    }
}

/// R68.1-4 through the real `OBDLinkService` (a fake BLE central): the
/// service's record of A survives Forget and the switch to B; the screens
/// still name B.
@Suite("Settings → OBD adapter and Console name the targeted adapter: OBDLinkService (R68.1-4)",
       .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AdapterNameServiceTests {
    @Test("Poll on A, Forget, scan, tap B that never finishes connecting: B is named, A is not")
    func forgetThenTapB() async throws {
        // Connection 0 (A) polls; connection 1 (B) stalls before GATT discovery.
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()], stalledDiscoveries: [1])
        let link = LinkTestSupport.service(central, discoveryTimeout: .seconds(30))
        let model = ConsoleViewModel(link: link, recordingState: { .idle })
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })
        #expect(model.adapterName == "IOS-Vlink")
        #expect(model.summary?.hasPrefix("IOS-Vlink") == true)

        link.forget()
        #expect(link.adapter?.name == "IOS-Vlink", "the service keeps A's record (it goes into log rows)")
        #expect(model.adapterName == nil)
        #expect(model.summary?.contains("IOS-Vlink") != true)
        #expect(AdapterSettingsText.status(
            link: model.state, adapterName: model.adapterName, hasRemembered: model.remembered != nil,
            foundAdapter: false, waitedLong: false).title == "No adapter chosen")

        let idB = UUID()
        link.startScan()
        central.send(.discovered(DiscoveredAdapter(id: idB, name: "Adapter B", rssi: -50)))
        #expect(await eventually { link.discovered.contains { $0.id == idB } })
        model.connect(idB)
        #expect(await eventually { central.calls.filter { $0 == "connect" }.count == 2 })
        #expect(link.rememberedAdapterID == idB)
        for waitedLong in [false, true] {
            let title = AdapterSettingsText.status(
                link: model.state, adapterName: model.adapterName, hasRemembered: model.remembered != nil,
                foundAdapter: false, waitedLong: waitedLong
            ).title
            // Discovering never becomes "not found"; connecting does after a long wait.
            #expect(["Connecting to Adapter B", "Adapter B not found"].contains(title), "\(model.state) \(title)")
        }
        #expect(model.adapterName == "Adapter B")
        #expect(model.summary?.contains("IOS-Vlink") != true)
        link.disconnect()
    }
}

@Suite("Settings → OBD adapter: DEBUG fakes")
struct AdapterFakeTests {
    @Test("-uiFakeAdapter values parse to plain inputs with a generic name; unknown or missing is nil")
    func parse() {
        let connected = AdapterFake.parse("connected")
        #expect(connected?.link == .polling(protocolNumber: "6", voltage: 12.4))
        #expect(connected?.name == "OBDII")
        #expect(connected?.hasRemembered == true)
        let notFound = AdapterFake.parse("notfound")
        #expect(notFound?.link == .scanning)
        #expect(notFound?.waitedLong == true)
        #expect(notFound?.hasRemembered == false)
        #expect(notFound?.discovered.allSatisfy { !OBDLinkService.isLikelyAdapter($0) } == true)
        #expect(AdapterFake.parse("bluetoothOff")?.link == .unavailable(reason: BLEAvailability.Reason.poweredOff))
        #expect(AdapterFake.parse("bogus") == nil)
        #expect(AdapterFake.parse(nil) == nil)
        #expect(AdapterFake.parse("") == nil)
        // The fake screens read as the states they are named after.
        #expect(connected.map { AdapterSettingsText.status(for: $0).phase } == .connected)
        #expect(notFound.map { AdapterSettingsText.status(for: $0).phase } == .notFound)
    }
}
