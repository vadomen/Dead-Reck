import SwiftUI
import UIKit

@main
struct DriveLoggerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Created once, at launch: the OBD link (for CoreBluetooth state
    /// restoration) and the recording session.
    @State private var services: AppServices

    init() {
        let services = AppServices()
        _services = State(initialValue: services)
        #if DEBUG
        DebugAutoRecord.startIfRequested(services)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    services.session.handleMemoryWarning()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            services.session.handleScenePhase(phase)
        }
    }
}
