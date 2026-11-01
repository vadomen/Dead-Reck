#if DEBUG || targetEnvironment(simulator)
import Foundation

/// DEBUG builds and simulator builds only (never a device Release build),
/// for simulator screenshots of Navigate (UX-1) and the Release-simulator
/// CPU measurement of prompt 47 item 5 (a Release build on the simulator
/// still has no adapter, so the OBD run needs this hook there too):
///
/// - `-navigateConnect 1` scans and connects the simulated adapter at launch
///   (without it the simulator app has no OBD, the "Connect OBD" state).
/// - `-navigateDisconnectAt S` (with the above) calls `link.disconnect()` S
///   seconds after the link first polls: Navigate goes to `waitingForOBD`
///   and stays there (a user disconnect does not reconnect).
/// - `-navigateTrace 1` prints every `navigateState` change, and every 30 s
///   the engine's ms/step, to stdout (`xcrun simctl launch --stdout=<file>`),
///   so a measurement can confirm its transitions. Read-only.
///
/// The simulated adapter remembers itself in its own defaults suite; uninstall
/// the app to get the no-OBD state back. Nothing here changes a default or
/// a timing; without the arguments it does nothing.
@MainActor
enum DebugNavigate {
    static func startIfRequested(_ services: AppServices, defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: "navigateTrace") { trace(services) }
        guard defaults.bool(forKey: "navigateConnect") else { return }
        let disconnectAt = defaults.integer(forKey: "navigateDisconnectAt")
        Task { await run(services, disconnectAt: disconnectAt > 0 ? disconnectAt : nil) }
    }

    private static func run(_ services: AppServices, disconnectAt: Int?) async {
        let link = services.link
        if link.rememberedAdapterID == nil {
            link.startScan()
            var found: DiscoveredAdapter?
            for _ in 0..<100 where found == nil {
                found = link.discovered.first(where: OBDLinkService.isLikelyAdapter) ?? link.discovered.first
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let found else { link.stopScan(); return }
            link.connect(to: found.id)
        }
        guard let disconnectAt else { return }
        for _ in 0..<300 {
            if case .polling = link.state { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(disconnectAt))
        say("link.disconnect() (navigateDisconnectAt \(disconnectAt) s after polling)")
        link.disconnect()
    }

    // MARK: - Trace (`-navigateTrace 1`)

    private static let launchedAt = ContinuousClock.now

    private static func trace(_ services: AppServices) {
        _ = launchedAt
        say("trace on")
        observeState(services.session)
        let navigation = services.navigation
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let s = await navigation.snapshot().stats
                say(String(format: "engine msPerStep %.3f max %.2f maxIngest %.2f steps %d inputs %d",
                           s.msPerStep, s.maxMsPerStep, s.maxIngestMs, s.steps, s.inputs))
            }
        }
    }

    private static func observeState(_ session: RecordingSession) {
        say("navigateState \(describe(session.navigateState))")
        withObservationTracking {
            _ = session.navigateState
        } onChange: {
            Task { @MainActor in observeState(session) }
        }
    }

    private static func describe(_ state: NavigateState) -> String {
        switch state {
        case .off: "off"
        case .calibrating: "calibrating"
        case .running: "running"
        case .waitingForOBD: "waitingForOBD"
        case .runningNoOBD: "runningNoOBD"
        }
    }

    private static func say(_ text: String) {
        let t = launchedAt.duration(to: .now).components.seconds
        print("[DriveLogger] t+\(t)s \(text)")
        fflush(stdout)
    }
}
#endif
