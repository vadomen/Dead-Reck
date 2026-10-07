#if DEBUG
import DriveLoggerCore
import Foundation

/// DEBUG builds only: `-autoRecordSeconds N` on the command line records for
/// N seconds at launch with no UI, so the simulator can produce an end-to-end
/// recording before the recording screen exists:
///
/// ```
/// xcrun simctl launch --console <UDID> <bundle id> -autoRecordSeconds 75
/// ```
///
/// With `-autoRecordLinkLossAt S` as well, the simulated adapter is
/// "unplugged" S seconds after the start call (`SimulatedOBDLink` only), so
/// the recording also shows the BLE drop, the reconnect, a fresh `ATZ`
/// handshake and a new `adapter` row.
///
/// Connects the link if it has no remembered adapter (scan, then the first
/// likely adapter — on the simulator, "Simulated Vlink"), waits up to 30 s
/// for it to poll, starts a recording (without OBD only if it never polls,
/// which the `start` row then says), stops it N seconds after the start call
/// (the 5 s calibration included), and prints progress to stdout.
@MainActor
enum DebugAutoRecord {
    static let argument = "autoRecordSeconds"
    static let linkLossArgument = "autoRecordLinkLossAt"

    static func startIfRequested(_ services: AppServices, defaults: UserDefaults = .standard) {
        let seconds = defaults.integer(forKey: argument)
        guard seconds > 0 else { return }
        let linkLossAt = defaults.integer(forKey: linkLossArgument)
        Task { await run(services, seconds: seconds, linkLossAt: linkLossAt > 0 ? linkLossAt : nil) }
    }

    private static func run(_ services: AppServices, seconds: Int, linkLossAt: Int?) async {
        let link = services.link
        let session = services.session
        say("auto-record: \(seconds) s requested")
        if link.rememberedAdapterID == nil {
            link.startScan()
            let found = await waitFor(.seconds(10)) {
                link.discovered.first(where: OBDLinkService.isLikelyAdapter) ?? link.discovered.first
            }
            if let found {
                say("auto-record: connecting to \(found.name)")
                link.connect(to: found.id)
            } else {
                link.stopScan()
                say("auto-record: no adapter found")
            }
        }
        let polling = await waitFor(.seconds(30)) { () -> Bool? in
            if case .polling = link.state { return true }
            return nil
        } ?? false
        say("auto-record: link \(RecordingSession.describe(link.state)); starting\(polling ? "" : " without OBD")")

        let start = Task {
            try await session.start(
                mount: "DEBUG auto-record",
                vehicle: "",
                allowWithoutOBD: !polling,
                calibration: .seconds(5)
            )
        }
        if let linkLossAt, linkLossAt < seconds, let simulated = link as? SimulatedOBDLink {
            try? await Task.sleep(for: .seconds(linkLossAt))
            say("auto-record: simulating adapter link loss")
            await simulated.simulateLinkLoss()
            try? await Task.sleep(for: .seconds(seconds - linkLossAt))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        if case .failure(let error) = await start.result {
            say("auto-record: start failed: \(error)")
            return
        }
        let file = session.currentFile
        await session.stop()
        say("auto-record: done, state \(session.state), file \(file?.path ?? "none")")
    }

    /// Polls `value` every 100 ms until it is non-nil or `timeout` passes.
    private static func waitFor<T>(_ timeout: Duration, _ value: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return value()
    }

    private static func say(_ text: String) {
        print("[DriveLogger] \(text)")
    }
}
#endif
