import Foundation

/// The adapter line shown on the dashboard and the console.
struct AdapterStatus: Hashable, Sendable {
    var title: String
    var detail: String?
    var tone: Tone
    var isPolling: Bool

    init(_ state: OBDLinkState) {
        switch state {
        case .unavailable(let reason):
            title = "Bluetooth unavailable"
            detail = reason
            tone = .bad
            isPolling = false
        case .idle:
            title = "Adapter not connected"
            detail = "Pick one in Console"
            tone = .bad
            isPolling = false
        case .scanning:
            title = "Scanning for adapter"
            detail = nil
            tone = .caution
            isPolling = false
        case .connecting:
            title = "Connecting"
            detail = nil
            tone = .caution
            isPolling = false
        case .discoveringServices:
            title = "Connecting"
            detail = "discovering services"
            tone = .caution
            isPolling = false
        case .initialising:
            title = "Initialising adapter"
            detail = nil
            tone = .caution
            isPolling = false
        case .ready:
            title = "Adapter ready"
            detail = "not polling yet"
            tone = .caution
            isPolling = false
        case .polling(let proto, let voltage):
            title = "Polling OBD"
            detail = (["protocol \(proto)"] + [DisplayFormat.voltage(voltage)].compactMap { $0 })
                .joined(separator: " · ")
            tone = .good
            isPolling = true
        case .reconnecting(let attempt):
            title = "Adapter lost"
            detail = "reconnecting, attempt \(attempt)"
            tone = .bad
            isPolling = false
        case .failed(let reason):
            title = "Adapter failed"
            detail = reason
            tone = .bad
            isPolling = false
        }
    }
}
