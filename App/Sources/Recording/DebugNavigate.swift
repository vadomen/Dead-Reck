#if DEBUG
import Foundation

/// DEBUG builds only, for simulator screenshots of Navigate (UX-1):
///
/// - `-navigateConnect 1` scans and connects the simulated adapter at launch
///   (without it the simulator app has no OBD, the "Connect OBD" state).
/// - `-navigateDisconnectAt S` (with the above) calls `link.disconnect()` S
///   seconds after the link first polls: Navigate goes to `waitingForOBD`
///   and stays there (a user disconnect does not reconnect).
///
/// The simulated adapter remembers itself in its own defaults suite; uninstall
/// the app to get the no-OBD state back. No effect in Release builds.
@MainActor
enum DebugNavigate {
    static func startIfRequested(_ services: AppServices, defaults: UserDefaults = .standard) {
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
        link.disconnect()
    }
}
#endif
