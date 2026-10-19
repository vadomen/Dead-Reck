import Foundation

/// The rules of a road pack download (UX-8, docs/BACKLOG_UX.md; prompt 25):
/// whether to resume a partial file, what to do with the server's answer,
/// what the partial's metadata sidecar holds, and when the network allows a
/// download. Pure logic: the app's transport (URLSession) asks, carries out
/// the answer and keeps the bytes; the file's SHA-256 against the manifest
/// is checked by the app after the last byte and is the real guard (none of
/// the rules here can prove the bytes are right).
///
/// **The server, as measured (prompt 25 step 0).** Pack URLs are
/// content-addressed (`<name>-<contentHash>.roadpack`) and served
/// `Cache-Control: immutable`. A ranged `GET` gets `206` with
/// `Content-Range: bytes a-b/<total>` and, on a plain ranged request, an
/// `ETag`. Two departures from RFC 9110 shape the rules:
/// - **`If-Range` is ignored.** A mismatched validator still gets `206`
///   (and that `206` carries no `ETag`). So a changed file is caught by the
///   `Content-Range` checks (start = the requested offset, total = the
///   manifest size) and by comparing a returned `ETag` with the stored one;
///   `If-Range` is still sent, which is right on a compliant server.
/// - **An unsatisfiable range gets `500`, not `416`.** So no range is ever
///   requested at or past the expected size (`plan`), which leaves a `5xx`
///   to a ranged request meaning what it says: a server error. It fails the
///   attempt and KEEPS the partial (R66.1-6): URLs are immutable and `plan`
///   never asks past the size, so a transient `502`/`503` must not throw
///   away e.g. 100 MB of a 120 MB pack; the next attempt resumes. Only a
///   `416` and a `206` that does not continue this file (`Content-Range`
///   start or total, a changed `ETag`) discard the partial and restart
///   without `Range`; the transport allows that restart once per attempt.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public enum PackDownloadRules {
    // MARK: Before a request

    /// What to request, given what is on disk.
    public enum Plan: Hashable, Sendable {
        /// No usable partial: `GET` without `Range`, write from byte 0.
        case fresh
        /// `GET` with `Range: bytes=<offset>-` and, when non-nil,
        /// `If-Range: <ifRange>`; append to the partial.
        case resume(from: Int64, ifRange: String?)
        /// The partial already has every byte: do not request, verify its
        /// SHA-256 (asking for `bytes=<size>-` would get a `500`).
        case verifyOnly
        /// The partial is longer than the pack: delete it, then go `fresh`.
        case discardAndRestart
    }

    /// The request plan for a partial of `partialBytes` (nil: no partial
    /// file) of a pack of `expectedSize` bytes. `storedETag` (from the
    /// metadata sidecar) goes into `If-Range` only when it is a strong
    /// validator: RFC 9110 never matches a weak one there, which on a
    /// compliant server would turn every resume into a full download.
    public static func plan(partialBytes: Int64?, expectedSize: Int64, storedETag: String?) -> Plan {
        guard let partial = partialBytes, partial != 0 else { return .fresh }
        if partial < 0 || partial > expectedSize { return .discardAndRestart }
        if partial == expectedSize { return .verifyOnly }
        let ifRange = storedETag.flatMap { isStrongETag($0) ? $0 : nil }
        return .resume(from: partial, ifRange: ifRange)
    }

    /// `"…"` (not `W/"…"`, not empty).
    public static func isStrongETag(_ etag: String) -> Bool {
        let t = etag.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.hasPrefix("\"") && t.hasSuffix("\"")
    }

    // MARK: After the response headers

    /// What to do with a response, decided from its status and headers
    /// before any body byte is written.
    public enum ResponseDecision: Hashable, Sendable {
        /// `206` for exactly the requested range of this file: append the
        /// body to the partial.
        case append
        /// `200`, the whole file: truncate the partial, write the body from
        /// byte 0 and store `etag` (nil: clear the stored one).
        case writeFromZero(etag: String?)
        /// The partial cannot be continued (`416`, or a `206` that is not
        /// the rest of this file): delete it (and its stored ETag) and
        /// request again without `Range`. At most once per attempt.
        case restartWithoutRange(reason: String)
        /// Give up this attempt; the partial is kept for a later one (a
        /// `5xx`, ranged or not, is one of these).
        case fail(reason: String)
    }

    /// The decision for a response with `status`.
    /// - `requestedOffset`: the `Range` start sent; nil when no `Range` was.
    /// - `contentRange`, `etag`: the response headers (nil when absent).
    /// - `storedETag`: the ETag kept with the partial.
    /// - `contentLength`: the response's `Content-Length` when known; a
    ///   `200` whose length is not `expectedSize` is not this pack.
    public static func decide(status: Int, requestedOffset: Int64?, contentRange: String?,
                              etag: String?, storedETag: String?, expectedSize: Int64,
                              contentLength: Int64? = nil) -> ResponseDecision {
        switch status {
        case 200:
            if let length = contentLength, length != expectedSize {
                return .fail(reason: "200 with \(length) bytes, the manifest says \(expectedSize)")
            }
            return .writeFromZero(etag: etag)
        case 206:
            guard let offset = requestedOffset else {
                return .fail(reason: "206 to a request without Range")
            }
            guard let header = contentRange else {
                return .restartWithoutRange(reason: "206 without Content-Range")
            }
            guard let parsed = parseContentRange(header), let range = parsed.range else {
                return .restartWithoutRange(reason: "206 with unusable Content-Range \"\(header)\"")
            }
            guard range.lowerBound == offset else {
                return .restartWithoutRange(reason: "206 from byte \(range.lowerBound), requested \(offset)")
            }
            guard parsed.total == expectedSize else {
                let total = parsed.total.map(String.init) ?? "*"
                return .restartWithoutRange(reason: "206 for a file of \(total) bytes, the manifest says \(expectedSize)")
            }
            if let new = etag, let stored = storedETag, opaqueTag(new) != opaqueTag(stored) {
                return .restartWithoutRange(reason: "206 with ETag \(new), the partial has \(stored)")
            }
            return .append
        case 416:
            guard requestedOffset != nil else { return .fail(reason: "416 to a request without Range") }
            return .restartWithoutRange(reason: "416: the server cannot serve the rest of the partial")
        case 404:
            return .fail(reason: "404: the pack is not on the server")
        case 500...599:
            // Ranged or not: a server error, the partial is kept (R66.1-6).
            return .fail(reason: requestedOffset == nil ? "server error \(status)"
                                                        : "server error \(status) to a ranged request")
        case 400...499:
            return .fail(reason: "client error \(status)")
        default:
            return .fail(reason: "unexpected status \(status)")
        }
    }

    /// An ETag without the weak prefix: `W/"x"` and `"x"` name the same
    /// representation for change detection.
    static func opaqueTag(_ etag: String) -> String {
        let t = etag.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("W/") ? String(t.dropFirst(2)) : t
    }

    // MARK: Content-Range

    /// A parsed `Content-Range` header.
    public struct ContentRange: Hashable, Sendable {
        /// The bytes sent, inclusive; nil for `bytes */<total>` (the form of
        /// an unsatisfiable-range answer).
        public var range: ClosedRange<Int64>?
        /// The complete length; nil for `bytes a-b/*`.
        public var total: Int64?

        public init(range: ClosedRange<Int64>?, total: Int64?) {
            self.range = range
            self.total = total
        }
    }

    /// Parses `bytes a-b/total`, `bytes a-b/*` and `bytes */total` (unit
    /// case-insensitive, spaces around the parts allowed). nil for anything
    /// else, `a > b`, `b >= total`, or `*/*`.
    public static func parseContentRange(_ header: String) -> ContentRange? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.count > 6, text.prefix(6).lowercased() == "bytes " else { return nil }
        let rest = text.dropFirst(6)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangeText = parts[0].trimmingCharacters(in: .whitespaces)
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        var total: Int64?
        if totalText != "*" {
            guard let t = decimal(totalText) else { return nil }
            total = t
        }
        if rangeText == "*" {
            guard total != nil else { return nil }
            return ContentRange(range: nil, total: total)
        }
        let bounds = rangeText.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = decimal(bounds[0].trimmingCharacters(in: .whitespaces)),
              let last = decimal(bounds[1].trimmingCharacters(in: .whitespaces)),
              first <= last else { return nil }
        if let total, last >= total { return nil }
        return ContentRange(range: first...last, total: total)
    }

    /// Non-negative decimal digits only (no sign, no spaces), fitting Int64.
    static func decimal(_ text: String) -> Int64? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int64(text)
    }

    // MARK: The partial's metadata

    /// The sidecar next to a partial download
    /// (`RoadPackStoreRules.partialMetadataFileName`): what the partial is a
    /// prefix of. Written when a download starts and on every new ETag;
    /// read before a resume.
    public struct PartialMetadata: Codable, Hashable, Sendable {
        /// Bumped if the fields change meaning.
        public var version: Int
        /// The absolute download URL.
        public var url: String
        /// The last ETag the server sent for it; nil when none was sent.
        public var etag: String?
        public var expectedSize: Int64
        /// 64 lowercase hex digits.
        public var sha256: String

        public static let currentVersion = 1

        public init(url: String, etag: String?, expectedSize: Int64, sha256: String) {
            self.version = Self.currentVersion
            self.url = url
            self.etag = etag
            self.expectedSize = expectedSize
            self.sha256 = sha256
        }

        public init(pack: PackManifest.Pack, etag: String?) {
            self.init(url: pack.url.absoluteString, etag: etag, expectedSize: pack.size, sha256: pack.sha256)
        }

        /// Whether the partial is a prefix of `pack` as the manifest now
        /// describes it (same size and SHA-256). If not, delete the partial
        /// and start fresh; the URL may change (another host path) without
        /// changing the bytes.
        public func matches(_ pack: PackManifest.Pack) -> Bool {
            version == Self.currentVersion && expectedSize == pack.size && sha256 == pack.sha256
        }

        /// Sorted-key JSON.
        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }

        /// nil when `data` is not a metadata file (treat the partial as
        /// having none: resume without `If-Range`; the SHA-256 still guards).
        public static func decode(_ data: Data) -> PartialMetadata? {
            try? JSONDecoder().decode(PartialMetadata.self, from: data)
        }
    }

    // MARK: Network policy

    /// The connection as the app's path monitor reports it.
    public enum Connection: Hashable, Sendable {
        case none
        /// Wi-Fi or wired, not marked expensive or constrained.
        case unmetered
        /// Cellular, or any path marked expensive or constrained
        /// (a personal hotspot, Low Data Mode).
        case cellularOrExpensive
    }

    /// Whether downloads may run now.
    public enum NetworkState: Hashable, Sendable {
        case allowed
        /// Cellular and the user has not allowed it.
        case waitingForWiFi
        /// A Record session runs: downloads pause so nothing competes with
        /// capture (Navigate does not pause them).
        case pausedForRecording
        case offline
    }

    /// The download state: Record first (it pauses downloads whatever the
    /// network), then no network, then cellular without permission.
    public static func networkState(connection: Connection, cellularAllowed: Bool, recordActive: Bool) -> NetworkState {
        if recordActive { return .pausedForRecording }
        switch connection {
        case .none: return .offline
        case .cellularOrExpensive: return cellularAllowed ? .allowed : .waitingForWiFi
        case .unmetered: return .allowed
        }
    }
}
