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

    /// Re-initialise can be pressed unless an init is visibly running or
    /// there is no connection to re-initialise.
    static func canReinitialise(_ state: OBDLinkState) -> Bool {
        switch state {
        case .ready, .polling, .failed, .reconnecting: true
        case .unavailable, .idle, .scanning, .connecting, .discoveringServices, .initialising: false
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

    /// Scan only finds an adapter: not while one is held, not while recording.
    static func canScan(link: OBDLinkState, recording: Bool) -> Bool {
        if case .unavailable = link { return false }
        return !recording && !holdsAdapter(link)
    }
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
    var status: AdapterStatus { AdapterStatus(link.state) }
    var discovered: [DiscoveredAdapter] { link.discovered }
    var remembered: UUID? { link.rememberedAdapterID }
    var lines: [ConsoleLine] { link.console }
    var summary: String? { ConsoleText.adapterSummary(adapter: link.adapter, plan: link.plan, pollHz: link.pollHz) }
    var isSimulated: Bool { link is SimulatedOBDLink }
    var canReinitialise: Bool { ConsoleText.canReinitialise(link.state) }
    var canSend: Bool { !isSending && !commandText.trimmingCharacters(in: .whitespaces).isEmpty }

    func scan() {
        guard canScan else { return }
        link.startScan()
    }
    func stopScan() { link.stopScan() }

    /// Tapping an adapter row. The already-targeted adapter is harmless; any
    /// other one, while an adapter is held during a recording, asks first.
    func connect(_ id: UUID) {
        if isRecording, ConsoleText.holdsAdapter(link.state), id != link.rememberedAdapterID {
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
        pendingChange = nil
        switch change {
        case .disconnect: link.disconnect()
        case .connect(let id): link.connect(to: id)
        }
    }

    func cancelPendingChange() { pendingChange = nil }

    func forget() { link.forget() }
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
