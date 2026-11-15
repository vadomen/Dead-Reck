import Foundation

/// One step of a route: the stretch of polyline leading up to a maneuver.
///
/// **Range convention.** `polylineRange` is `from...to`, both inclusive
/// polyline indices. The step covers the travel from vertex `from` to vertex
/// `to`, and its maneuver (and `instruction`) happens at its **last** vertex
/// `to` (`maneuverVertex`). That is how MapKit's route steps behave: on the R1
/// spike's routes the turn angle at a step's last vertex matched the
/// direction of its instruction. So the first step is usually a single point
/// (`from == to == 0`, `depart`) and the last step ends at the route's end
/// (`arrive`). Consecutive steps may share their boundary vertex.
///
/// JSON keys (part of the log format): `distanceM`, `from`, `instruction`,
/// `maneuver`, `to`, and `exitNumber` only on a `roundaboutExit` with a known
/// exit number (or on an unknown maneuver that was read with one).
public struct RouteStep: Hashable, Sendable {
    /// The provider's text, as given; may be empty.
    public let instruction: String
    /// The provider's step length in metres.
    public let distanceM: Double
    /// Inclusive polyline index bounds, `from...to`.
    public let polylineRange: ClosedRange<Int>
    public let maneuver: RouteManeuver

    public init(instruction: String, distanceM: Double, polylineRange: ClosedRange<Int>, maneuver: RouteManeuver) {
        self.instruction = instruction
        self.distanceM = distanceM
        self.polylineRange = polylineRange
        self.maneuver = maneuver
    }

    /// The vertex where this step's maneuver happens: its last vertex.
    public var maneuverVertex: Int { polylineRange.upperBound }

    /// Checks what can be checked without the polyline.
    func validate(stepIndex: Int) throws {
        guard distanceM.isFinite, distanceM >= 0 else { throw RouteError.invalidStepDistance(stepIndex: stepIndex) }
        guard polylineRange.lowerBound >= 0 else { throw RouteError.stepOutOfBounds(stepIndex: stepIndex) }
        if case .roundaboutExit(let exit?) = maneuver, exit < 1 {
            throw RouteError.invalidExitNumber(stepIndex: stepIndex)
        }
        // An exit number on a known name other than roundaboutExit, even
        // spelled as `.unknown`, could not be read back.
        if RouteManeuver(rawName: maneuver.rawName, exitNumber: maneuver.exitNumber) == nil {
            throw RouteError.invalidExitNumber(stepIndex: stepIndex)
        }
    }
}

extension RouteStep: Codable {
    enum CodingKeys: String, CodingKey {
        case instruction, distanceM, from, to, maneuver, exitNumber
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let from = try container.decode(Int.self, forKey: .from)
        let to = try container.decode(Int.self, forKey: .to)
        guard from <= to else {
            throw DecodingError.dataCorruptedError(
                forKey: .to, in: container, debugDescription: "Step range from \(from) is after to \(to)"
            )
        }
        let name = try container.decode(String.self, forKey: .maneuver)
        let exitNumber = try container.decodeIfPresent(Int.self, forKey: .exitNumber)
        guard let maneuver = RouteManeuver(rawName: name, exitNumber: exitNumber) else {
            throw DecodingError.dataCorruptedError(
                forKey: .exitNumber, in: container, debugDescription: "exitNumber on maneuver \(name)"
            )
        }
        self.init(
            instruction: try container.decode(String.self, forKey: .instruction),
            distanceM: try container.decode(Double.self, forKey: .distanceM),
            polylineRange: from...to,
            maneuver: maneuver
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instruction, forKey: .instruction)
        try container.encode(distanceM, forKey: .distanceM)
        try container.encode(polylineRange.lowerBound, forKey: .from)
        try container.encode(polylineRange.upperBound, forKey: .to)
        try container.encode(maneuver.rawName, forKey: .maneuver)
        try container.encodeIfPresent(maneuver.exitNumber, forKey: .exitNumber)
    }
}
