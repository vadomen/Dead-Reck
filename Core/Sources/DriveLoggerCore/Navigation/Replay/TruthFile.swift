import Foundation

/// Ground-truth positions for replayed drives, read at runtime from a
/// git-ignored JSON file (`logs/truth.json`), never from the repository.
///
/// Keyed by recording file name. Each entry may hold an `end` position (where
/// the car stood at the last sample), `points` at session-clock times,
/// `excludePins`: manual fixes of the recording that are not scored as truth
/// (the engine still receives them), and `scoreUntilT`: the session-clock
/// time after which nothing is scored (the engine still ingests every input
/// after it). Unknown keys (notes, future fields) are ignored:
///
/// ```json
/// { "<file name>": {
///     "end": { "latitude": …, "longitude": …, "sigmaM": 30, "source": "…" },
///     "points": [ { "t": 744.3, "latitude": …, "longitude": …, "sigmaM": 30, "source": "…" } ],
///     "excludePins": [ { "t": 100.25, "reason": "…" } ],
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

        public init(end: Position? = nil, points: [Point]? = nil, excludePins: [ExcludedPin]? = nil,
                    scoreUntilT: Double? = nil) {
            self.end = end
            self.points = points
            self.excludePins = excludePins
            self.scoreUntilT = scoreUntilT
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
