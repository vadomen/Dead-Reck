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

@MainActor
@Observable
final class ConsoleViewModel {
    var commandText = ""
    private(set) var result: ManualResult?
    private(set) var isSending = false
    var isForgetConfirmationPresented = false

    @ObservationIgnored private let link: any OBDLinkServicing

    init(services: AppServices) {
        link = services.link
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

    func scan() { link.startScan() }
    func stopScan() { link.stopScan() }
    func connect(_ id: UUID) { link.connect(to: id) }
    func disconnect() { link.disconnect() }
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
