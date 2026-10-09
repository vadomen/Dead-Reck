import Foundation

/// Ground-truth positions for replayed drives, read at runtime from a
/// git-ignored JSON file (`logs/truth.json`), never from the repository.
///
/// Keyed by recording file name. Each entry may hold an `end` position (where
/// the car stood at the last sample) and/or `points` at session-clock times;
/// unknown keys (notes, future fields) are ignored:
///
/// ```json
/// { "<file name>": {
///     "end": { "latitude": …, "longitude": …, "sigmaM": 30, "source": "…" },
///     "points": [ { "t": 744.3, "latitude": …, "longitude": …, "sigmaM": 30, "source": "…" } ],
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

    public struct Entry: Hashable, Sendable, Codable {
        public var end: Position?
        public var points: [Point]?

        public init(end: Position? = nil, points: [Point]? = nil) {
            self.end = end
            self.points = points
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
