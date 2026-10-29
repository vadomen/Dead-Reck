import Foundation

// Settings → OBD adapter (UX-34): the driver's view of the link. Pure
// decisions only (`AdapterSettingsTests`); the view is
// `AdapterSettingsView.swift`. Every action goes through `ConsoleViewModel`
// and its guards; nothing here talks to the link.

/// What the screen says the link is doing.
enum AdapterPhase: Hashable, Sendable {
    case bluetoothOff
    case bluetoothNotAllowed
    /// Unsupported, resetting or unknown.
    case bluetoothUnavailable
    /// Idle, nothing remembered.
    case noAdapter
    /// Idle with a remembered adapter (after Disconnect).
    case notConnected
    case searching
    /// A scan that has found nothing adapter-like for a while, or a connect
    /// that has waited a while: the adapter is not in range (iOS keeps a
    /// connect pending until the peripheral appears).
    case notFound
    case connecting
    /// Connected over BLE; the ELM327 is being initialised.
    case settingUp
    case connected
    case reconnecting
    case failed
}

struct AdapterScreenStatus: Equatable, Sendable {
    var phase: AdapterPhase
    var title: String
    var detail: String?
    var tone: Tone
    /// SF Symbol; failed states use a slashed or warning glyph, so the state
    /// never rests on colour alone.
    var symbol: String
    /// Show the "if your adapter isn't found" help.
    var showsHelp: Bool

    /// Bluetooth is denied for the app: only iOS Settings can change it, so the screen
    /// offers a button to the app's page there (prompt 42 QA). Not for "Bluetooth is off"
    /// (Control Centre) or an unsupported device.
    var offersAppSettings: Bool { phase == .bluetoothNotAllowed }
}

/// The enablement of the screen's controls. Scan and Disconnect follow
/// exactly the Console's rules (`ConsoleText.canScan`, `holdsAdapter`).
struct AdapterControls: Equatable, Sendable {
    var isScanning: Bool
    var canScan: Bool
    var canConnect: Bool
    var canDisconnect: Bool
    var canForget: Bool
}

enum AdapterSettingsText {
    /// After this long scanning without an adapter-like name, or waiting on a
    /// connect, the screen says "not found" and shows the help.
    static let longWait: Duration = .seconds(15)

    /// Short, and true for a BLE ELM327 (Vgate iCar Pro class): it is not
    /// paired in iOS Settings, and it talks to one app at a time.
    static let help: [String] = [
        String(localized: "Plug the adapter into the car's OBD port, under the dashboard."),
        String(localized: "Switch the ignition on."),
        String(localized: "Keep Bluetooth on."),
        String(localized: "Don't pair it in iOS Settings: pick it here after a scan."),
        String(localized: "Close other OBD apps: the adapter talks to one app at a time."),
    ]

    static func phase(link: OBDLinkState, hasRemembered: Bool, foundAdapter: Bool, waitedLong: Bool) -> AdapterPhase {
        switch link {
        case .unavailable(let reason):
            switch reason {
            case BLEAvailability.Reason.poweredOff: return .bluetoothOff
            case BLEAvailability.Reason.unauthorized: return .bluetoothNotAllowed
            default: return .bluetoothUnavailable
            }
        case .idle: return hasRemembered ? .notConnected : .noAdapter
        case .scanning: return waitedLong && !foundAdapter ? .notFound : .searching
        case .connecting: return waitedLong ? .notFound : .connecting
        case .reconnecting: return waitedLong ? .notFound : .reconnecting
        case .discoveringServices: return .connecting
        case .initialising, .ready: return .settingUp
        case .polling: return .connected
        case .failed: return .failed
        }
    }

    static func status(
        link: OBDLinkState, adapterName: String?, hasRemembered: Bool, foundAdapter: Bool, waitedLong: Bool
    ) -> AdapterScreenStatus {
        let phase = phase(link: link, hasRemembered: hasRemembered, foundAdapter: foundAdapter, waitedLong: waitedLong)
        let reason: String? = switch link {
        case .unavailable(let r), .failed(let r): r
        default: nil
        }
        switch phase {
        case .bluetoothOff:
            return .init(phase: phase, title: String(localized: "Bluetooth is off"),
                         detail: String(localized: "Turn it on in Control Centre or iOS Settings."),
                         tone: .bad, symbol: "antenna.radiowaves.left.and.right.slash", showsHelp: false)
        case .bluetoothNotAllowed:
            return .init(phase: phase, title: String(localized: "Bluetooth not allowed"),
                         detail: String(localized: "Allow it for this app in iOS Settings → Privacy & Security → Bluetooth."),
                         tone: .bad, symbol: "antenna.radiowaves.left.and.right.slash", showsHelp: false)
        case .bluetoothUnavailable:
            return .init(phase: phase, title: String(localized: "Bluetooth not available"), detail: reason.map(LinkReasonText.display),
                         tone: .bad, symbol: "antenna.radiowaves.left.and.right.slash", showsHelp: false)
        case .noAdapter:
            return .init(phase: phase, title: String(localized: "No adapter chosen"), detail: String(localized: "Scan to find your OBD adapter."),
                         tone: .neutral, symbol: "magnifyingglass", showsHelp: true)
        case .notConnected:
            return .init(phase: phase, title: String(localized: "Not connected"),
                         detail: adapterName.map { String(localized: "Connect to use \($0) again.") }
                             ?? String(localized: "Connect to use your adapter again."),
                         tone: .neutral, symbol: "bolt.horizontal", showsHelp: false)
        case .searching:
            return .init(phase: phase, title: String(localized: "Searching for adapters"),
                         detail: String(localized: "Tap your adapter when it appears."),
                         tone: .caution, symbol: "antenna.radiowaves.left.and.right", showsHelp: false)
        case .notFound:
            if case .scanning = link {
                return .init(phase: phase, title: String(localized: "No adapter found"),
                             detail: String(localized: "Still searching. Yours may have another name: check the list."),
                             tone: .bad, symbol: "exclamationmark.triangle", showsHelp: true)
            }
            return .init(phase: phase, title: adapterName.map { String(localized: "\($0) not found") } ?? String(localized: "Adapter not found"),
                         detail: String(localized: "Still waiting. It connects as soon as it is in range."),
                         tone: .bad, symbol: "exclamationmark.triangle", showsHelp: true)
        case .connecting:
            return .init(phase: phase, title: adapterName.map { String(localized: "Connecting to \($0)") } ?? String(localized: "Connecting to your adapter"),
                         detail: nil,
                         tone: .caution, symbol: "antenna.radiowaves.left.and.right", showsHelp: false)
        case .settingUp:
            return .init(phase: phase, title: adapterName.map { String(localized: "Setting up \($0)") } ?? String(localized: "Setting up your adapter"),
                         detail: String(localized: "Talking to the car."),
                         tone: .caution, symbol: "antenna.radiowaves.left.and.right", showsHelp: false)
        case .connected:
            return .init(phase: phase, title: String(localized: "Connected"),
                         detail: adapterName.map { String(localized: "\($0) · reading the car") } ?? String(localized: "reading the car"),
                         tone: .good, symbol: "checkmark.circle.fill", showsHelp: false)
        case .reconnecting:
            return .init(phase: phase, title: String(localized: "Adapter lost"),
                         detail: adapterName.map { String(localized: "Reconnecting to \($0)") }
                             ?? String(localized: "Reconnecting to your adapter"),
                         tone: .bad, symbol: "exclamationmark.triangle", showsHelp: false)
        case .failed:
            return .init(phase: phase, title: String(localized: "Connection failed"), detail: reason.map(LinkReasonText.display),
                         tone: .bad, symbol: "xmark.octagon", showsHelp: false)
        }
    }

    /// While the demo drive holds the link down (R74.1-6) the state line says
    /// why nothing connects; the real status comes back when the demo stops.
    static func status(_ status: AdapterScreenStatus, heldForDemo: Bool) -> AdapterScreenStatus {
        guard heldForDemo else { return status }
        return .init(phase: status.phase, title: String(localized: "Held for the demo drive"), detail: String(localized: "Connects when you stop it."),
                     tone: .neutral, symbol: "pause.circle", showsHelp: false)
    }

    /// The fake inputs (screenshots) through the same mapping.
    static func status(for fake: AdapterFake) -> AdapterScreenStatus {
        status(link: fake.link, adapterName: fake.name, hasRemembered: fake.hasRemembered,
               foundAdapter: fake.discovered.contains(where: OBDLinkService.isLikelyAdapter), waitedLong: fake.waitedLong)
    }

    static func controls(link: OBDLinkState, recording: Bool, remembered: UUID?) -> AdapterControls {
        let unavailable = if case .unavailable = link { true } else { false }
        return AdapterControls(
            isScanning: link == .scanning,
            canScan: ConsoleText.canScan(link: link, recording: recording),
            canConnect: remembered != nil && !unavailable && !ConsoleText.holdsConnection(link),
            canDisconnect: ConsoleText.holdsAdapter(link),
            canForget: remembered != nil)
    }

    /// Why Scan is disabled; nil while it is enabled or running.
    static func scanNote(link: OBDLinkState, recording: Bool) -> String? {
        if link == .scanning || ConsoleText.canScan(link: link, recording: recording) { return nil }
        if case .unavailable = link { return String(localized: "Needs Bluetooth.") }
        if recording { return String(localized: "Scanning is off while recording.") }
        return String(localized: "Disconnect first to look for another adapter.")
    }

    /// The long-wait timer restarts whenever this changes; nil = no timer.
    /// Reconnect attempts share one key, so the backoff's attempts don't
    /// restart it.
    static func waitKey(_ link: OBDLinkState) -> String? {
        switch link {
        case .scanning: "scanning"
        case .connecting, .reconnecting: "connecting"
        default: nil
        }
    }
}

// MARK: - Fakes

/// DEBUG `-uiFakeAdapter connected|notfound|searching|failed|bluetoothOff|bluetoothDenied`: plain
/// inputs for simulator screenshots, with a generic adapter name. Applied by
/// `RootView` in DEBUG builds only; parsed here so it is testable.
struct AdapterFake: Equatable, Sendable {
    var link: OBDLinkState
    var name: String?
    var hasRemembered: Bool
    var discovered: [DiscoveredAdapter] = []
    var waitedLong = false
    var isRecording = false

    static let genericName = "OBDII"

    static func parse(_ value: String?) -> AdapterFake? {
        switch value {
        case "connected":
            return AdapterFake(link: .polling(protocolNumber: "6", voltage: 12.4), name: genericName, hasRemembered: true)
        case "notfound":
            // A scan that has run a while and sees only non-adapter devices.
            return AdapterFake(
                link: .scanning, name: nil, hasRemembered: false,
                discovered: [DiscoveredAdapter(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                                               name: "Headphones", rssi: -78)],
                waitedLong: true)
        case "searching":
            return AdapterFake(
                link: .scanning, name: nil, hasRemembered: false,
                discovered: [DiscoveredAdapter(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                                               name: genericName, rssi: -55)])
        case "failed":
            // A typed link failure as the service writes it (English in the log, shown through `LinkReasonText`).
            return AdapterFake(link: .failed(reason: LinkReason.noUARTPair(services: 3).text), name: genericName,
                               hasRemembered: true)
        case "bluetoothOff":
            return AdapterFake(link: .unavailable(reason: BLEAvailability.Reason.poweredOff), name: genericName,
                               hasRemembered: true)
        case "bluetoothDenied":
            return AdapterFake(link: .unavailable(reason: BLEAvailability.Reason.unauthorized), name: genericName,
                               hasRemembered: true)
        default:
            return nil
        }
    }
}
