import Foundation

/// The navigation sidecar `<recording>.nav.jsonl` (N4 B): what the live
/// navigation showed the driver, so `replay_nav --as-live --compare` can
/// prove a replay reproduces it. Path: `NavSidecarFile`. Format:
/// docs/NAV_SIDECAR.md.
///
/// Versioned on its own, separate from the log format: the logger never
/// reads or writes it. JSON Lines, one object per line, each with a `kind`:
/// - `header` (first line): sidecar version, session ID, seed, the config as
///   canonical JSON and its hash, the app build;
/// - `estimate`: one per second of session-clock time once the engine is
///   initialised, as `NavigationEngine.estimate(at:)` returned it at that
///   grid instant;
/// - `pin`: the estimate at a confirmed manual fix, the prior just before
///   the engine ingested it.
///
/// Times are session-clock nanoseconds (`t`, like the log). Doubles are
/// written at full precision so a replay can match them bit for bit;
/// non-finite values as the strings "inf", "-inf", "nan".
public enum NavSidecar {
    /// The version `LiveNavigationRun` writes. A reader refuses a newer one.
    public static let version = 1

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

        public init(sessionID: UUID, config: NavigationConfig, appBuild: String) {
            sidecarVersion = NavSidecar.version
            self.sessionID = sessionID
            seed = config.seed
            configHash = config.hashHex
            configJSON = String(decoding: config.canonicalJSON(), as: UTF8.self)
            self.appBuild = appBuild
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

    public enum Line: Hashable, Sendable, Codable {
        case header(Header)
        case estimate(Estimate)
        case pin(Pin)
        /// A kind this reader does not know (a later version); skipped.
        case unrecognized(kind: String)

        public var kind: String {
            switch self {
            case .header: "header"
            case .estimate: "estimate"
            case .pin: "pin"
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
            default: self = .unrecognized(kind: kind)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .header(let value): try value.encode(to: encoder)
            case .estimate(let value): try value.encode(to: encoder)
            case .pin(let value): try value.encode(to: encoder)
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
    }

    public struct Contents: Hashable, Sendable {
        public var header: Header
        public var estimates: [Estimate]
        public var pins: [Pin]
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
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let decoder = makeDecoder()
        var header: Header?
        var estimates: [Estimate] = []
        var pins: [Pin] = []
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
                guard value.sidecarVersion <= version else { throw ReadError.unsupportedVersion(value.sidecarVersion) }
                header = value
                continue
            }
            switch line {
            case .estimate(let value): estimates.append(value)
            case .pin(let value): pins.append(value)
            case .header, .unrecognized: unrecognized += 1
            }
        }
        guard let header else { throw ReadError.missingHeader }
        return Contents(header: header, estimates: estimates, pins: pins,
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
