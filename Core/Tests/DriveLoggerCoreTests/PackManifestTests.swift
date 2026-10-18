import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-8 (prompt 25): the download manifest, schema 2. Hand-written JSON with
/// synthetic names, titles, bboxes and hashes only.
@Suite("Pack manifest (UX-8)")
struct PackManifestTests {
    typealias M = PackManifest

    static let manifestURL = URL(string: "https://packs.example.test/packs/manifest.json")!
    static let sha = String(repeating: "ab", count: 32)
    static let hashA = "0123456789abcdef"
    static let hashB = "fedcba9876543210"

    /// One valid entry as a JSON object text; `overrides` replace (or, with
    /// nil, remove) fields. Values are raw JSON.
    static func entry(_ name: String = "region-a", hash: String = hashA, _ overrides: [String: String?] = [:]) -> String {
        var fields: [String: String] = [
            "name": "\"\(name)\"",
            "kind": "\"region\"",
            "title": "{\"uk\": \"Регіон А\", \"en\": \"Region A\"}",
            "bbox": "[10, 20, 11.5, 21]",
            "url": "\"/packs/v1/\(name)-\(hash).roadpack\"",
            "size": "1000",
            "sha256": "\"\(sha)\"",
            "contentHash": "\"\(hash)\"",
            "formatVersion": "1",
            "osmDate": "\"2000-01-02T03:04:05Z\"",
            "osmTimestamp": "946782245",
        ]
        for (key, value) in overrides { fields[key] = value }
        return "{" + fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ") + "}"
    }

    static func entry(_ overrides: [String: String?]) -> String {
        entry("region-a", hash: hashA, overrides)
    }

    static func manifest(_ entries: [String], schema: String = "2", omit: String? = nil) -> Data {
        var fields: [String: String] = [
            "schema": schema,
            "generated": "\"2000-01-03T00:00:00Z\"",
            "license": "\"ODbL 1.0\"",
            "licenseUrl": "\"https://license.example.test/odbl\"",
            "attribution": "\"© OpenStreetMap contributors\"",
            "packs": "[" + entries.joined(separator: ", ") + "]",
        ]
        if let omit { fields[omit] = nil }
        return Data(("{" + fields.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ") + "}").utf8)
    }

    static func parse(_ entries: [String]) throws -> M {
        try M.parse(data: manifest(entries), manifestURL: manifestURL)
    }

    /// The single drop reason of a manifest with one bad entry.
    static func dropReason(_ entry: String) throws -> M.DropReason? {
        let m = try parse([entry])
        #expect(m.packs.isEmpty)
        return m.dropped.first?.reason
    }

    // MARK: Whole manifest

    @Test("A valid manifest: top-level fields, every pack field, the resolved absolute URL")
    func valid() throws {
        let national = Self.entry("national", hash: Self.hashB, [
            "kind": "\"national\"", "title": "{\"uk\": \"Країна\", \"en\": \"Country\"}", "bbox": "[10.25, 20, 12, 22.75]"])
        let m = try Self.parse([national, Self.entry()])
        #expect(m.manifestURL == Self.manifestURL)
        #expect(m.generated == "2000-01-03T00:00:00Z")
        #expect(m.generatedDate == Date(timeIntervalSince1970: 946_857_600))
        #expect(m.license == "ODbL 1.0" && m.licenseURL == "https://license.example.test/odbl")
        #expect(m.attribution == "© OpenStreetMap contributors")
        #expect(m.dropped.isEmpty)
        #expect(m.packs.map(\.name) == ["national", "region-a"])
        let a = try #require(m.pack(named: "region-a"))
        #expect(a.kind == .region && m.packs[0].kind == .national)
        #expect(a.titleUK == "Регіон А" && a.titleEN == "Region A")
        #expect(a.bbox == M.BBox(west: 10, south: 20, east: 11.5, north: 21))
        #expect(m.packs[0].bbox == M.BBox(west: 10.25, south: 20, east: 12, north: 22.75))
        #expect(a.url.absoluteString == "https://packs.example.test/packs/v1/region-a-0123456789abcdef.roadpack")
        #expect(a.size == 1000 && a.sha256 == Self.sha && a.contentHash == Self.hashA)
        #expect(a.formatVersion == 1 && a.osmDate == "2000-01-02T03:04:05Z" && a.osmTimestamp == 946_782_245)
        #expect(a.fileName == "region-a-0123456789abcdef.roadpack")
        #expect(m.pack(named: "zz-01") == nil)
        // osmDate is optional (the publisher omits it when the OSM time is unknown).
        let noDate = try Self.parse([Self.entry(["osmDate": nil, "osmTimestamp": "0"])])
        #expect(noDate.packs.first?.osmDate == nil && noDate.packs.first?.osmTimestamp == 0)
        // An empty pack list is a valid manifest.
        #expect(try Self.parse([]).packs.isEmpty)
        // Integral floats are integers.
        #expect(try Self.parse([Self.entry(["size": "1000.0"])]).packs.first?.size == 1000)
    }

    @Test("The whole manifest is refused only for non-JSON, a missing or mistyped top-level field, or schema != 2")
    func refusals() {
        #expect(throws: M.ParseError.unsupportedSchema(3)) {
            try M.parse(data: Self.manifest([Self.entry()], schema: "3"), manifestURL: Self.manifestURL)
        }
        #expect(throws: M.ParseError.unsupportedSchema(1)) {
            try M.parse(data: Self.manifest([Self.entry()], schema: "1"), manifestURL: Self.manifestURL)
        }
        #expect(throws: M.ParseError.mistypedField("schema")) {
            try M.parse(data: Self.manifest([], schema: "\"2\""), manifestURL: Self.manifestURL)
        }
        for field in ["schema", "generated", "license", "licenseUrl", "attribution", "packs"] {
            #expect(throws: M.ParseError.missingField(field)) {
                try M.parse(data: Self.manifest([Self.entry()], omit: field), manifestURL: Self.manifestURL)
            }
        }
        #expect(throws: M.ParseError.mistypedField("packs")) {
            try M.parse(data: Data(#"{"schema": 2, "generated": "x", "license": "l", "licenseUrl": "u", "attribution": "a", "packs": {}}"#.utf8),
                        manifestURL: Self.manifestURL)
        }
        #expect(throws: M.ParseError.mistypedField("license")) {
            try M.parse(data: Data(#"{"schema": 2, "generated": "x", "license": 1, "licenseUrl": "u", "attribution": "a", "packs": []}"#.utf8),
                        manifestURL: Self.manifestURL)
        }
        for text in ["", "not json", "[1, 2]", "\"text\"", "{\"schema\": 2,"] {
            #expect(throws: M.ParseError.notJSON) { try M.parse(data: Data(text.utf8), manifestURL: Self.manifestURL) }
        }
        // Schema is checked before the other fields: a schema 3 manifest of another shape still says "schema".
        #expect(throws: M.ParseError.unsupportedSchema(3)) {
            try M.parse(data: Data(#"{"schema": 3, "files": []}"#.utf8), manifestURL: Self.manifestURL)
        }
    }

    // MARK: Per-entry drops

    @Test("A missing or mistyped field drops the entry, not the manifest; the rest stay")
    func fieldDrops() throws {
        let required = ["name", "kind", "title", "bbox", "url", "size", "sha256", "contentHash", "formatVersion", "osmTimestamp"]
        for field in required {
            #expect(try Self.dropReason(Self.entry([field: nil])) == .missingField(field), "missing \(field)")
        }
        let mistyped: [(String, String)] = [
            ("name", "1"), ("kind", "true"), ("title", "\"Region A\""), ("bbox", "\"10,20,11,21\""),
            ("bbox", "[10, \"20\", 11, 21]"), ("url", "null"), ("size", "\"1000\""), ("size", "1000.5"),
            ("size", "true"), ("sha256", "1"), ("contentHash", "17"), ("formatVersion", "\"1\""),
            ("osmDate", "20000102"), ("osmTimestamp", "\"0\""),
        ]
        for (field, value) in mistyped {
            #expect(try Self.dropReason(Self.entry([field: value])) == .mistypedField(field), "\(field) = \(value)")
        }
        #expect(try Self.dropReason(Self.entry(["title": "{\"en\": \"Region A\"}"])) == .missingField("title.uk"))
        #expect(try Self.dropReason(Self.entry(["title": "{\"uk\": \"Регіон А\"}"])) == .missingField("title.en"))
        #expect(try Self.dropReason(Self.entry(["title": "{\"uk\": 1, \"en\": \"Region A\"}"])) == .mistypedField("title.uk"))
        #expect(try Self.dropReason(Self.entry(["title": "{\"uk\": \"Регіон А\", \"en\": null}"])) == .mistypedField("title.en"))
        #expect(try Self.dropReason("[]") == .notAnObject)
        #expect(try Self.dropReason("\"region-a\"") == .notAnObject)

        // One bad entry among good ones: only it goes, with its index and name.
        let m = try Self.parse([Self.entry("zz-01"), Self.entry("region-b", ["size": nil]), Self.entry("zz-02")])
        #expect(m.packs.map(\.name) == ["zz-01", "zz-02"])
        #expect(m.dropped == [M.DroppedEntry(index: 1, name: "region-b", reason: .missingField("size"))])
        #expect(m.dropped[0].description == "region-b: no \"size\"")
        // An entry without a string name is reported by index.
        let unnamed = try Self.parse([Self.entry(["name": nil])])
        #expect(unnamed.dropped == [M.DroppedEntry(index: 0, name: nil, reason: .missingField("name"))])
        #expect(unnamed.dropped[0].description.hasPrefix("#0: "))
    }

    @Test("Value drops: name, kind, formatVersion, size, sha256, contentHash, bbox, both titles empty")
    func valueDrops() throws {
        for name in ["Region-A", "-region", "region-", "region a", "../x", ""] {
            #expect(try Self.dropReason(Self.entry(name)) == .invalidName(name), "name \(name)")
        }
        #expect(try Self.dropReason(Self.entry(["kind": "\"city\""])) == .unknownKind("city"))
        #expect(try Self.dropReason(Self.entry(["kind": "\"National\""])) == .unknownKind("National"))
        let current = Int64(RoadPackFormat.currentVersion)
        #expect(try Self.dropReason(Self.entry(["formatVersion": "\(current + 1)"])) == .unsupportedFormatVersion(current + 1))
        #expect(try Self.dropReason(Self.entry(["formatVersion": "0"])) == .unsupportedFormatVersion(0))
        #expect(try Self.dropReason(Self.entry(["formatVersion": "-1"])) == .unsupportedFormatVersion(-1))
        #expect(try Self.parse([Self.entry(["formatVersion": "\(current)"])]).packs.count == 1)
        let max = Int64(RoadPackFormat.maximumFileSize)
        for size in [0, -1, max + 1] {
            #expect(try Self.dropReason(Self.entry(["size": "\(size)"])) == .invalidSize(size), "size \(size)")
        }
        #expect(try Self.parse([Self.entry(["size": "\(max)"])]).packs.first?.size == max)
        #expect(try Self.parse([Self.entry(["size": "1"])]).packs.first?.size == 1)
        for sha in [String(repeating: "AB", count: 32), String(repeating: "a", count: 63),
                    String(repeating: "a", count: 65), String(repeating: "g", count: 64), ""] {
            #expect(try Self.dropReason(Self.entry(["sha256": "\"\(sha)\""])) == .invalidSHA256, "sha \(sha)")
        }
        for hash in ["0123456789ABCDEF", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeg"] {
            #expect(try Self.dropReason(Self.entry(["contentHash": "\"\(hash)\""])) == .invalidContentHash, "hash \(hash)")
        }
        for box in ["[10, 20, 11]", "[10, 20, 11, 21, 22]", "[]", "[11, 20, 10, 21]", "[10, 21, 11, 20]",
                    "[-181, 20, 11, 21]", "[10, 20, 181, 21]", "[10, -91, 11, 21]", "[10, 20, 11, 91]"] {
            #expect(try Self.dropReason(Self.entry(["bbox": box])) == .invalidBBox, "bbox \(box)")
        }
        // A degenerate box (a point) is valid: W <= E and S <= N.
        #expect(try Self.parse([Self.entry(["bbox": "[10, 20, 10, 20]"])]).packs.count == 1)
        #expect(!M.BBox(west: .nan, south: 20, east: 11, north: 21).isValid)
        #expect(!M.BBox(west: 10, south: 20, east: .infinity, north: 21).isValid)
        for title in ["{\"uk\": \"\", \"en\": \"\"}", "{\"uk\": \"  \", \"en\": \"\\n\"}"] {
            #expect(try Self.dropReason(Self.entry(["title": title])) == .emptyTitles, "title \(title)")
        }
        // One title is enough.
        #expect(try Self.parse([Self.entry(["title": "{\"uk\": \"\", \"en\": \"Region A\"}"])]).packs.count == 1)
        #expect(try Self.parse([Self.entry(["title": "{\"uk\": \"Регіон А\", \"en\": \"\"}"])]).packs.count == 1)
    }

    @Test("URLs: relative ones resolve against the manifest; http, another host and unusable URLs are dropped")
    func urls() throws {
        func resolved(_ url: String) throws -> String? {
            try Self.parse([Self.entry(["url": "\"\(url)\""])]).packs.first?.url.absoluteString
        }
        #expect(try resolved("/packs/v1/region-a-0123456789abcdef.roadpack")
                == "https://packs.example.test/packs/v1/region-a-0123456789abcdef.roadpack")
        // Relative to the manifest's directory.
        #expect(try resolved("v1/region-a.roadpack") == "https://packs.example.test/packs/v1/region-a.roadpack")
        #expect(try resolved("../other/region-a.roadpack") == "https://packs.example.test/other/region-a.roadpack")
        // An absolute URL on the same host is accepted, host compared case-insensitively.
        #expect(try resolved("https://PACKS.example.test/x.roadpack") == "https://PACKS.example.test/x.roadpack")

        let other = "https://elsewhere.example.test/packs/v1/region-a.roadpack"
        #expect(try Self.dropReason(Self.entry(["url": "\"\(other)\""])) == .otherHost(other))
        let protocolRelative = "//elsewhere.example.test/region-a.roadpack"
        #expect(try Self.dropReason(Self.entry(["url": "\"\(protocolRelative)\""]))
                == .otherHost("https://elsewhere.example.test/region-a.roadpack"))
        let http = "http://packs.example.test/packs/v1/region-a.roadpack"
        #expect(try Self.dropReason(Self.entry(["url": "\"\(http)\""])) == .notHTTPS(http))
        let ftp = "ftp://packs.example.test/region-a.roadpack"
        #expect(try Self.dropReason(Self.entry(["url": "\"\(ftp)\""])) == .notHTTPS(ftp))
        #expect(try Self.dropReason(Self.entry(["url": "\"\""])) == .invalidURL(""))
        #expect(try Self.dropReason(Self.entry(["url": "\"   \""])) == .invalidURL("   "))
        #expect(try Self.dropReason(Self.entry(["url": "\"file:///tmp/region-a.roadpack\""])) == .invalidURL("file:///tmp/region-a.roadpack"))

        // An http manifest URL makes every relative pack URL http: all dropped.
        let insecure = try M.parse(data: Self.manifest([Self.entry()]), manifestURL: URL(string: "http://packs.example.test/packs/manifest.json")!)
        #expect(insecure.packs.isEmpty)
        #expect(insecure.dropped.first?.reason == .notHTTPS("http://packs.example.test/packs/v1/region-a-0123456789abcdef.roadpack"))
    }

    @Test("Duplicate names: the first accepted entry is kept; a broken earlier one does not block a good later one")
    func duplicates() throws {
        let m = try Self.parse([Self.entry(hash: Self.hashA), Self.entry(hash: Self.hashB), Self.entry("zz-01")])
        #expect(m.packs.map(\.name) == ["region-a", "zz-01"])
        #expect(m.packs[0].contentHash == Self.hashA)
        #expect(m.dropped == [M.DroppedEntry(index: 1, name: "region-a", reason: .duplicateName)])

        let late = try Self.parse([Self.entry(hash: Self.hashA, ["sha256": "\"x\""]), Self.entry(hash: Self.hashB)])
        #expect(late.packs.map(\.contentHash) == [Self.hashB])
        #expect(late.dropped == [M.DroppedEntry(index: 0, name: "region-a", reason: .invalidSHA256)])
    }

    // MARK: Titles

    @Test("Title: uk when the first preferred language is Ukrainian, else en; then the other; then the name")
    func titles() {
        func t(_ uk: String, _ en: String, _ langs: [String]) -> String {
            M.title(uk: uk, en: en, name: "region-a", preferredLanguages: langs)
        }
        #expect(t("Регіон А", "Region A", ["uk-UA", "en-US"]) == "Регіон А")
        #expect(t("Регіон А", "Region A", ["uk"]) == "Регіон А")
        #expect(t("Регіон А", "Region A", ["UK_ua"]) == "Регіон А")
        #expect(t("Регіон А", "Region A", ["en-US", "uk-UA"]) == "Region A")
        #expect(t("Регіон А", "Region A", ["de-DE"]) == "Region A")
        #expect(t("Регіон А", "Region A", []) == "Region A")
        // Fallback to the other language, then to the name.
        #expect(t("", "Region A", ["uk-UA"]) == "Region A")
        #expect(t("Регіон А", " ", ["en"]) == "Регіон А")
        #expect(t("", "", ["uk"]) == "region-a")
        let pack = M.Pack(name: "zz-01", kind: .region, titleUK: "Регіон Б", titleEN: "Region B",
                          bbox: .init(west: 10, south: 20, east: 11, north: 21),
                          url: URL(string: "https://packs.example.test/x")!, size: 1, sha256: Self.sha,
                          contentHash: Self.hashA, formatVersion: 1, osmDate: nil, osmTimestamp: 0)
        #expect(pack.title(preferredLanguages: ["uk-UA"]) == "Регіон Б")
        #expect(pack.title(preferredLanguages: ["en-GB"]) == "Region B")
    }

    // MARK: Updates, order, staleness

    @Test("updateAvailable: installed with a different content hash; not installed is never an update")
    func updates() {
        #expect(M.updateAvailable(installedContentHash: Self.hashA, manifestContentHash: Self.hashB))
        #expect(!M.updateAvailable(installedContentHash: Self.hashA, manifestContentHash: Self.hashA))
        #expect(!M.updateAvailable(installedContentHash: nil, manifestContentHash: Self.hashA))
    }

    @Test("List order: national first, then installed, then title (case-insensitive), then name; any input order")
    func order() {
        typealias E = M.ListEntry
        let national = E(name: "national", kind: .national, installed: false, title: "Zeta country")
        let installedB = E(name: "region-b", kind: .region, installed: true, title: "beta")
        let installedDev = E(name: "zz-dev", kind: nil, installed: true, title: "zz-dev")
        let alpha = E(name: "region-a", kind: .region, installed: false, title: "Alpha")
        let alphaLower = E(name: "region-c", kind: .region, installed: false, title: "alpha")
        let gamma = E(name: "region-g", kind: .region, installed: false, title: "Gamma")
        let expected = [national, installedB, installedDev, alpha, alphaLower, gamma]
        let locale = Locale(identifier: "en_US")
        for input in [expected, expected.reversed(), [gamma, alphaLower, installedDev, national, alpha, installedB]] {
            #expect(M.listOrder(input, locale: locale) == expected)
        }
        // A national pack that is not installed still precedes installed regions.
        #expect(M.listOrder([installedB, national], locale: locale) == [national, installedB])
        // Cyrillic titles sort among themselves case-insensitively.
        let a = E(name: "zz-02", kind: .region, installed: false, title: "Регіон А")
        let b = E(name: "zz-01", kind: .region, installed: false, title: "регіон Б")
        #expect(M.listOrder([b, a], locale: Locale(identifier: "uk_UA")) == [a, b])
        // ListEntry from a pack takes the display title.
        let pack = M.Pack(name: "zz-01", kind: .national, titleUK: "Країна", titleEN: "Country",
                          bbox: .init(west: 10, south: 20, east: 11, north: 21),
                          url: URL(string: "https://packs.example.test/x")!, size: 1, sha256: Self.sha,
                          contentHash: Self.hashA, formatVersion: 1, osmDate: nil, osmTimestamp: 0)
        #expect(E(pack: pack, installed: true, preferredLanguages: ["uk"]) == E(name: "zz-01", kind: .national, installed: true, title: "Країна"))
    }

    @Test("needsRefresh: never fetched, 24 h or older, or fetched in the future")
    func refresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(M.needsRefresh(fetchedAt: nil, now: now))
        #expect(!M.needsRefresh(fetchedAt: now, now: now))
        #expect(!M.needsRefresh(fetchedAt: now.addingTimeInterval(-86_399), now: now))
        #expect(M.needsRefresh(fetchedAt: now.addingTimeInterval(-86_400), now: now))
        #expect(M.needsRefresh(fetchedAt: now.addingTimeInterval(-200_000), now: now))
        #expect(M.needsRefresh(fetchedAt: now.addingTimeInterval(60), now: now))
    }
}
