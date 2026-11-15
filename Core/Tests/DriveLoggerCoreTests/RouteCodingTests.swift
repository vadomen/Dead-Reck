import Foundation
import Testing

@testable import DriveLoggerCore

/// The `Route` JSON is on-disk log format (prompt 51 item B): golden bytes,
/// exact round trips, forward compatibility and rejection of malformed input.
/// Synthetic routes only.
@Suite("Route JSON (prompt 51 B)")
struct RouteCodingTests {
    typealias F = RouteFixture

    /// Three points, hand-built so the expected bytes can be written out.
    static func small(label: String? = "Home") throws -> Route {
        let polyline = [
            RoutePoint(latE7: 100_000, lonE7: -200_000),
            RoutePoint(latE7: 104_500, lonE7: -200_000),
            RoutePoint(latE7: 104_500, lonE7: -195_500),
        ]
        return try Route(
            id: "r1", polyline: polyline,
            steps: [
                RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart),
                RouteStep(instruction: "Turn right", distanceM: 50, polylineRange: 0...1, maneuver: .right),
                RouteStep(instruction: "Arrive", distanceM: 49.5, polylineRange: 1...2, maneuver: .arrive),
            ],
            distanceM: 99.5, expectedTravelTimeS: 20, source: .synthetic, label: label
        )
    }

    static let smallJSON = #"{"distanceM":99.5,"expectedTravelTimeS":20,"id":"r1","label":"Home","#
        + #""polylineE7":[100000,-200000,4500,0,0,4500],"source":"synthetic","steps":["#
        + #"{"distanceM":0,"from":0,"instruction":"","maneuver":"depart","to":0},"#
        + #"{"distanceM":50,"from":0,"instruction":"Turn right","maneuver":"right","to":1},"#
        + #"{"distanceM":49.5,"from":1,"instruction":"Arrive","maneuver":"arrive","to":2}]}"#

    static func decode(_ json: String) throws -> Route {
        try JSONDecoder().decode(Route.self, from: Data(json.utf8))
    }

    @Test("Golden bytes: sorted keys, polylineE7 absolute then deltas, label present")
    func golden() throws {
        #expect(try F.string(Self.small()) == Self.smallJSON)
        #expect(try Self.decode(Self.smallJSON) == Self.small())
    }

    @Test("label is omitted when nil and decodes back to nil")
    func labelOmitted() throws {
        let json = try F.string(Self.small(label: nil))
        #expect(!json.contains("label"))
        #expect(try Self.decode(json).label == nil)
    }

    @Test("Encode → decode is exact and re-encoding is byte-identical, on a 700-point route")
    func roundTrip() throws {
        let route = try F.route(F.wandering(count: 700, spacingM: 50, turnEvery: 50),
                                breaks: Array(stride(from: 50, to: 700, by: 50)), id: "rt", label: "Somewhere")
        let first = try F.encode(route)
        let decoded = try JSONDecoder().decode(Route.self, from: first)
        #expect(decoded == route)
        #expect(decoded.polyline == route.polyline)
        #expect(try F.encode(decoded) == first)
    }

    @Test("Coordinates round to the nearest 1e-7 degree when a point is built; invalid ones give nil")
    func rounding() throws {
        let p = try #require(RoutePoint(latitude: 12.345_678_96, longitude: -98.765_432_14))
        #expect(p.latE7 == 123_456_790)
        #expect(p.lonE7 == -987_654_321)
        #expect(RoutePoint(latitude: 90, longitude: 180)?.lonE7 == 1_800_000_000)
        #expect(RoutePoint(latitude: 90.000_001, longitude: 0) == nil)
        #expect(RoutePoint(latitude: 0, longitude: -180.000_001) == nil)
        #expect(RoutePoint(latitude: .nan, longitude: 0) == nil)
        #expect(RoutePoint(latitude: 0, longitude: .infinity) == nil)
        // An invalid provider coordinate (-180, -180) is rejected.
        #expect(RoutePoint(latitude: -180, longitude: -180) == nil)
        // A rounded value survives a round trip unchanged.
        let route = try F.route([p, RoutePoint(latitude: 12.346, longitude: -98.765)!])
        #expect(try JSONDecoder().decode(Route.self, from: F.encode(route)).polyline[0] == p)
    }

    @Test("A roundabout exit number is written only when known, and decodes back")
    func roundaboutExit() throws {
        let points = [RoutePoint(latE7: 0, lonE7: 0), RoutePoint(latE7: 4500, lonE7: 0), RoutePoint(latE7: 9000, lonE7: 0)]
        func route(_ maneuver: RouteManeuver) throws -> Route {
            try Route(id: "x", polyline: points,
                      steps: [RouteStep(instruction: "", distanceM: 50, polylineRange: 0...1, maneuver: maneuver)],
                      distanceM: 100, expectedTravelTimeS: 10, source: .appleMaps)
        }
        let withExit = try F.string(route(.roundaboutExit(exit: 3)))
        #expect(withExit.contains(#""exitNumber":3,"from":0"#))
        #expect(withExit.contains(#""maneuver":"roundaboutExit""#))
        #expect(try Self.decode(withExit).steps[0].maneuver == .roundaboutExit(exit: 3))
        let without = try F.string(route(.roundaboutExit(exit: nil)))
        #expect(!without.contains("exitNumber"))
        #expect(try Self.decode(without).steps[0].maneuver == .roundaboutExit(exit: nil))
        #expect(throws: RouteError.invalidExitNumber(stepIndex: 0)) { try route(.roundaboutExit(exit: 0)) }
    }

    @Test("Unknown source and maneuver strings decode without throwing and survive re-encoding byte for byte")
    func unknownStrings() throws {
        let json = Self.smallJSON
            .replacingOccurrences(of: #""source":"synthetic""#, with: #""source":"futureMaps""#)
            .replacingOccurrences(of: #""maneuver":"right""#, with: #""maneuver":"keepRightFork""#)
        let route = try Self.decode(json)
        #expect(route.source == .unknown("futureMaps"))
        #expect(route.steps[1].maneuver == .unknown("keepRightFork"))
        #expect(try F.string(route) == json)
        // An exit number on an unknown maneuver is kept and re-exported byte for byte.
        let withExit = json.replacingOccurrences(
            of: #""from":0,"instruction":"Turn right""#, with: #""exitNumber":2,"from":0,"instruction":"Turn right""#
        )
        let read = try Self.decode(withExit)
        #expect(read.steps[1].maneuver == .unknown("keepRightFork", exitNumber: 2))
        #expect(read.steps[1].maneuver != .unknown("keepRightFork"))
        #expect(try F.string(read) == withExit)
        // Even an exit number this build would reject on a roundabout (0) survives on an unknown name.
        let zero = withExit.replacingOccurrences(of: #""exitNumber":2"#, with: #""exitNumber":0"#)
        #expect(try F.string(Self.decode(zero)) == zero)
        // Equality goes by raw string.
        #expect(RouteSource.unknown("appleMaps") == .appleMaps)
        #expect(RouteManeuver.unknown("left") == .left)
    }

    @Test("Equality and hashing agree for unknown spellings of known maneuvers; a known name decodes to its case")
    func unknownEqualsKnown() throws {
        let pairs: [(RouteManeuver, RouteManeuver)] = [
            (.unknown("left"), .left),
            (.unknown("roundaboutExit", exitNumber: 2), .roundaboutExit(exit: 2)),
            (.unknown("roundaboutExit"), .roundaboutExit(exit: nil)),
        ]
        for (a, b) in pairs {
            #expect(a == b && a.hashValue == b.hashValue, "\(a) vs \(b)")
            #expect(Set([a, b]).count == 1)
            // Encoded, the unknown spelling reads back as the known case.
            let read = try #require(RouteManeuver(rawName: a.rawName, exitNumber: a.exitNumber))
            switch read {
            case .unknown: Issue.record("\(a) read back as unknown")
            default: #expect(read == b)
            }
        }
        #expect(RouteManeuver.unknown("roundaboutExit", exitNumber: 2) != .roundaboutExit(exit: 3))
        #expect(RouteSource.unknown("synthetic").hashValue == RouteSource.synthetic.hashValue)
        // Through a route: an unknown spelling of a known name round-trips to the known case.
        let points = [RoutePoint(latE7: 0, lonE7: 0), RoutePoint(latE7: 4500, lonE7: 0)]
        func route(_ m: RouteManeuver) throws -> Route {
            try Route(id: "u", polyline: points,
                      steps: [RouteStep(instruction: "", distanceM: 50, polylineRange: 0...1, maneuver: m)],
                      distanceM: 50, expectedTravelTimeS: 5, source: .unknown("synthetic"))
        }
        let decoded = try JSONDecoder().decode(Route.self, from: F.encode(route(.unknown("roundaboutExit", exitNumber: 4))))
        if case .roundaboutExit(exit: 4) = decoded.steps[0].maneuver {} else { Issue.record("not decoded as roundaboutExit(4)") }
        if case .synthetic = decoded.source {} else { Issue.record("source not decoded as synthetic") }
        // An exit number on a known non-roundabout name cannot be written.
        #expect(throws: RouteError.invalidExitNumber(stepIndex: 0)) { try route(.unknown("left", exitNumber: 3)) }
    }

    @Test("The raw strings are frozen format")
    func frozenRawStrings() {
        let all: [RouteManeuver] = [
            .depart, .straight, .slightLeft, .left, .sharpLeft, .slightRight, .right, .sharpRight, .uTurn,
            .roundaboutExit(exit: nil), .merge, .exitRamp, .arrive,
        ]
        #expect(all.map(\.rawName) == [
            "depart", "straight", "slightLeft", "left", "sharpLeft", "slightRight", "right", "sharpRight", "uTurn",
            "roundaboutExit", "merge", "exitRamp", "arrive",
        ])
        for maneuver in all {
            #expect(RouteManeuver(rawName: maneuver.rawName) == maneuver)
            if case .unknown = RouteManeuver(rawName: maneuver.rawName)! { Issue.record("\(maneuver) parsed as unknown") }
        }
        #expect(RouteSource.appleMaps.rawValue == "appleMaps")
        #expect(RouteSource.synthetic.rawValue == "synthetic")
        if case .unknown = RouteSource(rawValue: "appleMaps") { Issue.record("appleMaps parsed as unknown") }
    }

    @Test("Malformed input is rejected on decode", arguments: [
        ("odd polylineE7", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[100000,-200000,4500,0,0]"#),
        ("one point", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[100000,-200000]"#),
        ("empty polyline", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[]"#),
        ("latitude past 90", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[100000,-200000,900000000,0,0,4500]"#),
        ("longitude past 180", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[100000,-200000,4500,0,0,1800200001]"#),
        ("overflowing delta", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[100000,-200000,9223372036854775807,0,0,4500]"#),
        ("fractional coordinate", #""polylineE7":[100000,-200000,4500,0,0,4500]"#, #""polylineE7":[100000,-200000,4500.5,0,0,4500]"#),
        ("step past the end", #""from":1,"instruction":"Arrive","maneuver":"arrive","to":2"#, #""from":1,"instruction":"Arrive","maneuver":"arrive","to":3"#),
        ("step from after to", #""from":1,"instruction":"Arrive","maneuver":"arrive","to":2"#, #""from":2,"instruction":"Arrive","maneuver":"arrive","to":1"#),
        ("negative from", #""from":0,"instruction":"","maneuver":"depart","to":0"#, #""from":-1,"instruction":"","maneuver":"depart","to":0"#),
        ("steps out of order", #""from":1,"instruction":"Arrive","maneuver":"arrive","to":2"#, #""from":0,"instruction":"Arrive","maneuver":"arrive","to":2"#),
        ("exit number on a turn", #""from":0,"instruction":"Turn right""#, #""exitNumber":2,"from":0,"instruction":"Turn right""#),
        ("negative distance", #""distanceM":99.5"#, #""distanceM":-1"#),
        ("negative step distance", #""distanceM":49.5"#, #""distanceM":-0.5"#),
        ("negative travel time", #""expectedTravelTimeS":20"#, #""expectedTravelTimeS":-20"#),
        ("missing steps", #","steps":["#, #","stepz":["#),
    ])
    func rejects(_ name: String, _ original: String, _ replacement: String) throws {
        #expect(Self.smallJSON.contains(original), "\(name): fixture text not found")
        let json = Self.smallJSON.replacingOccurrences(of: original, with: replacement)
        #expect(json != Self.smallJSON)
        #expect(throws: (any Error).self, "\(name)") { try Self.decode(json) }
    }

    @Test("Route.init rejects what decoding rejects")
    func initValidation() throws {
        let a = RoutePoint(latE7: 0, lonE7: 0), b = RoutePoint(latE7: 4500, lonE7: 0)
        func make(_ points: [RoutePoint], _ steps: [RouteStep] = [], distance: Double = 1, time: Double = 1) throws {
            _ = try Route(id: "", polyline: points, steps: steps, distanceM: distance, expectedTravelTimeS: time,
                          source: .synthetic)
        }
        #expect(throws: RouteError.tooFewPoints(1)) { try make([a]) }
        #expect(throws: RouteError.coordinateOutOfRange(pointIndex: 1)) {
            try make([a, RoutePoint(latE7: 900_000_001, lonE7: 0)])
        }
        #expect(throws: RouteError.invalidDistance) { try make([a, b], distance: .nan) }
        #expect(throws: RouteError.invalidTravelTime) { try make([a, b], time: .infinity) }
        let step = { (range: ClosedRange<Int>) in RouteStep(instruction: "", distanceM: 1, polylineRange: range, maneuver: .straight) }
        #expect(throws: RouteError.stepOutOfBounds(stepIndex: 0)) { try make([a, b], [step(0...2)]) }
        #expect(throws: RouteError.stepsOutOfOrder(stepIndex: 1)) { try make([a, b, a], [step(0...2), step(1...2)]) }
        #expect(throws: RouteError.invalidStepDistance(stepIndex: 0)) {
            try make([a, b], [RouteStep(instruction: "", distanceM: -1, polylineRange: 0...1, maneuver: .straight)])
        }
        // Shared boundary vertices and a gap between steps are fine.
        try make([a, b, a, b], [step(0...0), step(0...1), step(2...3)])
        // No steps at all is fine.
        try make([a, b])
    }

    @Test("Through LogCodec: a route row of a kind this build does not know survives read and re-export byte for byte")
    func throughLogCodec() throws {
        let route = try F.route(F.wandering(count: 40, spacingM: 50, turnEvery: 10), breaks: [10, 20, 30], label: "Dest")
        let data = try JSONDecoder().decode(JSONValue.self, from: F.encode(route))
        let codec = LogCodec()
        let event = LogEvent(
            timestamp: MonotonicTimestamp(nanoseconds: 1_000_000_000),
            payload: .unrecognized(kind: "routeCodingTestOnly", data: data)
        )
        let line = try codec.line(for: event)
        #expect(String(decoding: line, as: UTF8.self).contains(try F.string(route)))
        let read = try codec.event(from: line.dropLast())
        #expect(try codec.line(for: read) == line)
        guard case .unrecognized(_, let readData?) = read.payload else {
            Issue.record("payload not preserved")
            return
        }
        #expect(try JSONDecoder().decode(Route.self, from: F.encode(readData)) == route)
    }

    /// Size budget for a log row: a 30 km city route has about 600–750 points.
    /// Measured: a 700-point route with 50 m spacing and 15 steps (instructions
    /// of about 30 characters) encodes to 9 325 bytes, under the 10–12 KB target.
    @Test("A 700-point, 50 m spacing route with 15 steps encodes to at most 12 KB")
    func encodedSize() throws {
        let points = F.wandering(count: 700, spacingM: 50, turnEvery: 50)
        let route = try F.route(points, breaks: Array(stride(from: 50, to: 700, by: 50)), id: "size-test",
                                label: "Destination") { "Turn right onto Example Avenue \($0)" }
        #expect(route.steps.count == 15)
        let size = try F.encode(route).count
        #expect(size >= 8_000 && size <= 12_000, "encoded size \(size)")
    }
}
