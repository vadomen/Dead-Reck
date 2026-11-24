import Foundation
import Testing

@testable import DriveLogger

/// The pure parser behind the search field's coordinates and pasted map links
/// (prompt 53a). Every coordinate is invented, in the southern ocean or the
/// mid-Pacific, far from any real drive; every link is a real SHAPE with a made-up
/// token. No test here sends a request.
@Suite("Coordinate and map link parser")
struct CoordinateParserTests {
    enum Expect: Equatable {
        case point(Double, Double, name: String?)
        case swapped(Double, Double)
        case outOfRange
        case short(host: String)
        case noPoint
        case none
    }

    struct Case: CustomTestStringConvertible, Sendable {
        var input: String
        var expect: Expect
        var testDescription: String { String(input.prefix(70)) }
    }

    static func p(_ lat: Double, _ lon: Double, _ name: String? = nil) -> Expect { .point(lat, lon, name: name) }

    static func matches(_ result: CoordinateInput, _ expect: Expect) -> Bool {
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        switch (result, expect) {
        case (.point(let r), .point(let lat, let lon, let name)):
            return close(r.latitude, lat) && close(r.longitude, lon) && r.name == name
        case (.swapped(let r), .swapped(let lat, let lon)): return close(r.latitude, lat) && close(r.longitude, lon)
        case (.outOfRange, .outOfRange), (.noPoint, .noPoint), (.none, .none): return true
        case (.shortLink(let url), .short(let host)): return url.host == host
        default: return false
        }
    }

    // MARK: Typed coordinates

    static let typed: [Case] = [
        Case(input: "-45.12345, -120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "-45.12345 -120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "  -45.12345 ;  -120.54321 ", expect: p(-45.12345, -120.54321)),
        Case(input: "-45.12345;-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "-45,12345 -120,54321", expect: p(-45.12345, -120.54321)),
        Case(input: "-45,12345; -120,54321", expect: p(-45.12345, -120.54321)),
        Case(input: "-45,12345, -120,54321", expect: p(-45.12345, -120.54321)),
        Case(input: "-45.12345\u{2212} -120.5", expect: .none),
        Case(input: "\u{2212}45.12345, \u{2212}120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "+10.5, +20.25", expect: p(10.5, 20.25)),
        Case(input: "0, 0", expect: p(0, 0)),
        Case(input: "90, 180", expect: p(90, 180)),
        Case(input: "-90, -180", expect: p(-90, -180)),
        Case(input: "5 10", expect: p(5, 10)),
        Case(input: "45.12345 S, 120.54321 W", expect: p(-45.12345, -120.54321)),
        Case(input: "45.12345S 120.54321W", expect: p(-45.12345, -120.54321)),
        Case(input: "S45.12345 W120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "S 45.12345, W 120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "N 10.5 E 20.25", expect: p(10.5, 20.25)),
        Case(input: "n10.5, e20.25", expect: p(10.5, 20.25)),
        Case(input: "20.25 E 10.5 N", expect: p(10.5, 20.25)),
        Case(input: "45.12345\u{00B0} S, 120.54321\u{00B0} W", expect: p(-45.12345, -120.54321)),
        // A pair that only makes sense swapped is offered swapped, never applied.
        Case(input: "-120.54321, -45.12345", expect: .swapped(-45.12345, -120.54321)),
        Case(input: "120,25 45,5", expect: .swapped(45.5, 120.25)),
        Case(input: "150.5; 10.5", expect: .swapped(10.5, 150.5)),
        // Out of range.
        Case(input: "95.5, 200.5", expect: .outOfRange),
        Case(input: "-45.5, 181", expect: .outOfRange),
        Case(input: "91.5, 20.5", expect: .swapped(20.5, 91.5)),
        Case(input: "91.5, 120.5", expect: .outOfRange),
        Case(input: "N 95 E 20", expect: .outOfRange),
        Case(input: "120.5 N, 45.5 E", expect: .outOfRange),
        Case(input: "12345.5, 20.5", expect: .outOfRange),
        // Not coordinates: left to the completer.
        Case(input: "", expect: .none),
        Case(input: "   ", expect: .none),
        Case(input: "Test Cove", expect: .none),
        Case(input: "1 Test Lane", expect: .none),
        Case(input: "50", expect: .none),
        Case(input: "-45.1, -120.5, 7", expect: .none),
        Case(input: "1,2,3", expect: .none),
        Case(input: "1 2 3", expect: .none),
        Case(input: "-45,12345,-120,54321", expect: .none),
        Case(input: "NaN, 5", expect: .none),
        Case(input: "nan nan", expect: .none),
        Case(input: "inf, 5", expect: .none),
        Case(input: "-inf -inf", expect: .none),
        Case(input: "1e5, 2", expect: .none),
        Case(input: "0x10, 2", expect: .none),
        Case(input: "5.5.5, 2", expect: .none),
        Case(input: "500 600", expect: .none),
        Case(input: "123 45", expect: .none),
        Case(input: "N 50.1 N 30.2", expect: .none),
        Case(input: "E 50.1 W 30.2", expect: .none),
        Case(input: "-45.1 S, 10.2 E", expect: .none),
        Case(input: "NE 5 10", expect: .none),
        Case(input: "N 50.1 30.2", expect: .none),
        Case(input: "5,", expect: .none),
        Case(input: ",", expect: .none),
        Case(input: ";;;", expect: .none),
    ]

    @Test("Typed coordinates: shapes, letters, decimal comma, swapped, out of range, not coordinates", arguments: typed)
    func typedText(_ c: Case) {
        let result = CoordinateParser.parse(c.input)
        #expect(Self.matches(result, c.expect), "\(c.input) -> \(result)")
    }

    // MARK: geo: URIs

    static let geo: [Case] = [
        Case(input: "geo:-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "GEO:-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "geo:-45.12345,-120.54321,12.5", expect: p(-45.12345, -120.54321)),
        Case(input: "geo:-45.12345,-120.54321;crs=wgs84;u=35", expect: p(-45.12345, -120.54321)),
        Case(input: "geo:-45.12345,-120.54321?q=Test+Cove", expect: p(-45.12345, -120.54321, "Test Cove")),
        Case(input: "geo:0,0?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "geo:0,0?q=Test+Cove", expect: .noPoint),
        Case(input: "geo:95.5,20.5", expect: .outOfRange),
        Case(input: "geo:-45.12345", expect: .noPoint),
        Case(input: "geo:", expect: .noPoint),
        Case(input: "geo:NaN,5", expect: .noPoint),
        Case(input: "geo:1,2,x", expect: .noPoint),
        Case(input: "geo:1,2,3,4", expect: .noPoint),
        Case(input: "geo:45,12345,20,5", expect: .noPoint),
    ]

    @Test("geo: URIs", arguments: geo)
    func geoURIs(_ c: Case) {
        let result = CoordinateParser.parse(c.input)
        #expect(Self.matches(result, c.expect), "\(c.input) -> \(result)")
    }

    // MARK: Links (real shapes, invented points)

    static let links: [Case] = [
        // Apple Maps
        Case(input: "https://maps.apple.com/?ll=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.apple.com/?ll=-45.12345%2C-120.54321&q=Test%20Cove", expect: p(-45.12345, -120.54321, "Test Cove")),
        Case(input: "https://maps.apple.com/?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.apple.com/?coordinate=-45.12345,-120.54321&name=Test%20Cove", expect: p(-45.12345, -120.54321, "Test Cove")),
        Case(input: "https://maps.apple.com/?sll=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.apple.com/place?ll=-45.12345,-120.54321&name=Test+Cove&address=1+Test+Lane", expect: p(-45.12345, -120.54321, "Test Cove")),
        Case(input: "https://maps.apple.com/?ll=1.5,2.5&coordinate=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.apple.com/?ll=1.5,2.5&q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.apple.com/?sll=1.5,2.5&ll=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://MAPS.APPLE.COM/?ll=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.apple.com/?q=Test%20Cove", expect: .noPoint),
        Case(input: "https://maps.apple.com/", expect: .noPoint),
        Case(input: "https://maps.apple.com/?ll=95.5,200.5", expect: .outOfRange),
        Case(input: "https://maps.apple.com/?ll=NaN,5", expect: .noPoint),
        Case(input: "https://maps.apple.com/p/AbCd1234", expect: .short(host: "maps.apple.com")),
        Case(input: "https://maps.apple/p/AbCd1234", expect: .short(host: "maps.apple")),
        // Google Maps
        Case(input: "https://www.google.com/maps/place/Test+Cove/@-45.5,-120.5,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d-45.12345!4d-120.54321", expect: p(-45.12345, -120.54321, "Test Cove")),
        Case(input: "https://www.google.com/maps/place/Test+Cove/@-45.5,-120.5,17z", expect: p(-45.5, -120.5, "Test Cove")),
        Case(input: "https://www.google.com/maps/@-45.5,-120.5,15z", expect: p(-45.5, -120.5)),
        Case(input: "https://www.google.com/maps/place/Test%20Cove%2C+Reef/@-45.5,-120.5,17z/data=!3d-45.12345!4d-120.54321", expect: p(-45.12345, -120.54321, "Test Cove, Reef")),
        Case(input: "https://www.google.com/maps?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps?q=-45.12345%2C-120.54321&z=17", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.google.com/?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://maps.google.com/maps?ll=1,2&q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps/search/?api=1&query=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps/dir/?api=1&destination=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps/place/-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps/place/-45.12345,-120.54321/@-45.5,-120.5,17z", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps/search/-45.12345,+-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.co.uk/maps/place/Test+Cove/@-45.5,-120.5,17z", expect: p(-45.5, -120.5, "Test Cove")),
        Case(input: "https://www.google.com.ua/maps?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://google.de/maps?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.google.com/maps/place/Test+Cove/data=!4m2", expect: .noPoint),
        Case(input: "https://www.google.com/maps?q=Test+Cove", expect: .noPoint),
        Case(input: "https://www.google.com/maps/place/Test+Cove/@95.5,200.5,17z", expect: .outOfRange),
        Case(input: "https://www.google.com/maps/place/x/data=!3d95.5!4d10.5", expect: .outOfRange),
        Case(input: "https://maps.app.goo.gl/AbCd1234", expect: .short(host: "maps.app.goo.gl")),
        Case(input: "https://maps.app.goo.gl/AbCd1234?g_st=ic", expect: .short(host: "maps.app.goo.gl")),
        Case(input: "https://goo.gl/maps/AbCd1234", expect: .short(host: "goo.gl")),
        Case(input: "https://g.co/kgs/AbCd1234", expect: .short(host: "g.co")),
        Case(input: "https://maps.app.goo.gl/", expect: .noPoint),
        Case(input: "https://maps.app.goo.gl", expect: .noPoint),
        Case(input: "https://goo.gl/other/AbCd1234", expect: .noPoint),
        Case(input: "https://g.co/other", expect: .noPoint),
        // OpenStreetMap
        Case(input: "https://www.openstreetmap.org/?mlat=-45.12345&mlon=-120.54321#map=16/-45.5/-120.5", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.openstreetmap.org/?mlat=-45.12345&mlon=-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://www.openstreetmap.org/#map=16/-45.12345/-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "https://openstreetmap.org/#map=16/-45.12345/-120.54321&layers=N", expect: p(-45.12345, -120.54321)),
        Case(input: "https://osm.org/#map=5/-45.5/-120.5", expect: p(-45.5, -120.5)),
        Case(input: "https://www.openstreetmap.org/?mlat=95.5&mlon=10.5", expect: .outOfRange),
        Case(input: "https://www.openstreetmap.org/#map=16/95.5/10.5", expect: .outOfRange),
        Case(input: "https://www.openstreetmap.org/", expect: .noPoint),
        Case(input: "https://www.openstreetmap.org/#map=16/x/y", expect: .noPoint),
        Case(input: "https://osm.org/go/AbCd1234", expect: .short(host: "osm.org")),
        // Share text: a title before the link; a link without a scheme.
        Case(input: "Test Cove\nhttps://maps.app.goo.gl/AbCd1234", expect: .short(host: "maps.app.goo.gl")),
        Case(input: "https://maps.apple.com/?ll=-45.12345,-120.54321.", expect: p(-45.12345, -120.54321)),
        Case(input: "maps.apple.com/?ll=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "google.com/maps?q=-45.12345,-120.54321", expect: p(-45.12345, -120.54321)),
        Case(input: "maps.app.goo.gl/AbCd1234", expect: .short(host: "maps.app.goo.gl")),
    ]

    @Test("Full and short map links", arguments: links)
    func mapLinks(_ c: Case) {
        let result = CoordinateParser.parse(c.input)
        #expect(Self.matches(result, c.expect), "\(c.input) -> \(result)")
    }

    // MARK: Hostile input

    static let hostile: [Case] = [
        Case(input: "http://maps.apple.com/?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "HTTP://maps.google.com/?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "ftp://maps.apple.com/?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "javascript:alert(-45.12345,-120.54321)", expect: .noPoint),
        Case(input: "JavaScript:alert(1)//https://maps.apple.com/?ll=-45.1,-120.5", expect: .noPoint),
        Case(input: "data:text/html,-45.12345,-120.54321", expect: .noPoint),
        Case(input: "file:///maps?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://evil.example/maps?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://maps.apple.com.evil.example/?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://maps.google.com.evil.example/?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://google.com.evil.example/maps?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://www.google.evil/maps?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://notgoogle.com/maps?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://evil.example/https://maps.apple.com/?ll=-45.1,-120.5", expect: .noPoint),
        Case(input: "https://maps.apple.com@evil.example/?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://user:pw@maps.apple.com/?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://evil.example@maps.app.goo.gl/AbCd1234", expect: .noPoint),
        Case(input: "https://maps.apple.com:8443/?ll=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://www.google.com/search?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://www.google.com/?q=-45.12345,-120.54321", expect: .noPoint),
        Case(input: "https://consent.google.com/m?continue=https://www.google.com/maps/@-45.5,-120.5,17z", expect: .noPoint),
        Case(input: "https://goo.gl/AbCd1234", expect: .noPoint),
        Case(input: "https://maps.apple.com/?ll=-45.12345,-120.54321 and more", expect: p(-45.12345, -120.54321)),
        Case(input: "https://", expect: .noPoint),
        Case(input: "https:///maps", expect: .noPoint),
        Case(input: "https://www.google.com/maps/@NaN,inf,15z", expect: .noPoint),
        Case(input: "https://www.google.com/maps?q=inf,inf", expect: .noPoint),
        Case(input: "https://www.google.com/maps/place/x/data=!3dnan!4dinf", expect: .noPoint),
        Case(input: "https://www.google.com/maps?q=1,2,3,4", expect: .noPoint),
        Case(input: "https://maps.apple.com/?ll=1e5,2", expect: .noPoint),
        Case(input: "https://maps.apple.com/?ll=%00,%FF", expect: .noPoint),
        Case(input: "https://www.google.com/maps?q=" + String(repeating: "9", count: 5_000), expect: .noPoint),
        Case(input: "https://maps.apple.com/?ll=" + String(repeating: "1", count: 3_000) + ",5", expect: .noPoint),
        Case(input: "https://www.google.com/maps/" + String(repeating: "a/", count: 3_000) + "@-45.5,-120.5,17z", expect: .noPoint),
        Case(input: String(repeating: "9", count: 10_000), expect: .none),
        Case(input: String(repeating: "1,", count: 5_000), expect: .none),
        Case(input: String(repeating: "5 ", count: 5_000), expect: .none),
        Case(input: "geo:" + String(repeating: "1", count: 5_000) + ",5", expect: .noPoint),
        Case(input: "-45.1 " + String(repeating: "-120.5 ", count: 200), expect: .none),
        Case(input: String(repeating: "N", count: 5_000), expect: .none),
    ]

    @Test("Hostile and malformed input never gives a point", arguments: hostile)
    func hostileInput(_ c: Case) {
        let result = CoordinateParser.parse(c.input)
        #expect(Self.matches(result, c.expect), "\(c.testDescription) -> \(result)")
    }

    @Test("A point from a name-only place is never invented: names are cleaned and capped")
    func nameIsCleaned() {
        let long = String(repeating: "x", count: 500)
        guard case .point(let p) = CoordinateParser.parse("https://maps.apple.com/?ll=-45.1,-120.5&name=\(long)") else {
            Issue.record("no point")
            return
        }
        #expect(p.name?.count == CoordinateParser.maxNameLength)
        guard case .point(let c) = CoordinateParser.parse("https://maps.apple.com/?ll=-45.1,-120.5&name=%0A%00%09Test%20Cove%0A") else {
            Issue.record("no point")
            return
        }
        #expect(c.name == "Test Cove")
        guard case .point(let e) = CoordinateParser.parse("https://maps.apple.com/?ll=-45.1,-120.5&name=%20%20") else {
            Issue.record("no point")
            return
        }
        #expect(e.name == nil, "a blank name is no name: the card says Coordinates")
    }

    @Test("The subtitle is the values with a decimal point, five digits, in any locale")
    func formatted() {
        #expect(ParsedPoint(latitude: -45.123456, longitude: -120.5).formatted == "-45.12346, -120.50000")
        #expect(ParsedPoint(latitude: -0.0000001, longitude: 0).formatted == "0.00000, 0.00000")
    }

    @Test("Link-like text never goes to the completer; coordinates and words do")
    func linkLike() {
        for text in ["https://maps.apple.com/?ll=-45.1,-120.5", "http://x.example", "geo:-45.1,-120.5", "javascript:alert(1)",
                     "maps.app.goo.gl/AbCd1234", "Test Cove https://maps.app.goo.gl/AbCd1234", "ftp://x.example"] {
            #expect(CoordinateParser.isLinkLike(text), "\(text)")
        }
        for text in ["-45.12345, -120.54321", "Test Cove", "1 Test Lane", "N 10.5 E 20.25", "harbour", "evil.example/maps"] {
            #expect(!CoordinateParser.isLinkLike(text), "\(text)")
        }
    }
}

@Suite("Map link host allowlist")
struct MapLinkHostsTests {
    static let followed = [
        "https://maps.app.goo.gl/AbCd1234", "https://goo.gl/maps/AbCd1234", "https://g.co/kgs/AbCd1234",
        "https://www.google.com/maps/place/x/@-45.5,-120.5,17z", "https://google.com/maps?q=-45.1,-120.5",
        "https://maps.google.com/", "https://maps.google.com/maps?q=1,2", "https://www.google.co.uk/maps", "https://www.google.com.ua/maps/x",
        "https://maps.google.de/anything", "https://maps.apple.com/?ll=-45.1,-120.5", "https://maps.apple/p/AbCd1234",
        "https://www.openstreetmap.org/#map=1/2/3", "https://openstreetmap.org/", "https://osm.org/go/AbCd", "https://www.osm.org/",
        "https://MAPS.APP.GOO.GL/AbCd1234", "https://maps.apple.com:443/?ll=1,2", "https://maps.apple.com./?ll=1,2",
    ]
    static let refused = [
        "http://maps.app.goo.gl/AbCd1234", "ftp://maps.apple.com/", "javascript:alert(1)", "https://example.org/maps",
        "https://consent.google.com/m?continue=x", "https://accounts.google.com/ServiceLogin", "https://www.google.com/",
        "https://www.google.com/search?q=x", "https://www.google.com/mapsx", "https://google.com.evil.example/maps",
        "https://maps.google.com.evil.example/", "https://evilgoogle.com/maps", "https://goo.gl/other", "https://g.co/other",
        "https://www.google.xyz/maps", "https://www.google.co.uk.evil.example/maps", "https://sub.maps.apple.com/",
        "https://maps.apple.com.evil.example/", "https://maps.apple.com:8080/", "https://u@maps.apple.com/", "https://u:p@maps.apple.com/",
        "https://openstreetmap.org.evil.example/", "https://www.google.c/maps", "https://www.google.com.xyz1/maps",
    ]

    @Test("Hops that may be followed", arguments: followed)
    func followedHops(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(MapLinkHosts.mayFollow(url), "\(text)")
    }

    @Test("Hops that stop the resolver", arguments: refused)
    func refusedHops(_ text: String) {
        guard let url = URL(string: text) else { return }
        #expect(!MapLinkHosts.mayFollow(url), "\(text)")
    }

    @Test("The documented list names every allowlisted family")
    func documented() {
        #expect(MapLinkHosts.documented.count == 4)
    }
}
