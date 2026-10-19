import Foundation

/// The first-launch pack list (UX-8 (1), docs/BACKLOG_UX.md; prompt 26):
/// which manifest packs to preselect and which to list next to them, from
/// one coarse location fix. Decision (a): the manifest `bbox` is enough to
/// SUGGEST; exact containment is the pack's `COVR`, known only after the
/// download. The user edits the list and confirms; nothing here downloads
/// anything, and the fix never leaves the phone.
///
/// - **The fix** must be usable (`fixVerdict`): a finite position, accuracy
///   finite, ≥ 0 and ≤ 5 km, arrived within 10 s of the request, and fresh
///   (taken no earlier than the request and at most 60 s old on arrival:
///   the first fix iOS hands over can be a cached one tens of minutes old).
/// - **The region** is the `.region` pack whose bbox contains the fix; of
///   several (bboxes of neighbouring regions overlap), the one whose bbox
///   centre is nearest. Ties go to the smaller name, so the choice is
///   deterministic.
/// - **Neighbours** are the other `.region` packs whose bbox is within
///   `neighbourDistanceM` of the fix (0 when the fix is inside it), nearest
///   first; listed, never preselected.
/// - **Preselected** = every `.national` pack (always, fix or not) + the
///   region (only with a usable fix). No usable fix: national only, no
///   region, no neighbours.
///
/// **Distances** are measured in the local tangent plane at the fix
/// (`LocalTangentPlane`, WGS-84 radii): to a bbox centre, and to the bbox's
/// nearest point taken as the fix clamped into the box in degrees. For boxes
/// of a few hundred km and a 20 km threshold this is well within what a
/// suggestion needs (the plane's error at 300 km is a fraction of a percent).
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public enum PackRegionChoice {
    public struct Config: Hashable, Sendable {
        /// The largest usable `horizontalAccuracy`, metres.
        public var maxAccuracyM: Double
        /// The longest wait from the request to the fix's arrival, seconds.
        public var maxWaitS: Double
        /// The oldest fix accepted, at arrival, seconds.
        public var maxFixAgeS: Double
        /// Region packs whose bbox is this close to the fix are listed as
        /// neighbours, metres.
        public var neighbourDistanceM: Double

        public init(maxAccuracyM: Double = 5_000, maxWaitS: Double = 10, maxFixAgeS: Double = 60,
                    neighbourDistanceM: Double = 20_000) {
            self.maxAccuracyM = maxAccuracyM
            self.maxWaitS = maxWaitS
            self.maxFixAgeS = maxFixAgeS
            self.neighbourDistanceM = neighbourDistanceM
        }

        public static let `default` = Config()
    }

    /// A coarse fix as the app received it (a CoreLocation fix converted at
    /// the boundary). All three times are wall-clock `Date`s: the fix's own
    /// `timestamp` is one, so the request and arrival times must be too.
    public struct Fix: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// Metres; negative or non-finite is unusable (iOS: invalid).
        public var horizontalAccuracyM: Double
        /// When the fix was taken (`CLLocation.timestamp`).
        public var timestamp: Date
        /// When the app received it.
        public var arrivedAt: Date

        public init(latitude: Double, longitude: Double, horizontalAccuracyM: Double, timestamp: Date, arrivedAt: Date) {
            self.latitude = latitude
            self.longitude = longitude
            self.horizontalAccuracyM = horizontalAccuracyM
            self.timestamp = timestamp
            self.arrivedAt = arrivedAt
        }
    }

    /// Whether a fix may suggest a region, and if not, why (diagnostics).
    public enum FixVerdict: Hashable, Sendable {
        case usable
        /// No fix arrived (or none was asked for).
        case noFix
        /// Latitude/longitude not finite or out of range.
        case invalidPosition
        /// Accuracy not finite, negative, or above `maxAccuracyM`.
        case inaccurate
        /// Arrived more than `maxWaitS` after the request, or before it.
        case late
        /// Taken before the request, or more than `maxFixAgeS` old on arrival.
        case stale
    }

    /// The verdict for `fix`, requested at `requestedAt`. The checks run in
    /// the order of the cases (position, accuracy, arrival, age), so one
    /// verdict names the first failure.
    public static func fixVerdict(_ fix: Fix?, requestedAt: Date, config: Config = .default) -> FixVerdict {
        guard let fix else { return .noFix }
        guard fix.latitude.isFinite, fix.longitude.isFinite, abs(fix.latitude) <= 90, abs(fix.longitude) <= 180 else {
            return .invalidPosition
        }
        let accuracy = fix.horizontalAccuracyM
        guard accuracy.isFinite, accuracy >= 0, accuracy <= config.maxAccuracyM else { return .inaccurate }
        let wait = fix.arrivedAt.timeIntervalSince(requestedAt)
        guard wait.isFinite, wait >= 0, wait <= config.maxWaitS else { return .late }
        let age = fix.arrivedAt.timeIntervalSince(fix.timestamp)
        guard fix.timestamp >= requestedAt, age.isFinite, age <= config.maxFixAgeS else { return .stale }
        return .usable
    }

    /// A region pack listed next to the chosen one.
    public struct Neighbour: Hashable, Sendable {
        public var name: String
        /// From the fix to the pack's bbox (0 inside), metres.
        public var distanceM: Double

        public init(name: String, distanceM: Double) {
            self.name = name
            self.distanceM = distanceM
        }
    }

    /// The first-launch suggestion.
    public struct Suggestion: Hashable, Sendable {
        /// The names to preselect, in list order: every `.national` pack
        /// (manifest order), then the region if any.
        public var preselected: [String]
        /// The region containing a usable fix; nil without one, or when no
        /// region bbox contains it.
        public var region: String?
        /// Listed next to the region, NOT preselected; nearest first.
        public var neighbours: [Neighbour]
        public var fixVerdict: FixVerdict

        public init(preselected: [String], region: String?, neighbours: [Neighbour], fixVerdict: FixVerdict) {
            self.preselected = preselected
            self.region = region
            self.neighbours = neighbours
            self.fixVerdict = fixVerdict
        }
    }

    /// The suggestion for the manifest's `packs` and the first fix (nil:
    /// none arrived).
    public static func suggest(packs: [PackManifest.Pack], fix: Fix?, requestedAt: Date,
                               config: Config = .default) -> Suggestion {
        let national = packs.filter { $0.kind == .national }.map(\.name)
        let verdict = fixVerdict(fix, requestedAt: requestedAt, config: config)
        guard verdict == .usable, let fix else {
            return Suggestion(preselected: national, region: nil, neighbours: [], fixVerdict: verdict)
        }
        let region = containingRegion(latitude: fix.latitude, longitude: fix.longitude, in: packs)
        let near = neighbours(latitude: fix.latitude, longitude: fix.longitude, in: packs,
                              excluding: region.map { [$0.name] } ?? [], withinM: config.neighbourDistanceM)
        return Suggestion(preselected: national + (region.map { [$0.name] } ?? []), region: region?.name,
                          neighbours: near, fixVerdict: verdict)
    }

    /// The `.region` pack whose (valid) bbox contains the point, edges
    /// included; of several, the nearest bbox centre, ties to the smaller
    /// name. `excluding` names are not considered. nil when none contains it
    /// or the point is unusable.
    public static func containingRegion(latitude: Double, longitude: Double, in packs: [PackManifest.Pack],
                                        excluding: Set<String> = []) -> PackManifest.Pack? {
        guard let plane = plane(latitude: latitude, longitude: longitude) else { return nil }
        var best: (pack: PackManifest.Pack, d2: Double)?
        for pack in packs where pack.kind == .region && !excluding.contains(pack.name) {
            let box = pack.bbox
            guard box.isValid, box.contains(latitude: latitude, longitude: longitude) else { continue }
            let c = plane.enu(latitude: (box.south + box.north) / 2, longitude: (box.west + box.east) / 2)
            let d2 = c.east * c.east + c.north * c.north
            if let b = best, d2 > b.d2 || (d2 == b.d2 && pack.name >= b.pack.name) { continue }
            best = (pack, d2)
        }
        return best?.pack
    }

    /// The `.region` packs (not `excluding`) whose valid bbox is within
    /// `withinM` metres of the point (0 inside), by distance, then name.
    public static func neighbours(latitude: Double, longitude: Double, in packs: [PackManifest.Pack],
                                  excluding: Set<String>, withinM: Double) -> [Neighbour] {
        guard let plane = plane(latitude: latitude, longitude: longitude), withinM.isFinite, withinM >= 0 else { return [] }
        var found: [Neighbour] = []
        for pack in packs where pack.kind == .region && !excluding.contains(pack.name) && pack.bbox.isValid {
            let d = pack.bbox.distanceM(from: plane)
            if d <= withinM { found.append(Neighbour(name: pack.name, distanceM: d)) }
        }
        return found.sorted { ($0.distanceM, $0.name) < ($1.distanceM, $1.name) }
    }

    /// The first-launch list order: the `.national` packs (manifest order),
    /// then the suggested region, then the neighbours (nearest first), then
    /// every other pack in `restOrder` (the UI passes its localized-title
    /// comparison). Each pack appears once.
    public static func listOrder(_ packs: [PackManifest.Pack], suggestion: Suggestion,
                                 restOrder: (PackManifest.Pack, PackManifest.Pack) -> Bool) -> [PackManifest.Pack] {
        var placed = Set<String>()
        var list: [PackManifest.Pack] = []
        func place(_ pack: PackManifest.Pack) {
            if placed.insert(pack.name).inserted { list.append(pack) }
        }
        for pack in packs where pack.kind == .national { place(pack) }
        let byName = Dictionary(packs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        if let region = suggestion.region, let pack = byName[region] { place(pack) }
        for neighbour in suggestion.neighbours { if let pack = byName[neighbour.name] { place(pack) } }
        for pack in packs.filter({ !placed.contains($0.name) }).sorted(by: restOrder) { place(pack) }
        return list
    }

    static func plane(latitude: Double, longitude: Double) -> LocalTangentPlane? {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return LocalTangentPlane(latitude: latitude, longitude: longitude)
    }
}

extension PackManifest.BBox {
    /// Whether the point is inside the box, edges included (false for a
    /// non-finite point; an invalid box may answer either way).
    public func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    /// From the plane's anchor to the box's nearest point (the anchor
    /// clamped into the box in degrees), metres; 0 inside.
    func distanceM(from plane: LocalTangentPlane) -> Double {
        let lat = min(max(plane.anchorLatitude, south), north)
        let lon = min(max(plane.anchorLongitude, west), east)
        let p = plane.enu(latitude: lat, longitude: lon)
        return (p.east * p.east + p.north * p.north).squareRoot()
    }
}
