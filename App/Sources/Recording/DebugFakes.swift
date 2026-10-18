#if DEBUG
import Foundation

/// DEBUG builds only: synthetic values for simulator screenshots (the
/// simulator has no road packs). Names are made up. No effect in Release.
enum DebugFakes {
    static var mapsStatus: RoadPackLibrary.Status {
        RoadPackLibrary.Status(
            packs: [
                .preview("national", bytes: 120_000_000, hash: "0f0e0d0c", coverage: false),
                .preview("region-a", hash: "a1b2c3d4"),
                .preview("region-b", hash: "5e6f7a8b", pending: true),
            ],
            scansCompleted: 1, storeBytes: 216_000_000)
    }
}
#endif
