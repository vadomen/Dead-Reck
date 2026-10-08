import DriveLoggerCore
import Foundation

/// How trustworthy a fix is, from its horizontal accuracy in metres.
enum AccuracyBand: Int, Hashable, Sendable, CaseIterable {
    /// 15 m or better.
    case good
    /// Up to 100 m.
    case fair
    /// Up to 1000 m.
    case poor
    /// Worse than 1000 m.
    case bad

    /// nil for negative or non-finite accuracy (the fix is invalid).
    init?(accuracy: Double) {
        guard accuracy.isFinite, accuracy >= 0 else { return nil }
        switch accuracy {
        case ...15: self = .good
        case ...100: self = .fair
        case ...1000: self = .poor
        default: self = .bad
        }
    }

    var label: String {
        switch self {
        case .good: "good"
        case .fair: "fair"
        case .poor: "poor"
        case .bad: "bad"
        }
    }
}

/// One accepted fix of the displayed track.
struct TrackPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var band: AccuracyBand
    /// Fix time on the session clock (`receivedT - ageS`), the same `t` the
    /// fix has in the log.
    var t: Double
    /// True when the line must not be drawn from the previous point to this one.
    var segmentStart: Bool
}

/// Consecutive points of one segment and one accuracy band.
struct TrackRun: Hashable, Sendable {
    var band: AccuracyBand
    var points: [TrackPoint]
}

/// The thinned, bounded track shown on the map. Display only: it never feeds
/// the recorder. Pure value type so it is testable without MapKit.
struct GPSTrack: Sendable, Equatable {
    static let maxPoints = 1800
    static let initialMinInterval = 2.0
    /// A jump in fix time larger than this starts a new segment.
    static let gapSeconds = 30.0

    private(set) var points: [TrackPoint] = []
    /// Cached; recomputed only when `points` changes.
    private(set) var runs: [TrackRun] = []
    private(set) var minInterval = GPSTrack.initialMinInterval
    /// Fix-time jump that starts a new segment. Grows with the spacing so a
    /// thinned long drive is not cut at every point.
    var gapThreshold: Double { max(Self.gapSeconds, 2 * minInterval) }

    /// Time of the last fix seen, accepted or not, for dedupe by fix time.
    private var lastSeenT: Double?

    init() {}

    /// Adds a fix when it is valid, newer than the last one seen, and at
    /// least `minInterval` after the last accepted point. A fix without
    /// `receivedT` is ignored (live fixes always carry it).
    mutating func append(_ fix: LocationSample) {
        guard let received = fix.receivedT,
              fix.latitude.isFinite, fix.longitude.isFinite,
              abs(fix.latitude) <= 90, abs(fix.longitude) <= 180,
              let band = AccuracyBand(accuracy: fix.horizontalAccuracy)
        else { return }
        let t = received.seconds - (fix.ageS ?? 0)
        guard t.isFinite else { return }
        // Same fix re-delivered by the 1 Hz tick, or an older one: skip.
        if let lastSeenT, t <= lastSeenT { return }
        lastSeenT = t
        var segmentStart = false
        if let last = points.last {
            let dt = t - last.t
            if dt < minInterval { return }
            segmentStart = dt > gapThreshold
        } else {
            segmentStart = true
        }
        points.append(TrackPoint(
            latitude: fix.latitude, longitude: fix.longitude,
            accuracy: fix.horizontalAccuracy, band: band,
            t: t, segmentStart: segmentStart
        ))
        if points.count >= Self.maxPoints { halve() }
        runs = computeRuns()
    }

    /// Keeps every other point, always the first and the last, and doubles
    /// the spacing so the whole drive stays within the cap.
    private mutating func halve() {
        let lastIndex = points.count - 1
        var kept: [TrackPoint] = []
        kept.reserveCapacity(points.count / 2 + 1)
        // A dropped point that started a segment passes the flag on, so a
        // gap is never bridged by a line.
        var pending = false
        for (i, var p) in points.enumerated() {
            if i % 2 == 0 || i == lastIndex {
                p.segmentStart = p.segmentStart || pending
                pending = false
                kept.append(p)
            } else {
                pending = pending || p.segmentStart
            }
        }
        points = kept
        minInterval *= 2
    }

    /// Points grouped by segment and band. A run starts with the previous
    /// run's last point (within a segment) so the line is continuous.
    private func computeRuns() -> [TrackRun] {
        var result: [TrackRun] = []
        for p in points {
            if p.segmentStart || result.isEmpty {
                result.append(TrackRun(band: p.band, points: [p]))
            } else if result[result.count - 1].band == p.band {
                result[result.count - 1].points.append(p)
            } else {
                let previous = result[result.count - 1].points[result[result.count - 1].points.count - 1]
                result.append(TrackRun(band: p.band, points: [previous, p]))
            }
        }
        return result
    }
}
