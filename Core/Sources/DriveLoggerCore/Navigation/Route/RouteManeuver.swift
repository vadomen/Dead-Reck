import Foundation

/// What the driver does at the end of a route step.
///
/// A MapKit route step carries text only, so Core computes the maneuver from the
/// polyline's geometry (`RouteManeuver.computed`). From geometry alone it
/// yields `depart`, `arrive`, `straight`, the slight/normal/sharp turns and
/// `uTurn`; `roundaboutExit`, `merge` and `exitRamp` need road context from
/// the pack (`RouteManeuverRoadContext`, filled by item C's route-to-roads
/// matcher).
///
/// The raw names are on disk (`steps[].maneuver`): never change one. An
/// unknown name decodes to `.unknown` and keeps its string. Equality and
/// hashing go by `rawName` and `exitNumber`, so `.unknown("left")` equals
/// `.left`.
public enum RouteManeuver: Sendable, CustomStringConvertible {
    case depart
    case straight
    case slightLeft, left, sharpLeft
    case slightRight, right, sharpRight
    case uTurn
    /// `exit`: 1-based exit number counted from the entry, when known.
    case roundaboutExit(exit: Int?)
    case merge
    case exitRamp
    case arrive
    /// A maneuver this build does not know; the raw name is kept.
    case unknown(String)

    /// The on-disk name, without the exit number.
    public var rawName: String {
        switch self {
        case .depart: "depart"
        case .straight: "straight"
        case .slightLeft: "slightLeft"
        case .left: "left"
        case .sharpLeft: "sharpLeft"
        case .slightRight: "slightRight"
        case .right: "right"
        case .sharpRight: "sharpRight"
        case .uTurn: "uTurn"
        case .roundaboutExit: "roundaboutExit"
        case .merge: "merge"
        case .exitRamp: "exitRamp"
        case .arrive: "arrive"
        case .unknown(let name): name
        }
    }

    /// The exit number of a `roundaboutExit`, else nil.
    public var exitNumber: Int? {
        if case .roundaboutExit(let exit) = self { return exit }
        return nil
    }

    /// Parses an on-disk name. Nil when `exitNumber` is given on a known
    /// maneuver other than `roundaboutExit` (malformed). On an unknown name
    /// the exit number is ignored.
    public init?(rawName: String, exitNumber: Int? = nil) {
        let parsed: RouteManeuver = switch rawName {
        case "depart": .depart
        case "straight": .straight
        case "slightLeft": .slightLeft
        case "left": .left
        case "sharpLeft": .sharpLeft
        case "slightRight": .slightRight
        case "right": .right
        case "sharpRight": .sharpRight
        case "uTurn": .uTurn
        case "roundaboutExit": .roundaboutExit(exit: exitNumber)
        case "merge": .merge
        case "exitRamp": .exitRamp
        case "arrive": .arrive
        default: .unknown(rawName)
        }
        switch parsed {
        case .roundaboutExit, .unknown: break
        default: if exitNumber != nil { return nil }
        }
        self = parsed
    }

    public var description: String {
        exitNumber.map { "\(rawName)(\($0))" } ?? rawName
    }
}

extension RouteManeuver: Hashable {
    public static func == (lhs: RouteManeuver, rhs: RouteManeuver) -> Bool {
        lhs.rawName == rhs.rawName && lhs.exitNumber == rhs.exitNumber
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawName)
        hasher.combine(exitNumber)
    }
}

/// Every threshold of the geometric maneuver rule, in one place.
///
/// **Turn angle** at a vertex (`RoutePolyline.turnDegrees`): the change of
/// bearing between an incoming chord, from `chordLengthM` to `junctionGapM`
/// before the vertex, and an outgoing chord, from `junctionGapM` to
/// `chordLengthM` after it (distances along the polyline). The gap skips the
/// junction itself: a corner drawn as several short segments, or a U-turn
/// across a median up to `junctionGapM` wide, reads as the change between
/// the roads on either side. 40/20 m: a city corner's arc (radius about
/// 10 m) fits in the gap, and 40 m stays short of the next junction on most
/// grids. On the R1 spike's MapKit routes this read 53 of 60 "turn left /
/// right" steps as a normal or sharp turn to the correct side (plain 30 m
/// chords from the vertex: 49). A U-turn that MapKit draws as a loop of
/// 40–60 m through a turnaround still reads as a left turn, not `uTurn`
/// (2 of 7 found; 30 m chords: 1); the instruction text stays authoritative.
///
/// **Classes** of |angle|, each bound the inclusive lower bound of the next
/// class: below `straightBelowDegrees` straight; below `slightBelowDegrees`
/// slight; below `normalBelowDegrees` normal; below `sharpBelowDegrees`
/// sharp; else U-turn. The sign gives the side: positive = right
/// (clockwise seen from above, like a compass bearing).
public struct RouteManeuverThresholds: Hashable, Sendable {
    public var chordLengthM: Double
    public var junctionGapM: Double
    public var straightBelowDegrees: Double
    public var slightBelowDegrees: Double
    public var normalBelowDegrees: Double
    public var sharpBelowDegrees: Double

    public init(
        chordLengthM: Double = 40,
        junctionGapM: Double = 20,
        straightBelowDegrees: Double = 20,
        slightBelowDegrees: Double = 45,
        normalBelowDegrees: Double = 120,
        sharpBelowDegrees: Double = 160
    ) {
        self.chordLengthM = chordLengthM
        self.junctionGapM = junctionGapM
        self.straightBelowDegrees = straightBelowDegrees
        self.slightBelowDegrees = slightBelowDegrees
        self.normalBelowDegrees = normalBelowDegrees
        self.sharpBelowDegrees = sharpBelowDegrees
    }

    public static let standard = RouteManeuverThresholds()
}

/// Road context at a maneuver vertex, from the route matched onto the pack
/// graph (item C). With no context the maneuver comes from the angle only.
///
/// Rules (`RouteManeuver.classify`): `roundabout` gives `roundaboutExit`
/// with `roundaboutExit` as its exit number; leaving a main road onto a
/// link (`highway=*_link`) at less than a normal turn gives `exitRamp`;
/// leaving a link onto a main road at less than a normal turn gives
/// `merge`. A sharper angle stays a turn.
public struct RouteManeuverRoadContext: Hashable, Sendable {
    public var incomingIsLink: Bool
    public var outgoingIsLink: Bool
    public var roundabout: Bool
    public var roundaboutExit: Int?

    public init(incomingIsLink: Bool = false, outgoingIsLink: Bool = false, roundabout: Bool = false, roundaboutExit: Int? = nil) {
        self.incomingIsLink = incomingIsLink
        self.outgoingIsLink = outgoingIsLink
        self.roundabout = roundabout
        self.roundaboutExit = roundaboutExit
    }
}

extension RouteManeuver {
    /// The maneuver for a turn of `turnDegrees` (positive = right), refined
    /// by road context when there is one. Never `depart`/`arrive`.
    public static func classify(
        turnDegrees: Double,
        road: RouteManeuverRoadContext? = nil,
        thresholds: RouteManeuverThresholds = .standard
    ) -> RouteManeuver {
        let magnitude = abs(turnDegrees)
        if let road {
            if road.roundabout { return .roundaboutExit(exit: road.roundaboutExit) }
            if magnitude < thresholds.normalBelowDegrees {
                if road.outgoingIsLink, !road.incomingIsLink { return .exitRamp }
                if road.incomingIsLink, !road.outgoingIsLink { return .merge }
            }
        }
        let right = turnDegrees > 0
        if magnitude < thresholds.straightBelowDegrees { return .straight }
        if magnitude < thresholds.slightBelowDegrees { return right ? .slightRight : .slightLeft }
        if magnitude < thresholds.normalBelowDegrees { return right ? .right : .left }
        if magnitude < thresholds.sharpBelowDegrees { return right ? .sharpRight : .sharpLeft }
        return .uTurn
    }

    /// The maneuver at polyline vertex `vertex`: `depart` at the first
    /// vertex, `arrive` at the last, otherwise from the turn angle there.
    /// Throws `stepOutOfBounds(stepIndex: -1)` for a vertex outside the
    /// polyline.
    public static func atVertex(
        _ vertex: Int,
        of polyline: RoutePolyline,
        road: RouteManeuverRoadContext? = nil,
        thresholds: RouteManeuverThresholds = .standard
    ) throws -> RouteManeuver {
        guard polyline.points.indices.contains(vertex) else { throw RouteError.stepOutOfBounds(stepIndex: -1) }
        if vertex == 0 { return .depart }
        if vertex == polyline.points.count - 1 { return .arrive }
        let angle = polyline.turnDegrees(
            atVertex: vertex, chordLengthM: thresholds.chordLengthM, junctionGapM: thresholds.junctionGapM
        )
        return classify(turnDegrees: angle, road: road, thresholds: thresholds)
    }

    /// One maneuver per step range, at each range's last vertex (the
    /// `RouteStep` convention). `roadContexts[i]` (when present) refines
    /// step `i`; a shorter array leaves the rest angle-only. Throws
    /// `stepOutOfBounds` for a range outside the polyline. This is the hook
    /// item C's matcher fills.
    public static func computed(
        polyline: RoutePolyline,
        stepRanges: [ClosedRange<Int>],
        roadContexts: [RouteManeuverRoadContext?] = [],
        thresholds: RouteManeuverThresholds = .standard
    ) throws -> [RouteManeuver] {
        try stepRanges.enumerated().map { index, range in
            guard range.lowerBound >= 0, range.upperBound < polyline.points.count else {
                throw RouteError.stepOutOfBounds(stepIndex: index)
            }
            let road = index < roadContexts.count ? roadContexts[index] : nil
            return try atVertex(range.upperBound, of: polyline, road: road, thresholds: thresholds)
        }
    }
}
