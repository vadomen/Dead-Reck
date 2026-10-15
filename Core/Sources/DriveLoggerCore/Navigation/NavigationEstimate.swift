import Foundation

/// What `NavigationEngine` believes at one instant.
public struct NavigationEstimate: Hashable, Sendable {
    /// The time the estimate is for (session clock).
    public var t: MonotonicTimestamp
    /// Weighted mean position in the engine's local plane, metres.
    /// Plane-relative: the plane re-anchors at the cloud's mean once that is
    /// more than `NavigationConfig.reanchorDistanceM` from the anchor, and
    /// these values then jump by about that much while the position does
    /// not move. Consumers (map, sidecar) should use `latitude`/`longitude`.
    public var east: Double
    public var north: Double
    /// The same position in WGS-84 degrees.
    public var latitude: Double
    public var longitude: Double
    /// Circular mean heading of travel, degrees clockwise from north, [0, 360).
    public var headingDeg: Double
    /// Circular standard deviation of the heading, degrees.
    public var headingStdDeg: Double
    /// 95 % position ellipse. Past the extrapolation horizon it grows
    /// (see `NavigationEngine.estimate(at:)`); it never shrinks with `t`.
    public var ellipse: ErrorEllipse
    /// Mean speed over the last prediction step, m/s (0 when stopped).
    public var speedMps: Double
    /// OBD speed scale factor: mean and standard deviation.
    public var speedScaleMean: Double
    public var speedScaleStd: Double
    /// Effective sample size of the particle cloud, 1…N.
    public var effectiveSampleSize: Double
    /// Heading std under `NavigationConfig.convergedHeadingStdDeg`. While
    /// false the app shows "calibrating heading".
    public var converged: Bool
    /// The last prediction step was frozen: a zero-velocity update (fresh
    /// OBD 0) or a parked stale step (OBD stale after an OBD 0, with no IMU
    /// sign of motion since).
    public var stationary: Bool
    /// Σ wᵢ rᵢ of the last road update: the share of the cloud on a mapped
    /// road (N3.2). 0 after an attempt that found no road near the cloud;
    /// nil without roads, before the first attempt, and while the cloud is
    /// too wide for roads to engage.
    public var onRoadShare: Double? = nil
    /// The edge with the largest Σ wᵢ rᵢ in the last road update; nil
    /// whenever `onRoadShare` is nil or 0.
    public var matchedEdge: MatchedRoadEdge? = nil
}

/// An edge of a `RoadNetwork`: the pack (canonical order, ascending
/// content hash), the edge index in it and its OSM way.
public struct MatchedRoadEdge: Hashable, Sendable, Codable {
    public var pack: Int
    public var edge: Int
    public var osmWayID: Int64

    public init(pack: Int, edge: Int, osmWayID: Int64) {
        self.pack = pack
        self.edge = edge
        self.osmWayID = osmWayID
    }
}

/// A 95 % confidence ellipse: semi-axes `√(5.991 λ)` of the position
/// covariance's eigenvalues.
public struct ErrorEllipse: Hashable, Sendable {
    public var semiMajorM: Double
    public var semiMinorM: Double
    /// Bearing of the major axis, degrees clockwise from north, [0, 180).
    public var orientationDeg: Double

    /// χ² with 2 degrees of freedom at 95 %.
    public static let chiSquare95 = 5.991

    public init(semiMajorM: Double, semiMinorM: Double, orientationDeg: Double) {
        self.semiMajorM = semiMajorM
        self.semiMinorM = semiMinorM
        self.orientationDeg = orientationDeg
    }

    /// The ellipse of a 2×2 covariance [[ee, en], [en, nn]] (east/north, m²).
    public init(covarianceEE ee: Double, en: Double, nn: Double) {
        let mean = (ee + nn) / 2
        let radius = (((ee - nn) / 2) * ((ee - nn) / 2) + en * en).squareRoot()
        let major = max(mean + radius, 0)
        let minor = max(mean - radius, 0)
        // Angle of the major axis from east, counter-clockwise.
        let theta = 0.5 * atan2(2 * en, ee - nn)
        var bearing = 90 - theta * 180 / .pi
        bearing = bearing.truncatingRemainder(dividingBy: 180)
        if bearing < 0 { bearing += 180 }
        self.init(
            semiMajorM: (Self.chiSquare95 * major).squareRoot(),
            semiMinorM: (Self.chiSquare95 * minor).squareRoot(),
            orientationDeg: bearing
        )
    }

    /// Whether a point (east/north offset from the ellipse centre, metres)
    /// lies inside.
    public func contains(dEast: Double, dNorth: Double) -> Bool {
        let b = orientationDeg * .pi / 180
        // Unit vector of the major axis in east/north.
        let ue = sin(b), un = cos(b)
        let along = dEast * ue + dNorth * un
        let across = -dEast * un + dNorth * ue
        guard semiMajorM > 0 else { return along == 0 && across == 0 }
        let minor = max(semiMinorM, 1e-9)
        return (along / semiMajorM) * (along / semiMajorM) + (across / minor) * (across / minor) <= 1
    }
}

/// Running counts of what the engine did with its input, for replay reports.
public struct NavigationCounters: Hashable, Sendable, Codable {
    /// 10 Hz prediction steps since initialisation.
    public var steps = 0
    /// Steps frozen by a zero-velocity update.
    public var zuptSteps = 0
    /// Steps with stale OBD speed (unknown speed).
    public var staleSpeedSteps = 0
    /// Stale steps frozen as parked: after an OBD 0, no motion since.
    public var staleParkedSteps = 0
    public var fixesUsed = 0
    /// Fixes without a valid speed (cell tower, Wi-Fi).
    public var networkFixesUsed = 0
    /// Stale fixes (older than `maxFixAgeS`) not used: rejected on arrival
    /// while fresh OBD said the car was moving, from before the car's last
    /// motion (`staleFixesIgnoredMoved`), or held and then dropped
    /// (`heldFixesDroppedMoving`, `heldFixesDroppedTimeout`,
    /// `heldFixesReplaced`).
    public var fixesIgnoredStale = 0
    /// Stale fixes that arrived while the car was stopped but whose fix time
    /// is before the end of the last moving step: the car moved after the
    /// fix, and the ~10 s motion history cannot be trusted to shift it
    /// (R11.1-5). Included in `fixesIgnoredStale`.
    public var staleFixesIgnoredMoved = 0
    /// Stale fixes held because OBD could not yet say whether the car was
    /// stopped (N4B-1). Each one ends used, dropped, or still held when the
    /// input ends (`NavigationEngine.hasHeldFix`).
    public var fixesHeld = 0
    /// Held fixes applied once a fresh OBD 0 arrived (also in `fixesUsed`).
    public var heldFixesUsed = 0
    /// Held fixes dropped because the deciding OBD reply said moving.
    public var heldFixesDroppedMoving = 0
    /// Held fixes dropped because no deciding OBD reply came within
    /// `NavigationConfig.heldFixTimeoutS`.
    public var heldFixesDroppedTimeout = 0
    /// Stale fixes dropped because only one is held: the older of two.
    public var heldFixesReplaced = 0
    public var fixesIgnoredInvalid = 0
    public var courseUpdates = 0
    public var speedUpdates = 0
    public var reseeds = 0
    public var manualFixes = 0
    public var manualResets = 0
    /// Manual fixes ingested after grid steps beyond their own `t` (the
    /// app's double-tap pin, written when its undo window closes; R14.3-1).
    /// Included in `manualFixes`. 0 in arrival order.
    public var lateManualFixes = 0
    /// Late manual fixes older than the per-particle ring
    /// (`lateManualFixWindowS`): shifted by the cloud's mean motion, or,
    /// for an initialising one, given the isotropic gap allowance.
    public var lateManualFixesMeanShift = 0
    public var resamples = 0
    /// Times the local plane moved to the cloud's mean (R13.1-3).
    public var reanchors = 0
    /// Grid steps caught up in bulk after a long silence of every input,
    /// not one by one (R13.1-6): parked stretches folded, and unknown-speed
    /// stretches run as macro steps. Included in `steps`. 0 on ordinary
    /// input.
    public var coalescedSteps = 0
    /// Macro prediction steps (each one pass over the particles) run for
    /// the unknown-speed part of `coalescedSteps`.
    public var macroSteps = 0
    /// Inputs rejected as implausible forward time jumps (B0-1): more than
    /// `NavigationConfig.maxForwardJumpS` after the latest accepted input.
    /// 0 on every acceptance drive.
    public var inputsRejectedTimeJump = 0

    // Roads (N3.2). All 0 without a road network.

    /// Road updates that ran (Steps 1–5), pin anchors included.
    public var roadUpdates = 0
    /// Road update attempts skipped because no particle's mean was within
    /// `roadSearchRadiusM` of any segment (a car park, outside the pack):
    /// exact no-ops.
    public var roadUpdatesNoRoad = 0
    /// Particle Gaussians split before matching (Step 1).
    public var roadSplits = 0
    /// Segment candidates tested against particles: a deterministic work
    /// measure.
    public var roadCandidateTests = 0
    /// Candidates refused by the level rule (a bridge over the street the
    /// particle is on, or the street under its bridge).
    public var roadLevelBlocked = 0
    /// GNSS fixes ignored as a whole because no road near them fits while
    /// the cloud is on a road at speed.
    public var fixesRejectedOffRoad = 0
    /// Road updates forced by a moving pin.
    public var roadPinAnchors = 0

    /// The road counters' coding keys: the only keys a comparison against a
    /// pre-N3.2 `metrics.json` may treat as 0 when missing.
    public static let roadCounterKeys = [
        "roadUpdates", "roadUpdatesNoRoad", "roadSplits", "roadCandidateTests", "roadLevelBlocked",
        "fixesRejectedOffRoad", "roadPinAnchors",
    ]

    public init() {}
}

extension NavigationCounters {
    private enum CodingKeys: String, CodingKey {
        case steps, zuptSteps, staleSpeedSteps, staleParkedSteps, fixesUsed, networkFixesUsed, fixesIgnoredStale
        case fixesHeld, heldFixesUsed, heldFixesDroppedMoving, heldFixesDroppedTimeout, heldFixesReplaced
        case staleFixesIgnoredMoved
        case fixesIgnoredInvalid, courseUpdates, speedUpdates, reseeds, manualFixes, manualResets, resamples
        case lateManualFixes, lateManualFixesMeanShift
        case reanchors, coalescedSteps, macroSteps, inputsRejectedTimeJump
        case roadUpdates, roadUpdatesNoRoad, roadSplits, roadCandidateTests, roadLevelBlocked
        case fixesRejectedOffRoad, roadPinAnchors
    }

    /// Decodes counters written by any earlier build: a counter it did not
    /// have is 0, so `replay_nav` can merge older `metrics.json` runs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        self.init()
        steps = try value(.steps)
        zuptSteps = try value(.zuptSteps)
        staleSpeedSteps = try value(.staleSpeedSteps)
        staleParkedSteps = try value(.staleParkedSteps)
        fixesUsed = try value(.fixesUsed)
        networkFixesUsed = try value(.networkFixesUsed)
        fixesIgnoredStale = try value(.fixesIgnoredStale)
        fixesHeld = try value(.fixesHeld)
        heldFixesUsed = try value(.heldFixesUsed)
        heldFixesDroppedMoving = try value(.heldFixesDroppedMoving)
        heldFixesDroppedTimeout = try value(.heldFixesDroppedTimeout)
        heldFixesReplaced = try value(.heldFixesReplaced)
        staleFixesIgnoredMoved = try value(.staleFixesIgnoredMoved)
        fixesIgnoredInvalid = try value(.fixesIgnoredInvalid)
        courseUpdates = try value(.courseUpdates)
        speedUpdates = try value(.speedUpdates)
        reseeds = try value(.reseeds)
        manualFixes = try value(.manualFixes)
        manualResets = try value(.manualResets)
        lateManualFixes = try value(.lateManualFixes)
        lateManualFixesMeanShift = try value(.lateManualFixesMeanShift)
        resamples = try value(.resamples)
        reanchors = try value(.reanchors)
        coalescedSteps = try value(.coalescedSteps)
        macroSteps = try value(.macroSteps)
        inputsRejectedTimeJump = try value(.inputsRejectedTimeJump)
        roadUpdates = try value(.roadUpdates)
        roadUpdatesNoRoad = try value(.roadUpdatesNoRoad)
        roadSplits = try value(.roadSplits)
        roadCandidateTests = try value(.roadCandidateTests)
        roadLevelBlocked = try value(.roadLevelBlocked)
        fixesRejectedOffRoad = try value(.fixesRejectedOffRoad)
        roadPinAnchors = try value(.roadPinAnchors)
    }
}
