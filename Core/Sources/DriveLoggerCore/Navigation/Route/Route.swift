import Foundation

/// A driving route: the polyline to follow, the provider's steps, its length
/// and expected travel time (docs/ROUTING_PLAN.md, prompt 51 = R1).
///
/// The JSON form of a `Route` is part of the on-disk log format (the log's
/// `route` row embeds it, and `replay_nav --route <file.json>` reads the same
/// JSON), so its keys and raw strings never change:
///
/// ```json
/// {"distanceM":99.5,"expectedTravelTimeS":20,"id":"r1","label":"Home",
///  "polylineE7":[100000,-200000,4500,0,0,4500],"source":"synthetic",
///  "steps":[{"distanceM":0,"from":0,"instruction":"","maneuver":"depart","to":0},
///           {"distanceM":50,"from":0,"instruction":"Turn right","maneuver":"right","to":1},
///           {"distanceM":49.5,"from":1,"instruction":"Arrive","maneuver":"arrive","to":2}]}
/// ```
/// (one line on disk; this is `RouteCodingTests.smallJSON`.)
///
/// - `polylineE7`: integer degrees × 10⁷, latitude before longitude. The
///   first point is absolute, every later point is the delta from the point
///   before it. Deltas are plain integer differences (no wrap at ±180°).
/// - `steps[].from` / `to`: inclusive polyline index bounds; the step's
///   maneuver happens at `to` (`RouteStep`).
/// - `label` is omitted when nil. `steps[].exitNumber` appears only on a
///   `roundaboutExit` step whose exit number is known (`RouteStep`).
/// - Unknown `source` and `maneuver` strings decode to `.unknown` and keep
///   their string, so a route written by a newer build survives a re-export.
/// - Decoding rejects malformed input: an odd or short `polylineE7`, a
///   coordinate out of range, a step range out of bounds or out of order, a
///   negative or non-finite distance or time (`RouteError`).
///
/// Coordinates are fixed-point from the start (`RoutePoint` rounds to 1e-7°),
/// so encode → decode is an exact round trip and the bytes are stable under
/// `LogCodec`'s sorted keys. Size: a synthetic 700-point route with 50 m
/// spacing and 15 steps encodes to 9 325 bytes (`RouteCodingTests`).
public struct Route: Hashable, Sendable {
    /// Stable identifier, chosen by whoever built the route.
    public let id: String
    /// At least two points, in driving order.
    public let polyline: [RoutePoint]
    /// Ordered steps; see `RouteStep` for the range convention.
    public let steps: [RouteStep]
    /// The provider's route length in metres (not recomputed from the
    /// polyline; `RoutePolyline.lengthM` is the geometric length).
    public let distanceM: Double
    /// The provider's expected travel time in seconds.
    public let expectedTravelTimeS: Double
    public let source: RouteSource
    /// Optional destination label as the user saw it.
    public let label: String?

    /// Validates the route; see `RouteError` for what is rejected.
    ///
    /// Steps must be in order and may share only their boundary vertex:
    /// `steps[i].from >= steps[i-1].to`. They need not cover the whole
    /// polyline.
    public init(
        id: String,
        polyline: [RoutePoint],
        steps: [RouteStep],
        distanceM: Double,
        expectedTravelTimeS: Double,
        source: RouteSource,
        label: String? = nil
    ) throws {
        guard polyline.count >= 2 else { throw RouteError.tooFewPoints(polyline.count) }
        for (index, point) in polyline.enumerated() where !point.isValid {
            throw RouteError.coordinateOutOfRange(pointIndex: index)
        }
        guard distanceM.isFinite, distanceM >= 0 else { throw RouteError.invalidDistance }
        guard expectedTravelTimeS.isFinite, expectedTravelTimeS >= 0 else {
            throw RouteError.invalidTravelTime
        }
        var previousTo: Int?
        for (index, step) in steps.enumerated() {
            try step.validate(stepIndex: index)
            guard step.polylineRange.upperBound < polyline.count else {
                throw RouteError.stepOutOfBounds(stepIndex: index)
            }
            if let previousTo, step.polylineRange.lowerBound < previousTo {
                throw RouteError.stepsOutOfOrder(stepIndex: index)
            }
            previousTo = step.polylineRange.upperBound
        }
        self.id = id
        self.polyline = polyline
        self.steps = steps
        self.distanceM = distanceM
        self.expectedTravelTimeS = expectedTravelTimeS
        self.source = source
        self.label = label
    }
}

/// A WGS-84 position in fixed point: integer degrees × 10⁷ (about 1.1 cm of
/// latitude). Rounding happens once, here, so a route's coordinates survive
/// any number of encode/decode round trips unchanged.
public struct RoutePoint: Hashable, Sendable {
    public let latE7: Int32
    public let lonE7: Int32

    /// Unchecked; `Route.init` rejects a point outside ±90° / ±180°.
    public init(latE7: Int32, lonE7: Int32) {
        self.latE7 = latE7
        self.lonE7 = lonE7
    }

    /// Rounds to the nearest 1e-7° (ties away from zero). Nil for a
    /// non-finite value or one outside ±90° latitude / ±180° longitude
    /// (e.g. an invalid provider coordinate).
    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let lat = (latitude * 1e7).rounded()
        let lon = (longitude * 1e7).rounded()
        guard abs(lat) <= Double(Self.maxLatE7), abs(lon) <= Double(Self.maxLonE7) else { return nil }
        self.init(latE7: Int32(lat), lonE7: Int32(lon))
    }

    public var latitude: Double { Double(latE7) / 1e7 }
    public var longitude: Double { Double(lonE7) / 1e7 }

    static let maxLatE7: Int64 = 900_000_000
    static let maxLonE7: Int64 = 1_800_000_000

    var isValid: Bool {
        abs(Int64(latE7)) <= Self.maxLatE7 && abs(Int64(lonE7)) <= Self.maxLonE7
    }
}

/// Where a route came from. The raw strings are on disk: never change one.
/// Equality and hashing go by `rawValue`, so `.unknown("appleMaps")` equals
/// `.appleMaps`; build values with `init(rawValue:)` to get the canonical case.
public enum RouteSource: Sendable, CustomStringConvertible {
    /// Apple Maps directions, through the app's adapter (prompt 52).
    case appleMaps
    /// Built by a tool or a test (e.g. `replay_nav --route-from-truth`).
    case synthetic
    /// A source this build does not know; the string is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "appleMaps": self = .appleMaps
        case "synthetic": self = .synthetic
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .appleMaps: "appleMaps"
        case .synthetic: "synthetic"
        case .unknown(let value): value
        }
    }

    public var description: String { rawValue }
}

extension RouteSource: Hashable {
    public static func == (lhs: RouteSource, rhs: RouteSource) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

extension RouteSource: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why a route (or its JSON) was rejected.
public enum RouteError: Error, Hashable, Sendable {
    case tooFewPoints(Int)
    case coordinateOutOfRange(pointIndex: Int)
    /// `polylineE7` has an odd number of integers.
    case oddPolylineArray(count: Int)
    case invalidDistance
    case invalidTravelTime
    case invalidStepDistance(stepIndex: Int)
    /// `from > to`, `from < 0` or `to` past the last point.
    case stepOutOfBounds(stepIndex: Int)
    /// The step starts before the previous step's last vertex.
    case stepsOutOfOrder(stepIndex: Int)
    /// An exit number below 1, or on a known maneuver other than
    /// `roundaboutExit`.
    case invalidExitNumber(stepIndex: Int)
}

// MARK: - Coding

extension Route: Codable {
    enum CodingKeys: String, CodingKey {
        case id, polylineE7, steps, distanceM, expectedTravelTimeS, source, label
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let packed = try container.decode([Int64].self, forKey: .polylineE7)
        do {
            try self.init(
                id: container.decode(String.self, forKey: .id),
                polyline: Self.unpack(polylineE7: packed),
                steps: container.decode([RouteStep].self, forKey: .steps),
                distanceM: container.decode(Double.self, forKey: .distanceM),
                expectedTravelTimeS: container.decode(Double.self, forKey: .expectedTravelTimeS),
                source: container.decode(RouteSource.self, forKey: .source),
                label: container.decodeIfPresent(String.self, forKey: .label)
            )
        } catch let error as RouteError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid route: \(error)", underlyingError: error
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Self.pack(polyline), forKey: .polylineE7)
        try container.encode(steps, forKey: .steps)
        try container.encode(distanceM, forKey: .distanceM)
        try container.encode(expectedTravelTimeS, forKey: .expectedTravelTimeS)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(label, forKey: .label)
    }

    /// `[lat0, lon0, dLat1, dLon1, …]`: the first point absolute, then
    /// deltas from the previous point.
    static func pack(_ points: [RoutePoint]) -> [Int64] {
        var out: [Int64] = []
        out.reserveCapacity(points.count * 2)
        var previous: RoutePoint?
        for point in points {
            if let previous {
                out.append(Int64(point.latE7) - Int64(previous.latE7))
                out.append(Int64(point.lonE7) - Int64(previous.lonE7))
            } else {
                out.append(Int64(point.latE7))
                out.append(Int64(point.lonE7))
            }
            previous = point
        }
        return out
    }

    static func unpack(polylineE7 packed: [Int64]) throws -> [RoutePoint] {
        guard packed.count % 2 == 0 else { throw RouteError.oddPolylineArray(count: packed.count) }
        var points: [RoutePoint] = []
        points.reserveCapacity(packed.count / 2)
        var lat: Int64 = 0, lon: Int64 = 0
        for index in 0..<(packed.count / 2) {
            // A delta big enough to overflow cannot lead to a valid point.
            let (newLat, latOverflow) = lat.addingReportingOverflow(packed[2 * index])
            let (newLon, lonOverflow) = lon.addingReportingOverflow(packed[2 * index + 1])
            guard !latOverflow, !lonOverflow,
                  abs(newLat) <= RoutePoint.maxLatE7, abs(newLon) <= RoutePoint.maxLonE7
            else { throw RouteError.coordinateOutOfRange(pointIndex: index) }
            lat = newLat
            lon = newLon
            points.append(RoutePoint(latE7: Int32(lat), lonE7: Int32(lon)))
        }
        return points
    }
}
