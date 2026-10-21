import DriveLoggerCore
import Foundation
import Observation

/// Result of the last manual command, in words the console can show.
struct ManualResult: Equatable {
    enum Kind: Equatable { case reply, rejected, desynchronised, failure }
    var kind: Kind
    var title: String
    var detail: String?

    var tone: Tone {
        switch kind {
        case .reply: .good
        case .rejected, .failure: .bad
        case .desynchronised: .caution
        }
    }
}

/// Pure helpers for the console.
enum ConsoleText {
    /// Quick buttons: the read-only queries `ELMCommandPolicy` `.manual`
    /// accepts, plus the two PIDs the logger polls.
    static let quickCommands = ["ATI", "AT@1", "ATDP", "ATDPN", "ATRV", "0100", "010D", "010C"]

    static func result(for exchange: ELMExchange) -> ManualResult {
        let rx = exchange.rx?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = (rx?.isEmpty == false) ? rx : nil
        switch exchange.outcome {
        case .ok:
            return ManualResult(kind: .reply, title: "\(exchange.tx) → ok", detail: reply)
        default:
            return ManualResult(kind: .failure, title: "\(exchange.tx) → \(exchange.outcome.rawValue)", detail: reply)
        }
    }

    static func result(for error: ELMSessionError, command: String) -> ManualResult {
        switch error {
        case .forbiddenCommand:
            return ManualResult(
                kind: .rejected,
                title: "Rejected: \(command)",
                detail: "Not sent. The console only allows ATI, AT@1, ATDP, ATDPN, ATRV and mode 01 requests such as 010D."
            )
        case .desynchronised:
            return ManualResult(
                kind: .desynchronised,
                title: "Link out of sync",
                detail: "A reply was lost, so answers cannot be matched to commands. Nothing was sent. Re-initialise the adapter, then retry."
            )
        case .notInitialised:
            return ManualResult(kind: .failure, title: "Adapter not ready", detail: "Connect and wait for polling first.")
        case .cancelled:
            return ManualResult(kind: .failure, title: "Cancelled", detail: "The connection closed while waiting.")
        default:
            return ManualResult(kind: .failure, title: "Failed: \(command)", detail: "\(error)")
        }
    }

    /// One line for the adapter header: version, protocol, poll command and rate.
    static func adapterSummary(adapter: AdapterRecord?, plan: PollingPlan?, pollHz: Double) -> String? {
        var parts: [String] = []
        if let adapter {
            parts.append(adapter.name)
            if let version = adapter.elmVersion { parts.append(version) }
            if let proto = adapter.protocolNumber { parts.append("protocol \(proto)") }
        }
        if let plan { parts.append("poll \(plan.primaryCommand.wireFormat)") }
        if pollHz > 0 { parts.append("\(DisplayFormat.hz(pollHz)) Hz") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Monospaced prefix per direction.
    static func prefix(_ direction: ConsoleLine.Direction) -> String {
        switch direction {
        case .tx: "TX"
        case .rx: "RX"
        case .status: "--"
        }
    }

    /// Re-initialise is offered only on a live connection (R5.1-7): in
    /// `.failed` and `.reconnecting` the service has no connection and
    /// `reinitialise()` does nothing.
    static func canReinitialise(_ state: OBDLinkState) -> Bool {
        switch state {
        case .ready, .polling: true
        case .unavailable, .idle, .scanning, .connecting, .discoveringServices, .initialising,
             .failed, .reconnecting: false
        }
    }
}

/// A link change that, during a recording, ends or replaces the OBD feed
/// and so needs the user's confirmation first.
enum LinkChange: Equatable {
    case disconnect
    case connect(UUID)
}

extension ConsoleText {
    /// Shown whenever a confirmation concerns a recording in progress.
    static let recordingWarning = "The recording continues without OBD for the rest of the drive."

    static func isRecordingActive(_ state: RecordingState) -> Bool {
        switch state {
        case .calibrating, .recording, .stopping: true
        default: false
        }
    }

    /// Connected, initialising, polling or reconnecting: anything that holds
    /// or is acquiring an adapter.
    static func holdsAdapter(_ state: OBDLinkState) -> Bool {
        switch state {
        case .idle, .scanning, .unavailable: false
        default: true
        }
    }

    /// The words of the recording-time confirmation (R48.1-3). Dropping and
    /// connecting are opposite: "Keep connection" must not be the cancel of a
    /// connect the user asked for, so with no adapter held (idle, scanning,
    /// unavailable, failed) a connect says so and the recording gains OBD.
    struct LinkChangeDialog: Equatable {
        var title: String
        var message: String
        var confirm: String
        var cancel: String
        /// Dropping the feed is destructive; adding one is not.
        var confirmIsDestructive: Bool
    }

    /// True when an adapter connection exists or is being made.
    static func holdsConnection(_ state: OBDLinkState) -> Bool {
        switch state {
        case .idle, .scanning, .unavailable, .failed: false
        case .connecting, .discoveringServices, .initialising, .ready, .polling, .reconnecting: true
        }
    }

    static func linkChangeDialog(
        for change: LinkChange?, link: OBDLinkState, adapterName: String?
    ) -> LinkChangeDialog {
        if case .connect = change, !holdsConnection(link) {
            return LinkChangeDialog(
                title: "Connect to \(adapterName ?? "this adapter")?",
                message: "The recording gains OBD from now on. Earlier parts of it stay without.",
                confirm: "Connect", cancel: "Cancel", confirmIsDestructive: false)
        }
        return LinkChangeDialog(
            title: "Drop the OBD connection?", message: recordingWarning,
            confirm: "Drop OBD", cancel: "Keep connection", confirmIsDestructive: true)
    }

    /// The Forget confirmation's message, in Console and in Settings → OBD adapter.
    static func forgetMessage(isRecording: Bool) -> String {
        isRecording
            ? "The app will stop reconnecting to it. \(recordingWarning)"
            : "The app will stop reconnecting to it. You can pick it again from a scan."
    }

    /// Scan only finds an adapter: not while one is held, not while recording.
    /// `.failed` counts as free (R5.2-3): it is where an unusable adapter
    /// ("pick another adapter") leaves the user, so Scan must work there.
    static func canScan(link: OBDLinkState, recording: Bool) -> Bool {
        if case .unavailable = link { return false }
        if case .failed = link { return !recording }
        return !recording && !holdsAdapter(link)
    }
}

/// The adapter actions a screen may offer. Built only by
/// `ConsoleViewModel.linkActions`, so Console and Settings → OBD adapter
/// share one set of guards (recording-time confirmations, scan gating).
struct LinkActions {
    var scan: () -> Void
    var stopScan: () -> Void
    var connect: (UUID) -> Void
    var disconnect: () -> Void
    var forget: () -> Void
    var confirmLinkChange: (LinkChange) -> Void
}

@MainActor
@Observable
final class ConsoleViewModel {
    var commandText = ""
    private(set) var result: ManualResult?
    private(set) var isSending = false
    var isForgetConfirmationPresented = false
    /// Set while a Disconnect / switch-adapter confirmation is on screen.
    var pendingChange: LinkChange?

    @ObservationIgnored private let link: any OBDLinkServicing
    @ObservationIgnored private let recordingState: @MainActor () -> RecordingState

    init(link: any OBDLinkServicing, recordingState: @escaping @MainActor () -> RecordingState) {
        self.link = link
        self.recordingState = recordingState
    }

    convenience init(services: AppServices) {
        let session = services.session
        self.init(link: services.link, recordingState: { session.state })
    }

    var isRecording: Bool { ConsoleText.isRecordingActive(recordingState()) }
    var canScan: Bool { ConsoleText.canScan(link: link.state, recording: isRecording) }
    var isLinkChangeConfirmationPresented: Bool {
        get { pendingChange != nil }
        set { if !newValue { pendingChange = nil } }
    }

    var state: OBDLinkState { link.state }
    /// The adapter the link targets: its initialised record's name, else the
    /// remembered (paired) one's (UX-34). The record is the last initialised
    /// adapter's and outlives Forget and a switch to another adapter
    /// (R68.1-4), so it counts only while it is the paired one.
    var adapterName: String? { currentAdapter?.name ?? link.rememberedAdapterName }
    var status: AdapterStatus { AdapterStatus(link.state) }
    var discovered: [DiscoveredAdapter] { link.discovered }
    var remembered: UUID? { link.rememberedAdapterID }
    var lines: [ConsoleLine] { link.console }
    /// Without the previous adapter's record and plan once another adapter
    /// (or none) is paired (R68.1-4).
    var summary: String? {
        let stale = link.adapter != nil && currentAdapter == nil
        return ConsoleText.adapterSummary(
            adapter: currentAdapter, plan: stale ? nil : link.plan, pollHz: link.pollHz)
    }
    /// `link.adapter` when it is the paired adapter's, else nil.
    private var currentAdapter: AdapterRecord? {
        guard let record = link.adapter, let paired = link.rememberedAdapterID,
              UUID(uuidString: record.identifier) == paired else { return nil }
        return record
    }
    var isSimulated: Bool { link is SimulatedOBDLink }
    /// The demo drive holds the link down (R74.1-6): the adapter screen says so.
    var isHeldForDemo: Bool { (link as? any OBDLinkHolding)?.isHeldForDemo ?? false }
    var canReinitialise: Bool { ConsoleText.canReinitialise(link.state) }
    var canSend: Bool { !isSending && !commandText.trimmingCharacters(in: .whitespaces).isEmpty }

    func scan() {
        guard canScan else { return }
        link.startScan()
    }
    func stopScan() { link.stopScan() }

    /// Tapping an adapter row. The already-targeted adapter is harmless; any
    /// other one during a recording asks first, whatever the link state
    /// (R5.2-1): with Bluetooth unavailable a stale scan row would otherwise
    /// retarget the link silently.
    func connect(_ id: UUID) {
        if isRecording, id != link.rememberedAdapterID {
            pendingChange = .connect(id)
        } else {
            link.connect(to: id)
        }
    }

    func disconnect() {
        if isRecording { pendingChange = .disconnect } else { link.disconnect() }
    }

    func confirmPendingChange() {
        guard let change = pendingChange else { return }
        confirm(change)
    }

    /// Performs `change`, which the dialog captured when it was presented, so
    /// it works whether SwiftUI clears `isLinkChangeConfirmationPresented`
    /// (and with it `pendingChange`) before or after the button action runs.
    func confirm(_ change: LinkChange) {
        pendingChange = nil
        switch change {
        case .disconnect: link.disconnect()
        case .connect(let id): link.connect(to: id)
        }
    }

    func cancelPendingChange() { pendingChange = nil }

    func forget() { link.forget() }

    /// Settings → OBD adapter's Connect: the remembered adapter, through
    /// `connect(_:)` and so through its guard (the targeted adapter never
    /// asks). Nothing remembered: nothing to do.
    func connectRemembered() {
        guard let id = link.rememberedAdapterID else { return }
        connect(id)
    }

    /// The link actions, as both Console and Settings → OBD adapter wire
    /// them: every one goes through this model's guards.
    var linkActions: LinkActions {
        LinkActions(
            scan: scan, stopScan: stopScan, connect: connect, disconnect: disconnect, forget: forget,
            confirmLinkChange: confirm)
    }
    func reinitialise() { Task { await link.reinitialise() } }

    func send(_ command: String? = nil) {
        let text = (command ?? commandText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        Task {
            defer { isSending = false }
            do throws(ELMSessionError) {
                result = ConsoleText.result(for: try await link.sendManual(text))
                if command == nil { commandText = "" }
            } catch {
                result = ConsoleText.result(for: error, command: text)
            }
        }
    }
}
