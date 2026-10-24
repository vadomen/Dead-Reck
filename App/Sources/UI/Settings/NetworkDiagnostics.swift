import DriveLoggerCore
import Foundation

/// The developer-only "Map downloads network" rows of Settings → Diagnostics
/// (UX-17): what the path monitor reported, the "Use cellular data" switch
/// as the UserDefault and as the downloader holds it, and the policy
/// decision for each queued job. Pure text from a downloader snapshot, so a
/// disagreement between the switch and the downloader shows as a row.
enum NetworkDiagnosticsText {
    struct Row: Hashable, Identifiable, Sendable {
        var label: String
        var value: String
        /// Shown in red: something that should agree does not.
        var isProblem = false
        var id: String { label }
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    static func connection(_ value: PackDownloadRules.Connection) -> String {
        switch value {
        case .none: "none"
        case .unmetered: "unmetered"
        case .cellular: "cellular"
        case .meteredWiFi: "metered Wi-Fi"
        }
    }

    static func policy(_ value: PackDownloadRules.NetworkState) -> String {
        switch value {
        case .allowed: "allowed"
        case .waitingForWiFi: "waiting for Wi-Fi (cellular, switch off)"
        case .waitingMeteredWiFi: "waiting (metered Wi-Fi, switch off)"
        case .pausedForRecording: "paused (recording)"
        case .offline: "offline"
        }
    }

    /// "satisfied · Wi-Fi · expensive no · constrained no"; before the first report, the mapped connection only.
    static func path(_ snapshot: PackDownloader.Snapshot) -> String {
        guard let path = snapshot.path else { return "not reported (connection \(connection(snapshot.connection)))" }
        return [path.satisfied ? "satisfied" : "not satisfied", path.interfaces,
                "expensive " + yesNo(path.expensive), "constrained " + yesNo(path.constrained)].joined(separator: " · ")
    }

    /// The decision a job gets: its state in the snapshot.
    static func job(_ state: PackDownloader.State) -> String {
        switch state {
        case .queued: "queued (allowed)"
        case .waitingForWiFi: "waiting for Wi-Fi"
        case .waitingMeteredWiFi: "waiting, metered Wi-Fi"
        case .offline: "waiting for network"
        case .pausedForRecording: "paused (recording)"
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .failed(let reason): "failed: \(reason.text)"
        }
    }

    /// - Parameter setting: the "Use cellular data" UserDefault.
    static func rows(_ snapshot: PackDownloader.Snapshot, setting: Bool) -> [Row] {
        var rows = [
            Row(label: String(localized: "Path"), value: path(snapshot)),
            Row(label: String(localized: "Maps connection"), value: connection(snapshot.connection)),
            Row(label: String(localized: "Cellular switch"),
                value: "setting \(onOff(setting)) · downloader \(onOff(snapshot.cellularAllowed))"
                    + (setting == snapshot.cellularAllowed ? "" : " · MISMATCH"),
                isProblem: setting != snapshot.cellularAllowed),
            Row(label: String(localized: "Policy"), value: policy(snapshot.policy)),
        ]
        for name in snapshot.states.keys.sorted() {
            guard let state = snapshot.states[name] else { continue }
            rows.append(Row(label: name, value: job(state)))
        }
        return rows
    }
}
