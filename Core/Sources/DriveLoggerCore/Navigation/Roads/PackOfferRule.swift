import Foundation

/// An installed pack's coverage, by pack name (`RoadPackLibrary` in the app
/// lists them; `PackOfferRule` tests the estimate against them).
public struct InstalledPackCoverage: Hashable, Sendable {
    /// The pack name (`<name>` of `<name>-<contentHash>.roadpack`), as in
    /// the manifest.
    public var name: String
    public var coverage: RoadPackCoverage

    public init(name: String, coverage: RoadPackCoverage) {
        self.name = name
        self.coverage = coverage
    }
}

/// The at-a-stop road-pack offer (UX-8 (2), docs/BACKLOG_UX.md; prompt 26):
/// "You are in <region>, no road map. Download <size>?" — shown only at a
/// stop, never in motion (the UX safety rule), at most once per region per
/// drive. A value-type state machine: one instance per Navigate or Record
/// run (a "drive"), fed by `update(_:)` at whatever rate the caller likes
/// (about 1 Hz is plenty); deterministic, no clock of its own.
///
/// **Only the navigation estimate is input**, never the raw GNSS fix: the
/// app is for drives where GNSS is jammed or spoofed. A raw fix outside
/// coverage with the estimate inside is "inside" here.
///
/// **Outside.** A CONFIDENT estimate (95 % ellipse semi-major finite and
/// ≤ `maxSemiMajorM`) whose centre is in no installed REGION coverage
/// (`RoadPackCoverage.intersects(…, radiusM: 0)`). Coverages of `.national`
/// manifest packs are ignored: the national pack's `COVR` is the whole
/// country, and it has main roads only, so being inside it is exactly the
/// case the offer is for. A pack not in the manifest (a developer pack)
/// counts as region coverage. A missing, non-finite or unconfident estimate
/// resets the outside timer (keeping a pending region); a confident one
/// inside a coverage resets it AND forgets the pending region. An
/// unconverged estimate near a coverage edge therefore never starts the
/// timer: it is not confident.
///
/// **Pending region.** While outside, the region at the estimate is the
/// manifest `.region` pack whose bbox contains it, nearest centre first
/// (`PackRegionChoice.containingRegion`), skipping excluded (installed,
/// downloading, queued) and "Never" names; nil when none. After
/// `outsideS` continuously outside IN THE SAME region (a change of region,
/// nil included, restarts the timer), it becomes the pending region; nothing
/// is shown then. 30 s outside every eligible bbox (abroad, or only declined
/// regions) clears it.
///
/// **Stop.** The active speed (OBD first; km/h) finite, ≥ 0 and
/// ≤ `stopSpeedKmh` (default 0: OBD speed is whole km/h, so 0 already
/// means < 1 km/h) continuously for `stopS`. Unknown (nil, negative or
/// non-finite: iOS's `-1`) or any higher speed resets it.
///
/// **Offer.** At a stop, with a pending region not offered this drive, not
/// in "Never", not excluded, still a `.region` pack in the manifest, and no
/// confirmation dialog open: `offer` is that pack. It turns nil as soon as
/// the stop ends (speed > 0 or unknown), a dialog opens, or the region
/// becomes excluded, "Never" or leaves the manifest.
///
/// **Once per region per drive.** A region counts as offered the moment its
/// card is shown, so it is never shown again by this instance, even when the
/// card hid itself because the car moved without an answer: asking again at
/// every stop of a traffic jam would be the nagging the rule exists to
/// prevent. A new drive (a new instance) may offer it again, unless the
/// caller's "Never" set holds it. `answer(_:region:)` hides the card for
/// any answer and also marks the region offered; persisting "Never" (and
/// resetting it, Settings) is the caller's: the rule only reads the set.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public struct PackOfferRule: Hashable, Sendable {
    public struct Config: Hashable, Sendable {
        /// Continuously outside, in one region, before it is pending (s).
        public var outsideS: Double
        /// Continuously stopped before the offer shows (s).
        public var stopS: Double
        /// The largest 95 % semi-major axis of a confident estimate (m).
        /// 1 km: region bboxes are tens to hundreds of km across, so a
        /// 1 km estimate names the wrong region only within ~1 km of a
        /// border, where the border ways are in both packs anyway; and it
        /// excludes the unconverged estimate of a start under jamming
        /// (tower fixes of ~1.4 km accuracy).
        public var maxSemiMajorM: Double
        /// The highest speed that counts as stopped (km/h).
        public var stopSpeedKmh: Double

        public init(outsideS: Double = 30, stopS: Double = 3, maxSemiMajorM: Double = 1_000, stopSpeedKmh: Double = 0) {
            self.outsideS = outsideS
            self.stopS = stopS
            self.maxSemiMajorM = maxSemiMajorM
            self.stopSpeedKmh = stopSpeedKmh
        }

        public static let `default` = Config()
    }

    /// The navigation estimate (never a raw fix).
    public struct Estimate: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// The 95 % error ellipse's semi-major axis, metres.
        public var semiMajorM: Double

        public init(latitude: Double, longitude: Double, semiMajorM: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.semiMajorM = semiMajorM
        }
    }

    /// One update's input.
    public struct Input: Sendable {
        /// Monotonic seconds (any origin, the same for the whole drive).
        public var now: Double
        /// nil: no estimate yet (or the run has none).
        public var estimate: Estimate?
        /// The active source's speed, km/h (OBD first); nil unknown.
        public var speedKmh: Double?
        /// A confirmation dialog is open (no card may appear over it).
        public var dialogOpen: Bool
        /// The installed packs' coverages (`RoadPackLibrary.coverages()`).
        public var installed: [InstalledPackCoverage]
        /// The manifest's packs (cached or fresh); empty: nothing to offer.
        public var manifestPacks: [PackManifest.Pack]
        /// Names not to offer: installed, downloading or queued.
        public var excluded: Set<String>
        /// The persisted "Never for this region" names.
        public var never: Set<String>

        public init(now: Double, estimate: Estimate?, speedKmh: Double?, dialogOpen: Bool,
                    installed: [InstalledPackCoverage], manifestPacks: [PackManifest.Pack],
                    excluded: Set<String>, never: Set<String>) {
            self.now = now
            self.estimate = estimate
            self.speedKmh = speedKmh
            self.dialogOpen = dialogOpen
            self.installed = installed
            self.manifestPacks = manifestPacks
            self.excluded = excluded
            self.never = never
        }
    }

    /// The user's answer to a card.
    public enum Answer: Hashable, Sendable {
        /// Hide it for this drive.
        case notNow
        /// Hide it; the caller adds the region to its persisted "Never" set.
        case never
        /// Hide it; the caller queues the download (and lists it in `excluded`).
        case download
    }

    public let config: Config
    /// The pack to offer now; nil: show nothing.
    public private(set) var offer: PackManifest.Pack?
    /// The region remembered while outside coverage (diagnostics).
    public private(set) var pendingRegion: String?
    /// Regions shown (or answered) in this drive: never shown again.
    public private(set) var offered: Set<String> = []

    /// Since when the estimate is outside, and in which region.
    private struct Outside: Hashable, Sendable {
        var region: String?
        var since: Double
    }

    private var outside: Outside?
    private var stoppedSince: Double?
    private var lastNow: Double?

    public init(config: Config = .default) {
        self.config = config
    }

    /// Advances the rule to `input.now` and returns `offer`.
    @discardableResult
    public mutating func update(_ input: Input) -> PackManifest.Pack? {
        let now = input.now
        guard now.isFinite else {
            outside = nil
            stoppedSince = nil
            offer = nil
            return nil
        }
        if let last = lastNow, now < last {  // not monotonic: start the timers again
            outside = nil
            stoppedSince = nil
        }
        lastNow = now

        // Outside, and the pending region.
        if let e = input.estimate, e.latitude.isFinite, e.longitude.isFinite,
           abs(e.latitude) <= 90, abs(e.longitude) <= 180,
           e.semiMajorM.isFinite, e.semiMajorM >= 0, e.semiMajorM <= config.maxSemiMajorM {
            let national = Set(input.manifestPacks.filter { $0.kind == .national }.map(\.name))
            let inside = input.installed.contains {
                !national.contains($0.name)
                    && $0.coverage.intersects(latitude: e.latitude, longitude: e.longitude, radiusM: 0)
            }
            if inside {
                outside = nil
                pendingRegion = nil
            } else {
                let region = PackRegionChoice.containingRegion(
                    latitude: e.latitude, longitude: e.longitude, in: input.manifestPacks,
                    excluding: input.excluded.union(input.never))?.name
                if outside == nil || outside?.region != region { outside = Outside(region: region, since: now) }
                if let since = outside?.since, now - since >= config.outsideS { pendingRegion = region }
            }
        } else {
            outside = nil
        }

        // The stop.
        if let v = input.speedKmh, v.isFinite, v >= 0, v <= config.stopSpeedKmh {
            if stoppedSince == nil { stoppedSince = now }
        } else {
            stoppedSince = nil
        }
        let stopped = stoppedSince.map { now - $0 >= config.stopS } ?? false

        // The offer.
        func eligible(_ name: String) -> PackManifest.Pack? {
            guard !input.never.contains(name), !input.excluded.contains(name) else { return nil }
            return input.manifestPacks.first { $0.name == name && $0.kind == .region }
        }
        if let shown = offer {
            offer = stopped && !input.dialogOpen ? eligible(shown.name) : nil
        } else if stopped, !input.dialogOpen, let name = pendingRegion, !offered.contains(name),
                  let pack = eligible(name) {
            offer = pack
            offered.insert(name)
        }
        return offer
    }

    /// The user answered the card for `region` (any answer hides it; the
    /// region is not offered again in this drive).
    public mutating func answer(_ answer: Answer, region: String) {
        offered.insert(region)
        if offer?.name == region { offer = nil }
    }
}
