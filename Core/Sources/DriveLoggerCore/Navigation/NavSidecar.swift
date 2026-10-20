import Foundation

/// The navigation sidecar `<recording>.nav.jsonl` (N4 B): what the live
/// navigation showed the driver, so `replay_nav --as-live --compare` can
/// prove a replay reproduces it. Path: `NavSidecarFile`. Format:
/// docs/NAV_SIDECAR.md.
///
/// Versioned on its own, separate from the log format: the logger never
/// reads or writes it. JSON Lines, one object per line, each with a `kind`:
/// - `header` (first line): sidecar version, session ID, seed, the config as
///   canonical JSON and its hash, the app build and its build configuration;
/// - `estimate`: one per second of session-clock time once the engine is
///   initialised, as `NavigationEngine.estimate(at:)` returned it at that
///   grid instant;
/// - `pin`: the estimate at a confirmed manual fix, the prior just before
///   the engine ingested it;
/// - `roads` (v2): written when a road network became active: when (`t`,
///   `afterInputs`) and which packs. A sidecar without it used no roads.
///   v3: once more each time the run extended its network to a larger set
///   (prompt 38), each line the whole set; v1 and v2 have at most one.
/// - `roadsSelection` (within v2, no bump): a road selection attempt, how it
///   ended and which pack files it saw, written when the outcome or the
///   candidates change; identical repeats are folded into one line with a
///   count (`RoadsSelectionLog`). Diagnostic, never compared.
///
/// Times are session-clock nanoseconds (`t`, like the log). Doubles are
/// written at full precision so a replay can match them bit for bit;
/// non-finite values as the strings "inf", "-inf", "nan".
public enum NavSidecar {
    /// The version `LiveNavigationRun` writes. A reader refuses a newer one.
    /// 2 (N3.3): the `roads` line and `Estimate.onRoadShare`; a v1 reader
    /// would skip the roads line and hide which packs the run used.
    /// 3 (prompt 38): several `roads` lines (a network extended mid-run),
    /// with increasing `afterInputs`, each a strict superset of the one
    /// before; a v2 reader would refuse the second as a duplicate.
    public static let version = 3

    public struct Header: Hashable, Sendable, Codable {
        public var sidecarVersion: Int
        /// The recording's `LogHeader.sessionID`.
        public var sessionID: UUID
        /// The engine's seed (`NavigationSeed.derive(header:)` in the app).
        public var seed: UInt64
        /// `NavigationConfig.hashHex` of the engine's config.
        public var configHash: String
        /// `NavigationConfig.canonicalJSON()` of the engine's config, as text.
        public var configJSON: String
        /// `CFBundleVersion` of the app that wrote the sidecar.
        public var appBuild: String
        /// The build configuration of the app that wrote the sidecar:
        /// `"debug"` or `"release"` (the app sets it from `#if DEBUG`), so
        /// `msPerStep` can be read correctly: it means something only in
        /// Release. An open string set. Optional, added within v1: nil for a
        /// sidecar written before it existed, or by a writer that does not
        /// know it (`replay_nav`). Not compared.
        public var buildConfiguration: String?

        /// The values the app writes in `buildConfiguration`.
        public static let debugBuild = "debug"
        public static let releaseBuild = "release"

        public init(sessionID: UUID, config: NavigationConfig, appBuild: String,
                    buildConfiguration: String? = nil) {
            sidecarVersion = NavSidecar.version
            self.sessionID = sessionID
            seed = config.seed
            configHash = config.hashHex
            configJSON = String(decoding: config.canonicalJSON(), as: UTF8.self)
            self.appBuild = appBuild
            self.buildConfiguration = buildConfiguration
        }
    }

    /// One estimate. The compared fields are everything but the two timing
    /// diagnostics and `droppedInputs`.
    public struct Estimate: Hashable, Sendable, Codable {
        public var t: MonotonicTimestamp
        /// WGS-84 degrees (not plane east/north, which jump at a re-anchor).
        public var latitude: Double
        public var longitude: Double
        public var headingDeg: Double
        public var headingStdDeg: Double
        /// The 95 % ellipse.
        public var semiMajorM: Double
        public var semiMinorM: Double
        public var orientationDeg: Double
        public var converged: Bool
        public var speedScale: Double
        /// Navigation inputs the live feed had dropped so far
        /// (`NavigationTap.droppedInputs`). 0 in a replay.
        public var droppedInputs: Int
        /// Engine time per 10 Hz step, ms: EMA and the largest so far.
        /// Diagnostics only; nil in a replay.
        public var msPerStep: Double?
        public var maxStepMs: Double?
        /// v2: `NavigationEstimate.onRoadShare`, the weight share on a road
        /// at the last road update; nil (key omitted) without roads or
        /// before the first road update, so a no-roads line is a v1 line.
        public var onRoadShare: Double?

        public init(_ estimate: NavigationEstimate, droppedInputs: Int = 0,
                    msPerStep: Double? = nil, maxStepMs: Double? = nil) {
            t = estimate.t
            latitude = estimate.latitude
            longitude = estimate.longitude
            headingDeg = estimate.headingDeg
            headingStdDeg = estimate.headingStdDeg
            semiMajorM = estimate.ellipse.semiMajorM
            semiMinorM = estimate.ellipse.semiMinorM
            orientationDeg = estimate.ellipse.orientationDeg
            converged = estimate.converged
            speedScale = estimate.speedScaleMean
            self.droppedInputs = droppedInputs
            self.msPerStep = msPerStep
            self.maxStepMs = maxStepMs
            onRoadShare = estimate.onRoadShare
        }

        public var ellipse: ErrorEllipse {
            ErrorEllipse(semiMajorM: semiMajorM, semiMinorM: semiMinorM, orientationDeg: orientationDeg)
        }
    }

    /// A confirmed manual fix and the estimate just before it was ingested.
    public struct Pin: Hashable, Sendable, Codable {
        /// The fix's `t` (its confirm time).
        public var t: MonotonicTimestamp
        /// Where the driver put the pin.
        public var latitude: Double
        public var longitude: Double
        public var mapSpanM: Double?
        /// The engine's estimate at `t` before the pin; nil when the pin
        /// initialised the engine.
        public var prior: Estimate?

        public init(_ sample: ManualFixSample, at t: MonotonicTimestamp, prior: Estimate?) {
            self.t = t
            latitude = sample.latitude
            longitude = sample.longitude
            mapSpanM = sample.mapSpanM
            self.prior = prior
        }
    }

    /// v2: the road network a run attached, written when it became active
    /// (N3.3); v3: again at each extension to a larger set, each line the
    /// whole set (prompt 38). Data: © OpenStreetMap contributors, ODbL 1.0.
    public struct Roads: Hashable, Sendable, Codable {
        /// One pack, as `replay_nav` results record it: hashes as 16
        /// lowercase hex digits.
        public struct Pack: Hashable, Sendable, Codable {
            public var contentHash: String
            public var formatVersion: Int
            /// The OSM data's replication timestamp, Unix seconds (0 unknown).
            public var osmTimestamp: Int64
            public var gridID: String

            public init(contentHash: String, formatVersion: Int, osmTimestamp: Int64, gridID: String) {
                self.contentHash = contentHash
                self.formatVersion = formatVersion
                self.osmTimestamp = osmTimestamp
                self.gridID = gridID
            }

            public init(_ pack: RoadPack) {
                self.init(contentHash: NavigationSeed.hex(pack.contentHash), formatVersion: Int(pack.formatVersion),
                          osmTimestamp: pack.osmTimestamp, gridID: NavigationSeed.hex(pack.gridID))
            }
        }

        /// The engine's latest accepted arrival at the attach
        /// (`RoadAttachment.t`); nil (key omitted) for an attach before the
        /// first input.
        public var t: MonotonicTimestamp?
        /// Inputs the run had ingested before the attach: the network is
        /// used from input `afterInputs + 1` (1-based, file order) on.
        public var afterInputs: Int
        /// Per pack, in canonical order (ascending content hash).
        public var roads: [Pack]
        /// FNV-1a 64 over the packs' content hashes in ascending order, 16
        /// hex digits (`RoadNetwork.roadSetHashHex`).
        public var roadSetHash: String

        public init(t: MonotonicTimestamp?, afterInputs: Int, roads: [Pack], roadSetHash: String) {
            self.t = t
            self.afterInputs = afterInputs
            self.roads = roads
            self.roadSetHash = roadSetHash
        }

        public init(_ attachment: RoadAttachment) {
            self.init(t: attachment.t, afterInputs: attachment.afterInputs,
                      roads: attachment.network.packs.map(Pack.init), roadSetHash: attachment.network.roadSetHashHex)
        }
    }

    /// One road selection attempt and how it ended (diagnostic, within v2
    /// with no version bump; never compared), or a run of identical repeats
    /// of the line before it (`repeats`, `firstT`). Written where the
    /// outcome became known, so possibly some inputs after the request.
    /// An attempt `isRepeat(of:)` the last line written is counted, not
    /// written; the repeats are written as one line when an attempt differs,
    /// at an attach, and at the end (`RoadsSelectionLog`). Holds the
    /// request's radius but never its centre. Built by
    /// `RoadSelectionAttempt.line(recordedAfterInputs:)` through
    /// `LiveNavigationRun.finishSelection(_:emit:)` and
    /// `LiveNavigationRun.closingLines(inFlight:)`.
    /// Data: © OpenStreetMap contributors, ODbL 1.0.
    public struct RoadsSelection: Hashable, Sendable, Codable {
        /// What of the request is recorded: its radius only, no position.
        public struct Request: Hashable, Sendable, Codable {
            /// The request's 95 % semi-major axis, metres.
            public var radiusM: Double

            public init(radiusM: Double) {
                self.radiusM = radiusM
            }
        }

        /// A candidate's state. An open string set: a reader keeps a value
        /// it does not know.
        public struct State: RawRepresentable, Hashable, Sendable, Codable {
            public var rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }

            /// Verified and opened: selectable.
            public static let verified = State(rawValue: "verified")
            /// Refused when the packs were scanned or opened (`reason`).
            public static let refused = State(rawValue: "refused")
        }

        /// One pack file the selection knew about.
        public struct Candidate: Hashable, Sendable, Codable {
            /// The file name (`RoadPackSelection.Candidate.name`).
            public var name: String
            public var state: State
            /// Why it was refused; nil (omitted) when verified.
            public var reason: String?
            /// Verified only: its coverage intersects the request's circle
            /// (false for an unusable request); nil (omitted) when refused.
            public var covering: Bool?

            public init(name: String, state: State, reason: String? = nil, covering: Bool? = nil) {
                self.name = name
                self.state = state
                self.reason = reason
                self.covering = covering
            }
        }

        /// How an attempt ended. An open string set.
        public struct Outcome: RawRepresentable, Hashable, Sendable, Codable {
            public var rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }

            /// The covering packs were selected and attached (a `roads`
            /// line follows at once). `packs`: their names.
            public static let selected = Outcome(rawValue: "selected")
            /// Verified packs exist, none covers the circle.
            public static let noneCovering = Outcome(rawValue: "noneCovering")
            /// The covering set is not used: its network cannot be built,
            /// it was refused before (not built again), or the run refused
            /// the attach. `packs` and `reason`.
            public static let refused = Outcome(rawValue: "refused")
            /// The request's circle is unusable (non-finite or out of range).
            public static let unusableRequest = Outcome(rawValue: "unusableRequest")
            /// No verified pack at all (no file, or every file refused when
            /// scanned: `candidates` tells which).
            public static let noPacks = Outcome(rawValue: "noPacks")
            /// A network is attached and every covering pack is in it:
            /// nothing to add (v3, prompt 38). `packs`: the attached set.
            public static let noNewPacks = Outcome(rawValue: "noNewPacks")
            /// A network is attached and the set the covering packs would
            /// make is not a strict superset of it: the only new covering
            /// packs are newer versions of attached ones (they wait for the
            /// next start), or the run refused the extension as one
            /// (`RoadAttachRefusal.notSuperset`). `packs` and `reason` (v3).
            public static let notSuperset = Outcome(rawValue: "notSuperset")
            /// Still in flight when the recording ended; `candidates`
            /// omitted (not known).
            public static let unfinished = Outcome(rawValue: "unfinished")
        }

        /// The request's `t`: the engine's latest accepted arrival when it
        /// was raised (always after an input, so never omitted).
        public var t: MonotonicTimestamp
        /// The request's `afterInputs`: inputs handed to the run when it
        /// was raised.
        public var afterInputs: Int
        /// Inputs handed to the run when the outcome was recorded: where
        /// this line sits in the file, except for a line of repeats, which
        /// carries its last repeat's and is written later (at the next
        /// line or the end). ≥ `afterInputs`; equal for a synchronous
        /// selection (`replay_nav`).
        public var recordedAfterInputs: Int
        public var request: Request
        /// Per pack file, verified ones first (in candidate order), then
        /// those refused at the scan; nil (omitted) for `unfinished`.
        public var candidates: [Candidate]?
        public var outcome: Outcome
        /// The pack names involved, for `selected` and `refused`; nil
        /// (omitted) otherwise.
        public var packs: [String]?
        /// Why, for `refused`; nil (omitted) otherwise.
        public var reason: String?
        /// The attempts this line stands for, ≥ 2, when it folds a run of
        /// repeats (`RoadsSelectionLog`); nil (omitted) for one attempt.
        /// Every other field is the last repeat's; the repeats before it are
        /// the same attempt (`isRepeat(of:)`) and differ only in `t`, the
        /// input counts and the radius, which are not kept. Optional,
        /// within v2.
        public var repeats: Int?
        /// With `repeats`: the request `t` of the first of the attempts this
        /// line stands for (`t` is the last one's); nil (omitted) otherwise.
        /// Optional, within v2.
        public var firstT: MonotonicTimestamp?
        /// The request's `trigger` (v3, optional, diagnostic):
        /// `libraryChanged` or `coverageEntered`; nil (omitted) for the N3.3
        /// rule (initialisation, a position used without roads).
        public var trigger: RoadSelectionTrigger?

        public init(t: MonotonicTimestamp, afterInputs: Int, recordedAfterInputs: Int, request: Request,
                    candidates: [Candidate]?, outcome: Outcome, packs: [String]? = nil, reason: String? = nil,
                    repeats: Int? = nil, firstT: MonotonicTimestamp? = nil, trigger: RoadSelectionTrigger? = nil) {
            self.t = t
            self.afterInputs = afterInputs
            self.recordedAfterInputs = recordedAfterInputs
            self.request = request
            self.candidates = candidates
            self.outcome = outcome
            self.packs = packs
            self.reason = reason
            self.repeats = repeats
            self.firstT = firstT
            self.trigger = trigger
        }

        /// The attempts this line stands for: `repeats`, else 1.
        public var attempts: Int { max(repeats ?? 1, 1) }

        /// The same attempt as `other`: the same outcome, packs, reason,
        /// trigger and candidates (names, states, reasons and `covering`). The one
        /// definition of "same attempt", for writing (`RoadsSelectionLog`)
        /// and for folding rows in `replay_nav --compare`
        /// (`SidecarComparison.selectionRows`).
        public func isRepeat(of other: RoadsSelection) -> Bool {
            outcome == other.outcome && packs == other.packs && reason == other.reason
                && candidates == other.candidates && trigger == other.trigger
        }

        /// The attempt for `request`, still in flight when the run ended.
        public init(unfinished request: RoadSelectionRequest, recordedAfterInputs: Int) {
            self.init(t: request.t, afterInputs: request.afterInputs, recordedAfterInputs: recordedAfterInputs,
                      request: Request(radiusM: request.radiusM), candidates: nil, outcome: .unfinished,
                      trigger: request.trigger)
        }

        /// The refused pack set and why, for `refused`; else nil. What a
        /// caller remembers so the set is not built again.
        public var refusal: RoadPackSelection.Refusal? {
            outcome == .refused ? RoadPackSelection.Refusal(names: packs ?? [], reason: reason ?? "") : nil
        }

        /// One line for `replay_nav --compare`: "t 12.3 s after 45 inputs
        /// (recorded after 47), radius 1414 m: selected a.roadpack"; a line
        /// of repeats ends in "(×N, t a–b s)" (`firstT`, `t`).
        public var summary: String {
            var text = String(format: "t %.1f s after %d inputs", t.seconds, afterInputs)
            if recordedAfterInputs != afterInputs { text += " (recorded after \(recordedAfterInputs))" }
            text += String(format: ", radius %.0f m", request.radiusM)
            if let trigger { text += " (\(trigger.rawValue))" }
            text += ": " + outcome.rawValue
            if let packs, !packs.isEmpty { text += " " + packs.joined(separator: ", ") }
            if let reason { text += ": " + reason }
            if let candidates {
                let verified = candidates.filter { $0.state == .verified }
                let refused = candidates.filter { $0.state == .refused }
                text += " [\(verified.count) verified, \(verified.filter { $0.covering == true }.count) covering"
                if !refused.isEmpty {
                    text += "; refused: " + refused.map { "\($0.name) (\($0.reason ?? "no reason"))" }.joined(separator: ", ")
                }
                text += "]"
            }
            if attempts > 1 {
                text += String(format: " (×%d, t %.1f–%.1f s)", attempts, (firstT ?? t).seconds, t.seconds)
            }
            return text
        }
    }

    /// Which `roadsSelection` lines a run writes (within v2): the first
    /// attempt at once, then an attempt only when it is not a repeat
    /// (`RoadsSelection.isRepeat(of:)`) of the last line written. Repeats
    /// are counted and written as one line (the last repeat's, with
    /// `repeats` and `firstT`; a single repeat is a plain line) before the
    /// next line written, or by `flush()` at the end. `LiveNavigationRun`
    /// owns one, so the app and `replay_nav` write the same lines.
    public struct RoadsSelectionLog: Hashable, Sendable {
        /// The last line written; repeats are measured against it.
        public private(set) var lastWritten: RoadsSelection?
        /// The repeats counted since, as the line `flush()` would write.
        public private(set) var pending: RoadsSelection?
        /// Attempts recorded (`record`), the unfinished one included.
        public private(set) var attempts = 0
        /// Lines returned to write (`record` and `flush`).
        public private(set) var lines = 0

        public init() {}

        /// Records one attempt; returns the lines to write now, in order:
        /// none for a repeat, else the pending repeats' line (if any) and
        /// then `attempt`. `alwaysWrite`: write it even if it is a repeat
        /// (an attach, whose `roads` line must follow its own line).
        public mutating func record(_ attempt: RoadsSelection, alwaysWrite: Bool = false) -> [RoadsSelection] {
            attempts += 1
            if !alwaysWrite, let last = lastWritten, attempt.isRepeat(of: last) {
                if let earlier = pending {
                    var folded = attempt
                    folded.repeats = earlier.attempts + attempt.attempts
                    folded.firstT = earlier.firstT ?? earlier.t
                    pending = folded
                } else {
                    pending = attempt
                }
                return []
            }
            var out = flush().map { [$0] } ?? []
            out.append(attempt)
            lastWritten = attempt
            lines += 1
            return out
        }

        /// The pending repeats' line, if any, now (at the end of the run).
        public mutating func flush() -> RoadsSelection? {
            guard let line = pending else { return nil }
            pending = nil
            lines += 1
            return line
        }
    }

    public enum Line: Hashable, Sendable, Codable {
        case header(Header)
        case estimate(Estimate)
        case pin(Pin)
        /// v2.
        case roads(Roads)
        /// Within v2 (no bump): one road selection attempt, or a run of
        /// repeats of the line before it. Diagnostic.
        case roadsSelection(RoadsSelection)
        /// A kind this reader does not know (a later version); skipped.
        case unrecognized(kind: String)

        public var kind: String {
            switch self {
            case .header: "header"
            case .estimate: "estimate"
            case .pin: "pin"
            case .roads: "roads"
            case .roadsSelection: "roadsSelection"
            case .unrecognized(let kind): kind
            }
        }

        private enum Key: String, CodingKey { case kind }

        public init(from decoder: any Decoder) throws {
            let kind = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .kind)
            switch kind {
            case "header": self = .header(try Header(from: decoder))
            case "estimate": self = .estimate(try Estimate(from: decoder))
            case "pin": self = .pin(try Pin(from: decoder))
            case "roads": self = .roads(try Roads(from: decoder))
            case "roadsSelection": self = .roadsSelection(try RoadsSelection(from: decoder))
            default: self = .unrecognized(kind: kind)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .header(let value): try value.encode(to: encoder)
            case .estimate(let value): try value.encode(to: encoder)
            case .pin(let value): try value.encode(to: encoder)
            case .roads(let value): try value.encode(to: encoder)
            case .roadsSelection(let value): try value.encode(to: encoder)
            case .unrecognized: break
            }
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(kind, forKey: .kind)
        }
    }

    // MARK: Encoding

    /// Sorted keys, compact, non-finite numbers as strings.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// `line` as one JSON Lines line, newline included.
    public static func encode(_ line: Line, with encoder: JSONEncoder) throws -> Data {
        var data = try encoder.encode(line)
        data.append(0x0A)
        return data
    }

    // MARK: Reading

    public enum ReadError: Error, Hashable, Sendable {
        /// The first line is not a header.
        case missingHeader
        /// Written by a later version: guessing would give plausible but
        /// wrong numbers.
        case unsupportedVersion(Int)
        /// A line other than the last one does not decode (1-based number).
        case malformedLine(number: Int, description: String)
        /// A second `roads` line (1-based number) in a v1 or v2 sidecar: a
        /// run of those versions attaches roads once.
        case duplicateRoadsLine(number: Int)
        /// A later `roads` line (1-based number, v3) that does not extend
        /// the one before it: `afterInputs` decreases, or its packs are not
        /// a strict superset.
        case invalidRoadsLine(number: Int, reason: String)
    }

    public struct Contents: Hashable, Sendable {
        public var header: Header
        public var estimates: [Estimate]
        public var pins: [Pin]
        /// The `roads` lines in file order: none when the run used no roads
        /// (and always for v1), at most one for v2, and for v3 one per attach
        /// or extension, each a strict superset of the one before.
        public var roads: [Roads] = []
        /// The `roadsSelection` lines, in file order (a line may stand for
        /// several attempts: `RoadsSelection.attempts`); diagnostic, never
        /// compared.
        public var roadsSelections: [RoadsSelection] = []
        /// Lines of a kind this reader does not know, skipped.
        public var unrecognizedLines: Int
        /// The last line was cut short (the app was killed mid-write) and
        /// was dropped.
        public var truncatedLastLine: Bool

        /// The highest `droppedInputs` of any estimate: what the live feed
        /// had lost by the end of the sidecar.
        public var droppedInputs: Int { estimates.map(\.droppedInputs).max() ?? 0 }
    }

    public static func read(contentsOf url: URL) throws -> Contents {
        try read(Data(contentsOf: url))
    }

    /// Parses a sidecar. A last line that does not decode is dropped and
    /// reported (`truncatedLastLine`); any other bad line throws.
    public static func read(_ data: Data) throws -> Contents {
        try read(data, maxVersion: version)
    }

    /// `read(_:)` as a reader that knows versions up to `maxVersion`.
    static func read(_ data: Data, maxVersion: Int) throws -> Contents {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let decoder = makeDecoder()
        var header: Header?
        var estimates: [Estimate] = []
        var pins: [Pin] = []
        var roads: [Roads] = []
        var selections: [RoadsSelection] = []
        var unrecognized = 0
        var truncated = false
        for (index, bytes) in lines.enumerated() {
            let line: Line
            do {
                line = try decoder.decode(Line.self, from: Data(bytes))
            } catch {
                if index == lines.count - 1 && index > 0 {
                    truncated = true
                    break
                }
                if index == 0 { throw ReadError.missingHeader }
                throw ReadError.malformedLine(number: index + 1, description: String(describing: error))
            }
            if index == 0 {
                guard case .header(let value) = line else { throw ReadError.missingHeader }
                guard value.sidecarVersion <= maxVersion else { throw ReadError.unsupportedVersion(value.sidecarVersion) }
                header = value
                continue
            }
            switch line {
            case .estimate(let value): estimates.append(value)
            case .pin(let value): pins.append(value)
            case .roads(let value):
                if let last = roads.last {
                    guard (header?.sidecarVersion ?? 0) >= 3 else { throw ReadError.duplicateRoadsLine(number: index + 1) }
                    let before = Set(last.roads.map(\.contentHash)), now = Set(value.roads.map(\.contentHash))
                    guard value.afterInputs >= last.afterInputs else {
                        throw ReadError.invalidRoadsLine(number: index + 1, reason: "afterInputs \(value.afterInputs) "
                                                         + "is before the previous line's \(last.afterInputs)")
                    }
                    guard before.isStrictSubset(of: now) else {
                        throw ReadError.invalidRoadsLine(number: index + 1, reason: "its packs are not a strict "
                                                         + "superset of the previous line's")
                    }
                }
                roads.append(value)
            case .roadsSelection(let value): selections.append(value)
            case .header, .unrecognized: unrecognized += 1
            }
        }
        guard let header else { throw ReadError.missingHeader }
        return Contents(header: header, estimates: estimates, pins: pins, roads: roads, roadsSelections: selections,
                        unrecognizedLines: unrecognized, truncatedLastLine: truncated)
    }
}

/// Buffered writer of one sidecar file. Not thread-safe: one owner (the
/// app's NavigationService actor) calls it. Write errors never throw out:
/// the first one is kept in `failure`, the file is closed and later lines
/// are counted as lost — navigation itself goes on.
public final class NavSidecarWriter {
    public let url: URL
    private var handle: FileHandle?
    private var pending = Data()
    private let encoder = NavSidecar.makeEncoder()
    /// Bytes handed to the file so far.
    public private(set) var bytesWritten = 0
    /// Lines that never reached the file (encoding or write failure, or
    /// appended after `close()`).
    public private(set) var linesLost = 0
    /// The first write failure, if any.
    public private(set) var failure: String?

    /// Creates (or truncates) the file at `url`.
    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle?.close()
    }

    public var isOpen: Bool { handle != nil }

    /// Bytes buffered and not yet written.
    public var pendingBytes: Int { pending.count }

    /// Buffers one line; nothing is written until `flush()`.
    public func append(_ line: NavSidecar.Line) {
        guard handle != nil else {
            linesLost += 1
            return
        }
        do {
            pending.append(try NavSidecar.encode(line, with: encoder))
        } catch {
            linesLost += 1
        }
    }

    /// Writes what is buffered.
    public func flush() {
        guard let handle, !pending.isEmpty else { return }
        do {
            try handle.write(contentsOf: pending)
            bytesWritten += pending.count
            pending.removeAll(keepingCapacity: true)
        } catch {
            fail(error)
        }
    }

    /// Flushes and closes. Idempotent.
    public func close() {
        flush()
        guard let handle else { return }
        do {
            try handle.close()
        } catch {
            if failure == nil { failure = String(describing: error) }
        }
        self.handle = nil
    }

    private func fail(_ error: any Error) {
        if failure == nil { failure = String(describing: error) }
        linesLost += pending.split(separator: 0x0A).count
        pending.removeAll()
        try? handle?.close()
        handle = nil
    }
}
