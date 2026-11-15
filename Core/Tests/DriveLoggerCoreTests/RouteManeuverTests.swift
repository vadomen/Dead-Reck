import Foundation
import Testing

@testable import DriveLoggerCore

/// Maneuvers computed from route geometry (prompt 51 item B): the angle
/// classes and their thresholds, chords over a densified corner, the
/// MapKit-style step convention, and the road-context hook for item C.
/// Synthetic polylines only.
@Suite("Route maneuvers (prompt 51 B)")
struct RouteManeuverTests {
    typealias F = RouteFixture

    @Test("Angle classes and their boundaries (lower bound inclusive)", arguments: [
        (0.0, RouteManeuver.straight), (19.99, .straight), (-19.99, .straight),
        (20, .slightRight), (-20, .slightLeft), (44.99, .slightRight),
        (45, .right), (-45, .left), (119.99, .right), (-119.99, .left),
        (120, .sharpRight), (-120, .sharpLeft), (159.99, .sharpRight), (-159.99, .sharpLeft),
        (160, .uTurn), (-160, .uTurn), (180, .uTurn),
    ])
    func classes(angle: Double, expected: RouteManeuver) {
        #expect(RouteManeuver.classify(turnDegrees: angle) == expected)
    }

    @Test("The thresholds are the documented defaults")
    func defaults() {
        let t = RouteManeuverThresholds.standard
        #expect(t.chordLengthM == 40 && t.junctionGapM == 20)
        #expect([t.straightBelowDegrees, t.slightBelowDegrees, t.normalBelowDegrees, t.sharpBelowDegrees]
            == [20, 45, 120, 160])
        // Custom thresholds are honoured.
        let wide = RouteManeuverThresholds(straightBelowDegrees: 30)
        #expect(RouteManeuver.classify(turnDegrees: 25, thresholds: wide) == .straight)
    }

    @Test("Road context: roundabout, exit ramp and merge; a sharper angle stays a turn")
    func roadContext() {
        let roundabout = RouteManeuverRoadContext(roundabout: true, roundaboutExit: 2)
        #expect(RouteManeuver.classify(turnDegrees: 90, road: roundabout) == .roundaboutExit(exit: 2))
        #expect(RouteManeuver.classify(turnDegrees: -10, road: RouteManeuverRoadContext(roundabout: true))
            == .roundaboutExit(exit: nil))
        let ramp = RouteManeuverRoadContext(outgoingIsLink: true)
        #expect(RouteManeuver.classify(turnDegrees: 25, road: ramp) == .exitRamp)
        #expect(RouteManeuver.classify(turnDegrees: 119.99, road: ramp) == .exitRamp)
        #expect(RouteManeuver.classify(turnDegrees: 120, road: ramp) == .sharpRight)
        let merge = RouteManeuverRoadContext(incomingIsLink: true)
        #expect(RouteManeuver.classify(turnDegrees: -15, road: merge) == .merge)
        #expect(RouteManeuver.classify(turnDegrees: -130, road: merge) == .sharpLeft)
        // Link to link, or main road to main road: the angle decides.
        let linkToLink = RouteManeuverRoadContext(incomingIsLink: true, outgoingIsLink: true)
        #expect(RouteManeuver.classify(turnDegrees: 30, road: linkToLink) == .slightRight)
        #expect(RouteManeuver.classify(turnDegrees: 30, road: RouteManeuverRoadContext()) == .slightRight)
    }

    @Test("Turn angle at a vertex: sign is right-positive, magnitude matches the geometry", arguments: [
        F.equator, F.south,
    ])
    func turnAngles(origin: (latitude: Double, longitude: Double)) throws {
        // North 100, east 100 (right 90), north-east 100 (left 45), south 100 (right 135).
        let d = 100 / 2.0.squareRoot()
        let line = try RoutePolyline(F.points(
            [(0, 0), (0, 100), (100, 100), (100 + d, 100 + d), (100 + d, d)], origin: origin
        ))
        #expect(abs(line.turnDegrees(atVertex: 1, chordLengthM: 30) - 90) < 0.01)
        #expect(abs(line.turnDegrees(atVertex: 2, chordLengthM: 30) + 45) < 0.01)
        #expect(abs(line.turnDegrees(atVertex: 3, chordLengthM: 30) - 135) < 0.01)
        // End vertices have no turn.
        #expect(line.turnDegrees(atVertex: 0, chordLengthM: 30) == 0)
        #expect(line.turnDegrees(atVertex: 4, chordLengthM: 30) == 0)
    }

    @Test("A corner drawn as several short segments reads as one turn through the chords")
    func densifiedCorner() throws {
        // A right-angle corner with radius 8 m drawn as four 22.5° pieces;
        // the step boundary sits on the first arc vertex.
        var offsets: [(east: Double, north: Double)] = [(0, 0), (0, 100)]
        let r = 8.0
        for k in 1...4 {
            let a = Double(k) * .pi / 8
            offsets.append((r - r * cos(a), 100 + r * sin(a)))
        }
        offsets.append((r + 100, 100 + r))
        let line = try RoutePolyline(F.points(offsets))
        // One arc vertex alone turns only 22.5°: the chords see the corner.
        let angle = line.turnDegrees(atVertex: 1, chordLengthM: 30)
        #expect(angle > 60 && angle < 100, "angle \(angle)")
        #expect(try RouteManeuver.atVertex(1, of: line) == .right)
        // With the junction gap the chords miss the arc: the full 90°.
        #expect(abs(line.turnDegrees(atVertex: 1, chordLengthM: 40, junctionGapM: 20) - 90) < 0.5)
        // With a 1 m chord the same vertex is a slight bend.
        #expect(abs(line.turnDegrees(atVertex: 1, chordLengthM: 1) - 11.25) < 0.5)
    }

    @Test("A U-turn across a median up to the junction gap wide; without the gap it reads as sharp", arguments: [
        5.0, 15, 20,
    ])
    func uTurn(medianM: Double) throws {
        let line = try RoutePolyline(F.points([(0, 0), (0, 200), (medianM, 200), (medianM, 0)]))
        let angle = line.turnDegrees(atVertex: 1, chordLengthM: 40, junctionGapM: 20)
        #expect(abs(angle) >= 160, "angle \(angle)")
        #expect(try RouteManeuver.atVertex(1, of: line) == .uTurn)
        if medianM >= 15 {
            #expect(abs(line.turnDegrees(atVertex: 1, chordLengthM: 30)) < 160)
        }
    }

    @Test("A vertex within the junction gap of the start falls back to the chord up to the vertex")
    func nearStart() throws {
        // A right turn 10 m after the start.
        let line = try RoutePolyline(F.points([(0, 0), (0, 10), (100, 10)]))
        #expect(abs(line.turnDegrees(atVertex: 1, chordLengthM: 40, junctionGapM: 20) - 90) < 0.01)
        #expect(try RouteManeuver.atVertex(1, of: line) == .right)
        // And 10 m before the end.
        let end = try RoutePolyline(F.points([(0, 0), (0, 100), (10, 100)]))
        #expect(abs(end.turnDegrees(atVertex: 1, chordLengthM: 40, junctionGapM: 20) - 90) < 0.01)
    }

    @Test("Maneuvers per step range, at each range's last vertex: depart, turns, arrive")
    func computed() throws {
        // North, east (right 90), bearing 60 (slight left 30), north (left 60).
        let e = 100 * sin(Double.pi / 3), n = 100 * cos(Double.pi / 3)
        let line = try RoutePolyline(F.points(
            [(0, 0), (0, 100), (0, 200), (100, 200), (100 + e, 200 + n), (100 + e, 300 + n), (100 + e, 400 + n)]
        ))
        let ranges = [0...0, 0...2, 2...3, 3...4, 4...6]
        let maneuvers = try RouteManeuver.computed(polyline: line, stepRanges: ranges)
        #expect(maneuvers == [.depart, .right, .slightLeft, .left, .arrive])
        // A straight-through vertex is straight.
        #expect(try RouteManeuver.atVertex(1, of: line) == .straight)
        // Road context refines one step; a short context array leaves the rest angle-only.
        let refined = try RouteManeuver.computed(
            polyline: line, stepRanges: ranges,
            roadContexts: [nil, nil, nil, RouteManeuverRoadContext(outgoingIsLink: true)]
        )
        #expect(refined == [.depart, .right, .slightLeft, .exitRamp, .arrive])
        // depart/arrive are not overridden by context.
        let ends = try RouteManeuver.computed(
            polyline: line, stepRanges: [0...0, 4...6],
            roadContexts: [RouteManeuverRoadContext(roundabout: true), RouteManeuverRoadContext(roundabout: true)]
        )
        #expect(ends == [.depart, .arrive])
        #expect(throws: RouteError.stepOutOfBounds(stepIndex: 1)) {
            try RouteManeuver.computed(polyline: line, stepRanges: [0...1, 2...7])
        }
        #expect(throws: RouteError.stepOutOfBounds(stepIndex: -1)) { try RouteManeuver.atVertex(7, of: line) }
    }

    @Test("Duplicate points at a vertex do not make a turn")
    func duplicates() throws {
        let points = F.points([(0, 0), (0, 0), (0, 100)])
        let line = try RoutePolyline(points)
        #expect(line.turnDegrees(atVertex: 1, chordLengthM: 30) == 0)
    }
}
