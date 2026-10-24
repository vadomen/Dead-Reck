import Foundation

/// App Store screenshot capture mode (`scripts/store_screenshots.sh`).
///
/// DEBUG builds only: `-storeScreenshots 1` hides exactly three things while
/// the demo drive runs, so a store image shows the product and not its test
/// scaffolding: the "nav: ..." developer strip, the DEMO badge and the
/// "Stop demo" button. Nothing else changes (the demo, the map, the OSM
/// credit are as in a normal demo run). In Release `current` is always `off`,
/// whatever the launch arguments say.
struct StoreScreenshotMode: Equatable {
    static let key = "storeScreenshots"
    /// DEBUG `-storeDemoReadyAt S`: when the demo clock reaches S seconds the
    /// app writes `readyFileName` into its tmp directory, so the capture
    /// script can shoot at a fixed demo moment.
    static let readyKey = "storeDemoReadyAt"
    static let readyFileName = "store-demo-ready"

    var isOn: Bool

    static let off = StoreScreenshotMode(isOn: false)

    /// The launch arguments' mode; `off` in Release.
    static var current: StoreScreenshotMode {
        #if DEBUG
        from(defaults: .standard)
        #else
        .off
        #endif
    }

    static func from(defaults: UserDefaults) -> StoreScreenshotMode {
        StoreScreenshotMode(isOn: defaults.bool(forKey: key))
    }

    /// The DEMO badge and Stop demo are drawn.
    var showsDemoControls: Bool { !isOn }

    /// The developer strip is drawn: the driver's setting, unless capturing.
    func showsDebugStrip(setting: Bool) -> Bool { isOn ? false : setting }
}

#if DEBUG
extension StoreScreenshotMode {
    /// The demo second to signal, nil when not requested.
    static func readyAt(defaults: UserDefaults = .standard) -> Double? {
        defaults.object(forKey: readyKey) == nil ? nil : defaults.double(forKey: readyKey)
    }

    /// Polls the demo clock; at `seconds` writes the ready file (once).
    @MainActor
    static func signalReady(at seconds: Double, elapsed: @MainActor () -> Double?, directory: URL = FileManager.default.temporaryDirectory) async {
        let file = directory.appendingPathComponent(readyFileName)
        try? FileManager.default.removeItem(at: file)
        while !Task.isCancelled {
            if let t = elapsed(), t >= seconds {
                try? Data().write(to: file)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
