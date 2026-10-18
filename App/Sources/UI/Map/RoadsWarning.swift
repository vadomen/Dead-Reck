import DriveLoggerCore
import Foundation
import Observation

/// The one-line map warning for "roads are off and the driver can fix it".
/// Pure: the rule is unit-tested; `RoadsWarningModel` only feeds it.
enum RoadsWarning {
    static let noPacks = "No road packs \u{2014} roads off"
    static let noneCovering = "No road pack covers this area \u{2014} roads off"
    static let refused = "Road packs refused \u{2014} see Diagnostics"

    /// The line to show, or nil.
    ///
    /// - No run navigating (a recording or Navigate), or roads attached: nil.
    /// - No verified pack once this run's own library rescan has
    ///   returned (`libraryScanned`, R34.1-3): `noPacks`, even before the
    ///   first selection attempt has an outcome.
    /// - Otherwise only the latest attempt's outcome speaks: `noPacks`,
    ///   `noneCovering`, `refused`. `selected`, `unusableRequest` (transient:
    ///   the engine raises a new request, nothing the driver can fix),
    ///   `unfinished` and no attempt yet give nil.
    static func message(
        active: Bool, libraryScanned: Bool, verifiedPacks: Int, roadsAttached: Bool,
        lastOutcome: NavSidecar.RoadsSelection.Outcome?
    ) -> String? {
        guard active, !roadsAttached else { return nil }
        if libraryScanned, verifiedPacks == 0 { return noPacks }
        guard let lastOutcome else { return nil }
        if lastOutcome == .noPacks { return noPacks }
        if lastOutcome == .noneCovering { return noneCovering }
        if lastOutcome == .refused { return refused }
        return nil
    }
}

extension RoadsWarning {
    /// The line for the run in progress: `message` over the service's
    /// roads status and the library's latest packs (the map polls it). The
    /// library counts as scanned only once the run's own rescan has
    /// returned (`RoadsStatus.libraryScanned`), not when an earlier scan is
    /// finished and idle: at Start the rescan begins in a `.utility` task,
    /// and a poll before it would read the previous scan's packs (R34.1-3).
    static func current(service: NavigationService, library: RoadPackLibrary) async -> String? {
        let roads = await service.roadsStatus()
        guard roads.active else { return nil }
        let status = await library.status()
        return message(
            active: roads.active, libraryScanned: roads.libraryScanned,
            verifiedPacks: status.packs.filter(\.verified).count, roadsAttached: roads.inUse,
            lastOutcome: roads.lastOutcome
        )
    }
}

/// Observed by the map. `message` is written only when it changes.
@MainActor
@Observable
final class RoadsWarningModel {
    typealias Source = @Sendable () async -> String?

    /// Polled once a second: two actor hops, no more.
    static let pollInterval: Duration = .seconds(1)

    private(set) var message: String?
    /// How many times `message` was assigned (a test sees the guard; R34.1-5).
    @ObservationIgnored private(set) var messageWrites = 0
    @ObservationIgnored private let source: Source?

    init(source: @escaping Source) { self.source = source }

    /// Previews and tests: a fixed line.
    init(message: String?) {
        self.message = message
        source = nil
    }

    func refresh() async {
        guard let source else { return }
        let next = await source()
        if next != message {
            message = next
            messageWrites += 1
        }
    }

    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
