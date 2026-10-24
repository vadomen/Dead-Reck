import Foundation

/// The Bluetooth availability reasons are on-disk text in the log's link rows
/// (`BLEAvailability.Reason`: never reworded there), so the screens translate
/// the known ones here, by comparing with the same constants. The link
/// services' failure texts are read back as a typed `LinkReason` and shown
/// as its `display`. Any other reason (an `ELMSession` failure from Core,
/// an iOS error text) is shown as the service wrote it.
enum LinkReasonText {
    static func display(_ reason: String) -> String {
        switch reason {
        case BLEAvailability.Reason.poweredOff: String(localized: "Bluetooth is off")
        case BLEAvailability.Reason.unauthorized: String(localized: "Bluetooth permission denied")
        case BLEAvailability.Reason.unsupported: String(localized: "Bluetooth LE is not supported on this device")
        case BLEAvailability.Reason.resetting: String(localized: "Bluetooth is resetting")
        case BLEAvailability.Reason.unknown: String(localized: "Bluetooth state unknown")
        default: LinkReason(text: reason)?.display ?? reason
        }
    }
}

/// The adapter line shown on the dashboard and the console.
struct AdapterStatus: Hashable, Sendable {
    var title: String
    var detail: String?
    var tone: Tone
    var isPolling: Bool

    init(_ state: OBDLinkState) {
        switch state {
        case .unavailable(let reason):
            title = String(localized: "Bluetooth unavailable")
            detail = LinkReasonText.display(reason)
            tone = .bad
            isPolling = false
        case .idle:
            title = String(localized: "Adapter not connected")
            detail = String(localized: "Pick one in Settings → OBD adapter")
            tone = .bad
            isPolling = false
        case .scanning:
            title = String(localized: "Scanning for adapter")
            detail = nil
            tone = .caution
            isPolling = false
        case .connecting:
            title = String(localized: "Connecting")
            detail = nil
            tone = .caution
            isPolling = false
        case .discoveringServices:
            title = String(localized: "Connecting")
            detail = String(localized: "discovering services")
            tone = .caution
            isPolling = false
        case .initialising:
            title = String(localized: "Initialising adapter")
            detail = nil
            tone = .caution
            isPolling = false
        case .ready:
            title = String(localized: "Adapter ready")
            detail = String(localized: "not polling yet")
            tone = .caution
            isPolling = false
        case .polling(let proto, let voltage):
            title = String(localized: "Polling OBD")
            if let volts = DisplayFormat.voltage(voltage) {
                detail = String(localized: "protocol \(proto) · \(volts)")
            } else {
                detail = String(localized: "protocol \(proto)")
            }
            tone = .good
            isPolling = true
        case .reconnecting(let attempt):
            title = String(localized: "Adapter lost")
            detail = String(localized: "reconnecting, attempt \(attempt)")
            tone = .bad
            isPolling = false
        case .failed(let reason):
            title = String(localized: "Adapter failed")
            detail = LinkReasonText.display(reason)
            tone = .bad
            isPolling = false
        }
    }
}
