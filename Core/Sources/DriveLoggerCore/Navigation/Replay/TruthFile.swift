import Foundation

/// Ground-truth positions for replayed drives, read at runtime from a
/// git-ignored JSON file (`logs/truth.json`), never from the repository.
///
/// Keyed by recording file name. Each entry may hold an `end` position (where
/// the car stood at the last sample), `points` at session-clock times,
/// `excludePins`: manual fixes of the recording that are not scored as truth
/// (the engine still receives them), `excludeFixes`: session-clock ranges
/// whose location fixes are never truth (scoring only, like the others),
/// and `scoreUntilT`: the session-clock time after which nothing is scored
/// (the engine still ingests every input after it). Unknown keys (notes,
/// future fields) are ignored. A malformed entry (a wrong type, an
/// `excludeFixes` range with `fromT` > `toT` or a non-finite bound) makes
/// the whole file fail to decode:
///
/// ```json
/// { "<file name>": {
///     "end": { "latitude": …, "longitude": …, "sigmaM": 30, "source": "…" },
///     "points": [ { "t": 744.3, "latitude": …, "longitude": …, "sigmaM": 30, "source": "…" } ],
///     "excludePins": [ { "t": 100.25, "reason": "…" } ],
///     "excludeFixes": [ { "fromT": 0.0, "toT": 251.0, "reason": "…" } ],
///     "scoreUntilT": 1500.0,
///     "note": "…" } }
/// ```
public struct TruthFile: Hashable, Sendable {
    public struct Position: Hashable, Sendable, Codable {
        public var latitude: Double
        public var longitude: Double
        public var sigmaM: Double?
        public var source: String?

        public init(latitude: Double, longitude: Double, sigmaM: Double? = nil, source: String? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.sigmaM = sigmaM
            self.source = source
        }
    }

    public struct Point: Hashable, Sendable, Codable {
        /// Session-clock seconds (the event `t`).
        public var t: Double
        public var latitude: Double
        public var longitude: Double
        public var sigmaM: Double?
        public var source: String?

        public init(t: Double, latitude: Double, longitude: Double, sigmaM: Double? = nil, source: String? = nil) {
            self.t = t
            self.latitude = latitude
            self.longitude = longitude
            self.sigmaM = sigmaM
            self.source = source
        }
    }

    /// A manual fix that is not scored as ground truth, matched by its event
    /// `t` (session-clock seconds) within `excludePinToleranceS`. The engine
    /// still ingests it: this is a scoring decision only.
    public struct ExcludedPin: Hashable, Sendable, Codable {
        public var t: Double
        public var reason: String?

        public init(t: Double, reason: String? = nil) {
            self.t = t
            self.reason = reason
        }
    }

    /// How far an `excludePins` `t` may be from the manual fix's `t`. 0.1 s
    /// lets a `t` written to one decimal match, and is a tenth of the closest
    /// pin spacing in the replay set (0.95 s, a refinement pair), so it never
    /// reaches a neighbouring pin. Each entry excludes the nearest pin in
    /// range (the earlier one on a tie).
    public static let excludePinToleranceS = 0.1

    /// A session-clock range whose location fixes are never ground truth:
    /// a fix whose event `t` satisfies `fromT` ≤ t ≤ `toT` (inclusive,
    /// compared in whole nanoseconds as `MonotonicTimestamp(seconds:)`
    /// rounds them) is neither a clean-fix checkpoint (in any GPS mode) nor
    /// a clean fix of the offline road truth (residuals, wrong road,
    /// unmapped). Scoring only: whether the engine receives the fix still
    /// follows the GPS mode exactly as without the range. Manual fixes in
    /// the range are not affected (`excludePins` is for them).
    ///
    /// Decoding refuses `fromT` > `toT` and a non-finite bound
    /// (`DecodingError.dataCorrupted`), as for any malformed truth file; a
    /// range built in code with such bounds matches no fix.
    public struct ExcludedFixRange: Hashable, Sendable, Codable {
        public var fromT: Double
        public var toT: Double
        public var reason: String?

        public init(fromT: Double, toT: Double, reason: String? = nil) {
            self.fromT = fromT
            self.toT = toT
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case fromT, toT, reason
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fromT = try c.decode(Double.self, forKey: .fromT)
            toT = try c.decode(Double.self, forKey: .toT)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            if let problem = problem {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "excludeFixes range: \(problem)"))
            }
        }

        /// Why the range is invalid, nil when it is valid.
        public var problem: String? {
            guard fromT.isFinite, toT.isFinite else { return "fromT \(fromT) and toT \(toT) must be finite" }
            guard fromT <= toT else { return "fromT \(fromT) is after toT \(toT)" }
            return nil
        }

        /// Whether a fix at event time `t` is in the range (inclusive); false
        /// for an invalid range.
        public func contains(_ t: MonotonicTimestamp) -> Bool {
            guard problem == nil else { return false }
            return t.nanoseconds >= MonotonicTimestamp(seconds: fromT).nanoseconds
                && t.nanoseconds <= MonotonicTimestamp(seconds: toT).nanoseconds
        }
    }

    public struct Entry: Hashable, Sendable, Codable {
        public var end: Position?
        public var points: [Point]?
        /// Manual fixes not scored as truth; optional so older files decode.
        public var excludePins: [ExcludedPin]?
        /// Scoring cutoff, session-clock seconds: a checkpoint of any kind
        /// (withheld clean fix, manual fix, truth point, the `end` at the
        /// last input) whose `t` is after it is listed but not scored; one
        /// exactly at it is scored. Scoring only: the engine ingests every
        /// input as without it. Optional so older files decode; nil scores
        /// the whole recording.
        public var scoreUntilT: Double?
        /// Location fixes that are never truth, by event-time range
        /// (`ExcludedFixRange`). Optional so older files decode; nil or
        /// empty: every fix is as without it.
        public var excludeFixes: [ExcludedFixRange]?

        public init(end: Position? = nil, points: [Point]? = nil, excludePins: [ExcludedPin]? = nil,
                    scoreUntilT: Double? = nil, excludeFixes: [ExcludedFixRange]? = nil) {
            self.end = end
            self.points = points
            self.excludePins = excludePins
            self.scoreUntilT = scoreUntilT
            self.excludeFixes = excludeFixes
        }

        /// Whether a location fix at event time `t` is excluded from truth.
        public func excludesFix(at t: MonotonicTimestamp) -> Bool {
            excludeFixes?.contains { $0.contains(t) } ?? false
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    public init(data: Data) throws {
        entries = try JSONDecoder().decode([String: Entry].self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// The entry for a recording, by file name (`Drive_….jsonl.gz`), also
    /// matching a key written without the `.jsonl.gz` / `.jsonl` extension.
    public func entry(forLog fileName: String) -> Entry? {
        if let entry = entries[fileName] { return entry }
        let stem = Self.stem(fileName)
        // Sorted so a (malformed) file with two matching keys still resolves
        // the same way on every run.
        return entries.keys.sorted().first { Self.stem($0) == stem }.flatMap { entries[$0] }
    }

    static func stem(_ name: String) -> String {
        for suffix in [".jsonl.gz", ".jsonl"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
