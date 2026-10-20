import DriveLoggerCore
import Foundation

/// What the map, the HUD, the link indicator and the roads warning are bound
/// to (REL-DEMO): the app's own objects, or the running demo's. Chosen in one
/// place from `DemoDriveController.isRunning`, so every part switches in the
/// same render: no frame shows the user's real state during the demo, or the
/// demo's after it. Pure selection over the given objects.
@MainActor
struct MapBindings {
    var session: RecordingSession
    var link: any OBDLinkServicing
    var navigation: NavigationFeed
    var roadsWarning: RoadsWarningModel
    /// nil during the demo: the one-time mount card neither fires nor can be
    /// marked seen (the demo car is parked and "mounted" by definition).
    var mountConfirmation: MountConfirmationModel?
    /// nil during the demo: no road-pack offer (the demo is offline, and the
    /// offer reads the app's estimate, not the demo's).
    var offers: PackOfferMonitor?
    /// The system's last position; always nil during the demo, so the user's
    /// real position never frames the camera.
    var cachedLocation: @MainActor () -> CachedLocation?
    /// The roads, bounds and Stop; nil outside the demo.
    var demo: MapDemo?

    var isDemo: Bool { demo != nil }

    /// The app's own, or the demo's while it runs.
    /// - Parameters:
    ///   - demoFeed, demoWarning: made fresh at each demo start (the previous
    ///     run's estimate and message must not show for a moment).
    ///   - demoRoads: the converted roads of the running demo (cached per run).
    static func make(
        appSession: RecordingSession, appLink: any OBDLinkServicing, appFeed: NavigationFeed,
        appWarning: RoadsWarningModel, mount: MountConfirmationModel, offers: PackOfferMonitor?,
        cachedLocation: @escaping @MainActor () -> CachedLocation?,
        demo: DemoDriveController, demoFeed: NavigationFeed, demoWarning: RoadsWarningModel,
        demoRoads: DemoRoadLayers?
    ) -> MapBindings {
        if demo.isRunning, let session = demo.session, let link = demo.link, let roads = demo.roads, let demoRoads {
            return MapBindings(
                session: session, link: link, navigation: demoFeed, roadsWarning: demoWarning,
                mountConfirmation: nil, offers: nil, cachedLocation: { nil },
                demo: MapDemo(roads: demoRoads, southWest: roads.southWest, northEast: roads.northEast,
                              onStop: { demo.stop() }, elapsed: { demo.elapsedSeconds }))
        }
        return MapBindings(
            session: appSession, link: appLink, navigation: appFeed, roadsWarning: appWarning,
            mountConfirmation: mount, offers: offers, cachedLocation: cachedLocation, demo: nil)
    }
}

/// Settings' Demo drive row: enabled, or why not.
enum DemoDriveRow: Equatable {
    case ready
    /// Disabled; the reason is shown under the row.
    case blocked(String)

    static let recordActiveText = "Stop the recording to run the demo."

    static func make(_ blocker: DemoDriveStartBlocker?) -> DemoDriveRow {
        switch blocker {
        case nil: .ready
        case .recordActive?: .blocked(recordActiveText)
        case .running?: .ready   // Stop demo is on the map; a second tap just returns to it
        case .unavailable?: .blocked("The demo is not available in this build.")
        }
    }
}
