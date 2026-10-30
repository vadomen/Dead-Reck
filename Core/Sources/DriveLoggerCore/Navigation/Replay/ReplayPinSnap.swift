import Foundation

/// `replay_nav --snap-pins` (prompt 46 Part B, replay only): each logged
/// manual fix is snapped as the app would (`PinSnap`), from its raw tap
/// (`truthLatitude`/`truthLongitude`) with its logged `mapSpanM`, the
/// engine's road network and cloud just before the pin is ingested, and a
/// viewport `viewportHeightPt` tall. The engine gets the placed point
/// (`PinSnap.placement`): the snapped point with the tap kept, or the raw
/// tap. Scoring keeps the raw tap: pin truth is `truthLatitude`/
/// `truthLongitude` whatever the engine got.
///
/// No log records the viewport height (format v6 has none), so it is a
/// constant: 852 pt by default, the map viewport of the reference iPhone
/// screen in portrait (`--snap-viewport <pt>` overrides it). It only scales
/// the touch and junction radii (44 pt and 8 pt in metres are
/// span × points / height).
///
/// `spanOverrideM` (`--snap-span <m>`, a stress test): snap and place as if
/// every tap had been made on a map that many metres tall (radius, σ_pin for
/// the cloud, the span rule), with the logged tap position. The engine's
/// pin σ still comes from the row's own `mapSpanM`.
public struct ReplayPinSnap: Hashable, Sendable {
    public static let defaultViewportHeightPt = 852.0

    public var viewportHeightPt = Self.defaultViewportHeightPt
    public var parameters = PinSnap.Parameters()
    public var spanOverrideM: Double?

    public init(viewportHeightPt: Double = Self.defaultViewportHeightPt, spanOverrideM: Double? = nil) {
        self.viewportHeightPt = viewportHeightPt
        self.spanOverrideM = spanOverrideM
    }

    /// The mode label part: `-snap-pins`, plus `-vp-<pt>` for a viewport
    /// other than the default.
    public var labelSuffix: String {
        var s = "snap-pins"
        if viewportHeightPt != Self.defaultViewportHeightPt { s += "-vp-\(GPSMode.format(viewportHeightPt))" }
        if let spanOverrideM { s += "-span-\(GPSMode.format(spanOverrideM))" }
        return s
    }

    /// What happened to one pin (`ReplayResult.pinSnaps`): relative metres
    /// only, no position and no road identity.
    public struct Record: Hashable, Sendable, Codable {
        /// The fix's `t`, session seconds.
        public var t: Double
        public var mapSpanM: Double?
        /// `edge`, `node`, `ambiguous`, `noEdgeInRadius` or `noNetwork`.
        public var result: String
        /// `PinSnap.Decision` for `edge` / `node`.
        public var decision: String?
        /// What the engine got: `snapped`, `raw` (the tap) or `zoomIn` (the
        /// app would have refused it; the engine still gets the raw tap, as
        /// the recording has the pin).
        public var placement: String
        /// Raw tap → snapped point, metres (`edge` / `node`).
        public var snapDistanceM: Double?
        /// Raw tap → snapped point, metres east and north (`edge` / `node`):
        /// relative, so the pin's place is not in the record.
        public var snapEastM: Double?
        public var snapNorthM: Double?
        public var radiusM: Double
        /// An `edge` snap on another edge than the one nearest the tap (the
        /// cloud chose it).
        public var differsFromNearest: Bool?
        /// Roads weighed by the ambiguity rule (0: it was not needed).
        public var contested: Int
        /// The largest distance between two contested snapped points,
        /// metres; nil when fewer than two.
        public var contestedSpreadM: Double?
    }

    /// The sample the engine gets and the record, for a pin whose prior
    /// engine is `engine`.
    public func apply(_ sample: ManualFixSample, at t: MonotonicTimestamp, engine: NavigationEngine) -> (sample: ManualFixSample, record: Record) {
        let tap = (latitude: sample.truthLatitude, longitude: sample.truthLongitude)
        let network = engine.roadNetwork
        let span = spanOverrideM ?? sample.mapSpanM
        let outcome = PinSnap.snap(latitude: tap.latitude, longitude: tap.longitude, mapSpanM: span,
                                   viewportHeightPt: viewportHeightPt, network: network,
                                   cloud: network == nil ? nil : engine.pinSnapCloud(), parameters: parameters)
        let placement = PinSnap.placement(tapLatitude: tap.latitude, tapLongitude: tap.longitude,
                                          mapSpanM: span, result: outcome.result, parameters: parameters)
        var given = sample
        let placementName: String
        switch placement {
        case .place(let latitude, let longitude, let tapLatitude, let tapLongitude):
            given.latitude = latitude
            given.longitude = longitude
            given.tapLatitude = tapLatitude
            given.tapLongitude = tapLongitude
            placementName = tapLatitude == nil ? "raw" : "snapped"
        case .zoomIn:
            given.latitude = tap.latitude
            given.longitude = tap.longitude
            given.tapLatitude = nil
            given.tapLongitude = nil
            placementName = "zoomIn"
        }
        let resultName: String
        var differs: Bool?
        switch outcome.result {
        case .edge(let s):
            resultName = "edge"
            differs = outcome.nearest.map { $0.edge != s.candidate.edge }
        case .node: resultName = "node"
        case .ambiguous: resultName = "ambiguous"
        case .noEdgeInRadius: resultName = "noEdgeInRadius"
        case .noNetwork: resultName = "noNetwork"
        }
        var spread: Double?
        if outcome.contested.count >= 2 {
            var worst = 0.0
            for (i, a) in outcome.contested.enumerated() {
                let plane = LocalTangentPlane(latitude: a.latitude, longitude: a.longitude)
                for b in outcome.contested[(i + 1)...] {
                    let d = plane.enu(latitude: b.latitude, longitude: b.longitude)
                    worst = max(worst, (d.east * d.east + d.north * d.north).squareRoot())
                }
            }
            spread = worst
        }
        let offset = outcome.result.snap.map { snap in
            LocalTangentPlane(latitude: tap.latitude, longitude: tap.longitude)
                .enu(latitude: snap.latitude, longitude: snap.longitude)
        }
        let record = Record(
            t: t.seconds, mapSpanM: span, result: resultName,
            decision: outcome.result.snap?.decision.rawValue, placement: placementName,
            snapDistanceM: outcome.result.snap?.distanceM, snapEastM: offset?.east, snapNorthM: offset?.north,
            radiusM: outcome.radiusM,
            differsFromNearest: differs, contested: outcome.contested.count, contestedSpreadM: spread
        )
        return (given, record)
    }
}
