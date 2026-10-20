import DriveLoggerCore
import Foundation
import Observation

/// The one-line map warning for "roads are off and the driver can fix it".
/// Pure: the rule is unit-tested; `RoadsWarningModel` only feeds it.
enum RoadsWarning {
    static let noPacks = "No road packs \u{2014} roads off"
    static let noneCovering = "No road pack covers this area \u{2014} roads off"
    static let refused = "Road packs refused \u{2014} see Maps"

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

extension RoadsWarning {
    /// Whether the map credits OSM: the run is navigating and has packs attached.
    static func attributionCurrent(service: NavigationService) async -> Bool {
        let roads = await service.roadsStatus()
        return MapAttribution.visible(runActive: roads.active, packsInUse: roads.packNames.count)
    }
}

/// The Download action on the roads warning (B3, prompt 38): when the line says
/// "No road pack covers this area" (or there are no packs at all) and the
/// manifest has a region for the place, the line offers **Download <region>**.
/// It is the at-a-stop offer (`PackOfferMonitor`) shown in the banner: the same
/// rule (a confident estimate outside every region pack for 30 s, the car
/// stopped for 3 s, never in motion, "Not now" / "Never" respected) and the same
/// downloader (Wi-Fi / cellular policy; paused while Record is active), so the
/// banner never offers what the card would not. While the banner hosts the
/// offer the card is not shown (one surface, not two).
struct RoadsWarningDownload: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The offer is up: a button.
        case offer
        /// Download tapped; queued or running: a line, no button.
        case queued
    }

    var title: String
    var sizeBytes: Int64?
    var state: State
    /// A recording is active: the downloader waits for it to end.
    var recording: Bool

    /// The button's label.
    var buttonText: String {
        recording ? "Download \(title) after recording" : "Download \(title)"
    }

    /// The line that replaces the button once it was tapped.
    var queuedText: String {
        recording ? "\(title) downloads after the recording" : "Downloading \(title)\u{2026}"
    }
}

enum RoadsWarningOffer {
    /// The warnings that the driver can fix by downloading a region.
    static func offersDownload(message: String?) -> Bool {
        message == RoadsWarning.noneCovering || message == RoadsWarning.noPacks
    }

    /// The banner's download, or nil: no such warning, or neither an offer
    /// nor a queued download to speak of.
    static func make(
        message: String?, offer: PackOfferMonitor.Offer?, downloadingTitle: String?, recording: Bool
    ) -> RoadsWarningDownload? {
        guard offersDownload(message: message) else { return nil }
        if let offer {
            return RoadsWarningDownload(title: offer.title, sizeBytes: offer.sizeBytes, state: .offer, recording: recording)
        }
        if let downloadingTitle {
            return RoadsWarningDownload(title: downloadingTitle, sizeBytes: nil, state: .queued, recording: recording)
        }
        return nil
    }

    /// The card is not shown while the banner hosts the offer.
    static func hostsOffer(_ download: RoadsWarningDownload?) -> Bool { download?.state == .offer }
}

/// Observed by the map. `message` is written only when it changes.
@MainActor
@Observable
final class RoadsWarningModel {
    typealias Source = @Sendable () async -> String?
    typealias AttributionSource = @Sendable () async -> Bool

    /// Polled once a second: two actor hops, no more.
    static let pollInterval: Duration = .seconds(1)

    private(set) var message: String?
    /// The map shows "© OpenStreetMap contributors" (`MapAttribution`).
    private(set) var attribution = false
    /// How many times `message` was assigned (a test sees the guard; R34.1-5).
    @ObservationIgnored private(set) var messageWrites = 0
    @ObservationIgnored private let source: Source?
    @ObservationIgnored private let attributionSource: AttributionSource?

    init(source: @escaping Source, attributionSource: AttributionSource? = nil) {
        self.source = source
        self.attributionSource = attributionSource
    }

    /// Previews and tests: a fixed line.
    init(message: String?, attribution: Bool = false) {
        self.message = message
        self.attribution = attribution
        source = nil
        attributionSource = nil
    }

    func refresh() async {
        guard let source else { return }
        if let attributionSource {
            let credit = await attributionSource()
            if credit != attribution { attribution = credit }
        }
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
