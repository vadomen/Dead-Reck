import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-8 (prompt 25): resume plan, response decision (including the measured
/// server quirks: If-Range ignored, 500 for an unsatisfiable range),
/// Content-Range, partial metadata, network policy. Synthetic values only.
@Suite("Pack download rules (UX-8)")
struct PackDownloadRulesTests {
    typealias D = PackDownloadRules

    static let size: Int64 = 1_000
    static let etag = "\"etag-1\""

    // MARK: Plan

    @Test("Plan: no partial or 0 bytes -> fresh; partial < size -> resume from it; == size -> verifyOnly; > size -> discard")
    func plans() {
        #expect(D.plan(partialBytes: nil, expectedSize: Self.size, storedETag: Self.etag) == .fresh)
        #expect(D.plan(partialBytes: 0, expectedSize: Self.size, storedETag: Self.etag) == .fresh)
        #expect(D.plan(partialBytes: 1, expectedSize: Self.size, storedETag: Self.etag) == .resume(from: 1, ifRange: Self.etag))
        #expect(D.plan(partialBytes: 999, expectedSize: Self.size, storedETag: nil) == .resume(from: 999, ifRange: nil))
        // Never a range at or past the size (the server answers 500, not 416).
        #expect(D.plan(partialBytes: 1_000, expectedSize: Self.size, storedETag: Self.etag) == .verifyOnly)
        #expect(D.plan(partialBytes: 1_001, expectedSize: Self.size, storedETag: Self.etag) == .discardAndRestart)
        #expect(D.plan(partialBytes: -1, expectedSize: Self.size, storedETag: Self.etag) == .discardAndRestart)
    }

    @Test("Plan: If-Range carries only a strong ETag")
    func ifRangeStrongOnly() {
        #expect(D.plan(partialBytes: 10, expectedSize: Self.size, storedETag: "W/\"etag-1\"") == .resume(from: 10, ifRange: nil))
        #expect(D.plan(partialBytes: 10, expectedSize: Self.size, storedETag: "") == .resume(from: 10, ifRange: nil))
        #expect(D.plan(partialBytes: 10, expectedSize: Self.size, storedETag: "etag-1") == .resume(from: 10, ifRange: nil))
        #expect(D.isStrongETag("\"x\"") && D.isStrongETag("\"\"") && !D.isStrongETag("\"") && !D.isStrongETag("W/\"x\""))
    }

    // MARK: Response decision

    static func decide(_ status: Int, offset: Int64? = 400, range: String? = "bytes 400-999/1000",
                       etag: String? = nil, stored: String? = etag, length: Int64? = nil) -> D.ResponseDecision {
        D.decide(status: status, requestedOffset: offset, contentRange: range, etag: etag,
                 storedETag: stored, expectedSize: size, contentLength: length)
    }

    static func isRestart(_ d: D.ResponseDecision) -> Bool {
        if case .restartWithoutRange = d { return true }
        return false
    }

    static func isFail(_ d: D.ResponseDecision) -> Bool {
        if case .fail = d { return true }
        return false
    }

    @Test("206 for exactly the requested range of this file -> append (with or without a matching ETag)")
    func appendCases() {
        #expect(Self.decide(206) == .append)  // the server's 206 to an If-Range request: no ETag
        #expect(Self.decide(206, etag: Self.etag) == .append)
        #expect(Self.decide(206, etag: "W/\"etag-1\"") == .append)  // weak/strong forms of one tag
        #expect(Self.decide(206, etag: Self.etag, stored: nil) == .append)  // nothing stored to compare with
        #expect(Self.decide(206, range: "bytes 400-499/1000") == .append)  // a shorter chunk still continues the file
        #expect(Self.decide(206, offset: 0, range: "bytes 0-999/1000") == .append)
    }

    @Test("Server quirk: If-Range ignored -> a 206 whose ETag differs from the stored one restarts")
    func ifRangeIgnored() {
        #expect(Self.isRestart(Self.decide(206, etag: "\"etag-2\"", stored: Self.etag)))
        #expect(Self.isRestart(Self.decide(206, etag: "\"etag-2\"", stored: "W/\"etag-1\"")))
    }

    @Test("206 with a missing, unusable or mismatched Content-Range restarts without Range")
    func contentRangeMismatch() {
        for range: String? in [nil, "", "bytes 400-999", "items 400-999/1000", "bytes */1000",
                               "bytes 401-999/1000", "bytes 0-999/1000", "bytes 400-999/2000",
                               "bytes 400-999/*", "bytes 400-1000/1000"] {
            #expect(Self.isRestart(Self.decide(206, range: range)), "Content-Range \(range ?? "nil")")
        }
    }

    @Test("Server quirks: 416 and a 5xx to a ranged request restart without Range; unranged they fail")
    func restartStatuses() {
        #expect(Self.isRestart(Self.decide(416, range: "bytes */1000")))
        #expect(Self.isRestart(Self.decide(416, range: nil)))
        for status in [500, 502, 503, 599] {
            #expect(Self.isRestart(Self.decide(status, range: nil)), "\(status)")
            #expect(Self.isFail(Self.decide(status, offset: nil, range: nil)), "\(status) unranged")
        }
        #expect(Self.isFail(Self.decide(416, offset: nil, range: nil)))
    }

    @Test("200 -> writeFromZero with the new ETag (ranged or not); a 200 of the wrong length fails")
    func fullResponses() {
        #expect(Self.decide(200, range: nil, etag: "\"etag-2\"") == .writeFromZero(etag: "\"etag-2\""))
        #expect(Self.decide(200, offset: nil, range: nil, etag: nil) == .writeFromZero(etag: nil))
        #expect(Self.decide(200, offset: nil, range: nil, etag: Self.etag, length: 1_000) == .writeFromZero(etag: Self.etag))
        #expect(Self.isFail(Self.decide(200, offset: nil, range: nil, length: 999)))
        #expect(Self.isFail(Self.decide(200, range: nil, length: 600)))  // the rest-of-file length is not the pack
    }

    @Test("Failures: 404, other 4xx, 206 to an unranged request, unexpected statuses")
    func failures() {
        #expect(Self.decide(404, range: nil) == .fail(reason: "404: the pack is not on the server"))
        #expect(Self.decide(404, offset: nil, range: nil) == .fail(reason: "404: the pack is not on the server"))
        for status in [400, 401, 403, 410, 429] {
            #expect(Self.isFail(Self.decide(status, range: nil)), "\(status)")
        }
        #expect(Self.isFail(Self.decide(206, offset: nil, range: "bytes 0-999/1000")))
        for status in [100, 204, 301, 304, 0, 600] {
            #expect(Self.isFail(Self.decide(status, range: nil)), "\(status)")
        }
    }

    // MARK: Content-Range

    @Test("Content-Range: a-b/total, a-b/*, */total; anything else is nil")
    func contentRange() {
        #expect(D.parseContentRange("bytes 0-99/1000") == .init(range: 0...99, total: 1_000))
        #expect(D.parseContentRange("Bytes  400-999/1000 ") == .init(range: 400...999, total: 1_000))
        #expect(D.parseContentRange("bytes 5-5/6") == .init(range: 5...5, total: 6))
        #expect(D.parseContentRange("bytes 0-99/*") == .init(range: 0...99, total: nil))
        #expect(D.parseContentRange("bytes */1000") == .init(range: nil, total: 1_000))
        #expect(D.parseContentRange("bytes 0-149999999/150000000") == .init(range: 0...149_999_999, total: 150_000_000))
        for bad in ["", "bytes", "bytes ", "0-99/1000", "bytes 0-99", "bytes 99-0/1000", "bytes 0-1000/1000",
                    "bytes */*", "bytes -1-99/1000", "bytes 0-99/-5", "bytes 0-99/1000/2", "bytes a-b/c",
                    "bytes 0-/1000", "bytes -99/1000", "bytes +0-99/1000", "items 0-99/1000",
                    "bytes 0-99/99999999999999999999"] {
            #expect(D.parseContentRange(bad) == nil, "\(bad)")
        }
    }

    // MARK: Partial metadata

    @Test("Partial metadata: round-trips as sorted-key JSON; matches the pack by size and sha256")
    func metadata() throws {
        let sha = String(repeating: "cd", count: 32)
        let pack = PackManifest.Pack(name: "region-a", kind: .region, titleUK: "Регіон А", titleEN: "Region A",
                                     bbox: .init(west: 10, south: 20, east: 11, north: 21),
                                     url: URL(string: "https://packs.example.test/packs/v1/region-a.roadpack")!,
                                     size: 1_000, sha256: sha, contentHash: "0123456789abcdef",
                                     formatVersion: 1, osmDate: nil, osmTimestamp: 0)
        let meta = D.PartialMetadata(pack: pack, etag: Self.etag)
        #expect(meta.url == "https://packs.example.test/packs/v1/region-a.roadpack")
        #expect(meta.expectedSize == 1_000 && meta.sha256 == sha && meta.etag == Self.etag && meta.version == 1)
        let data = try meta.encoded()
        #expect(String(decoding: data, as: UTF8.self)
                == #"{"etag":"\"etag-1\"","expectedSize":1000,"sha256":"\#(sha)","url":"https:\/\/packs.example.test\/packs\/v1\/region-a.roadpack","version":1}"#)
        #expect(D.PartialMetadata.decode(data) == meta)
        #expect(D.PartialMetadata.decode(Data("{}".utf8)) == nil)
        #expect(D.PartialMetadata.decode(Data("not json".utf8)) == nil)
        #expect(meta.matches(pack))
        var other = pack
        other.size = 1_001
        #expect(!meta.matches(other))
        other = pack
        other.sha256 = String(repeating: "ef", count: 32)
        #expect(!meta.matches(other))
        other = pack
        other.url = URL(string: "https://packs.example.test/elsewhere.roadpack")!
        #expect(meta.matches(other))  // the URL may move; the bytes are what count
        var future = meta
        future.version = 2
        #expect(!future.matches(pack))
    }

    // MARK: Network policy

    @Test("Network policy: Record pauses first, then no network, then cellular without permission")
    func network() {
        let table: [(D.Connection, Bool, Bool, D.NetworkState)] = [
            (.none, false, false, .offline),
            (.none, true, false, .offline),
            (.none, false, true, .pausedForRecording),
            (.none, true, true, .pausedForRecording),
            (.unmetered, false, false, .allowed),
            (.unmetered, true, false, .allowed),
            (.unmetered, false, true, .pausedForRecording),
            (.unmetered, true, true, .pausedForRecording),
            (.cellularOrExpensive, false, false, .waitingForWiFi),
            (.cellularOrExpensive, true, false, .allowed),
            (.cellularOrExpensive, false, true, .pausedForRecording),
            (.cellularOrExpensive, true, true, .pausedForRecording),
        ]
        for (connection, cellular, record, expected) in table {
            #expect(D.networkState(connection: connection, cellularAllowed: cellular, recordActive: record) == expected,
                    "\(connection) cellular=\(cellular) record=\(record)")
        }
    }
}
