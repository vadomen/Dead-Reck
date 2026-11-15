import Foundation
import Testing

@testable import DriveLoggerCore

/// The v7 `route` and `routeCleared` rows (prompt 51 item D): open reason
/// vocabularies, malformed rows, the gzip reader, size, and what
/// `inspect_log` and the CSV export make of them. The frozen fixture and
/// golden bytes are in `LogFormatCompatibilityV7Tests`. Synthetic routes in
/// open ocean only.
@Suite("Route rows (v7)")
struct RouteRowTests {
    typealias F = RouteFixture
    typealias V7 = LogFormatCompatibilityV7Tests

    static let clean = LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: [])

    static func analyze(_ events: [LogEvent], version: LogFormatVersion = .v7) -> RecordingSummary {
        var header = AnalysisFixtures.header
        header.formatVersion = version
        var analyzer = RecordingAnalyzer(header: header)
        for event in events { analyzer.observe(event) }
        return analyzer.summary(report: clean)
    }

    static func route(_ id: String, _ reason: RouteSample.Reason = .user, distanceM: Double = 100,
                      origin: RouteOrigin? = nil) throws -> RouteSample {
        let points = [RoutePoint(latE7: -450_000_000, lonE7: -1_200_000_000), RoutePoint(latE7: -449_990_000, lonE7: -1_200_000_000)]
        let route = try Route(id: id, polyline: points, steps: [], distanceM: distanceM, expectedTravelTimeS: 10, source: .synthetic)
        return RouteSample(reason: reason, route: route, origin: origin)
    }

    static func at(_ ms: Int64, _ payload: LogEvent.Payload) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(nanoseconds: ms * 1_000_000), payload: payload)
    }

    // MARK: Vocabularies

    @Test("Unknown reasons decode without throwing, keep their string and compare by it")
    func openVocabularies() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RouteSample.Reason.self, from: Data(#""rerouteByVoice""#.utf8)) == .unknown("rerouteByVoice"))
        #expect(try decoder.decode(RouteClearedSample.Reason.self, from: Data(#""expired""#.utf8)).rawValue == "expired")
        #expect(RouteSample.Reason.unknown("offRoute") == .offRoute)
        #expect(RouteSample.Reason.unknown("offRoute").hashValue == RouteSample.Reason.offRoute.hashValue)
        #expect(RouteClearedSample.Reason.unknown("arrived") == .arrived)
        for reason in RouteSample.Reason.known {
            #expect(RouteSample.Reason(rawValue: reason.rawValue) == reason)
            if case .unknown = RouteSample.Reason(rawValue: reason.rawValue) { Issue.record("\(reason) parsed as unknown") }
        }
        for reason in RouteClearedSample.Reason.known {
            if case .unknown = RouteClearedSample.Reason(rawValue: reason.rawValue) { Issue.record("\(reason) parsed as unknown") }
        }
        // Case-sensitive: a near miss is a different, unknown string.
        if case .unknown("User") = RouteSample.Reason(rawValue: "User") {} else { Issue.record("User is not user") }
    }

    @Test("The origin is checked for range, not on decode: an invalid one decodes and inspect_log warns")
    func originRange() throws {
        #expect(RouteOrigin(latitude: -45, longitude: -120).isValid)
        #expect(RouteOrigin(latitude: 90, longitude: -180).isValid)
        #expect(!RouteOrigin(latitude: -180, longitude: -180).isValid, "an invalid provider coordinate")
        #expect(!RouteOrigin(latitude: 0, longitude: 180.5).isValid)
        #expect(!RouteOrigin(latitude: .nan, longitude: 0).isValid)

        let line = #"{"data":{"origin":{"latitude":-180,"longitude":-180},"reason":"user","route":"#
            + RouteCodingTests.smallJSON + #"},"kind":"route","t":0}"#
        let event = try LogCodec().event(from: Data(line.utf8))
        guard case .route(let sample) = event.payload else {
            Issue.record("not a route row")
            return
        }
        #expect(sample.origin == RouteOrigin(latitude: -180, longitude: -180))
        #expect(Self.analyze([event]).healthWarnings == ["1 route row(s) with an origin out of range"])
    }

    // MARK: Reading

    @Test("A route row whose route is malformed is one malformed line: strict stops, recovery skips only it")
    func malformedRouteRow() throws {
        let lines = V7.version7Recording.split(separator: "\n").map(String.init)
        let routeLine = try #require(lines.firstIndex { $0.contains(#""id":"r2""#) })
        var broken = lines
        // An odd polylineE7 (RouteError.oddPolylineArray).
        broken[routeLine] = broken[routeLine].replacingOccurrences(of: "-2000,0,0,2500]", with: "-2000,0,0]")
        #expect(broken[routeLine] != lines[routeLine])
        let data = Data(broken.joined(separator: "\n").utf8)

        #expect(throws: LogDecodingError.self) { try LogCodec().document(from: data, recovery: .strict) }
        let recovered = try LogCodec().document(from: data, recovery: .skipMalformedLines)
        #expect(recovered.skippedLineIndices == [routeLine])
        #expect(recovered.events.count == 14)
        #expect(V7.routes(recovered.events).map(\.sample.route.id) == ["r1", "r3", "r4", "r5", "r6"])
    }

    @Test("Route rows survive the gzip writer's members, and a cut inside the last member keeps the earlier ones")
    func gzipAndTruncatedTail() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let big = try F.route(F.wandering(count: 400, spacingM: 75, turnEvery: 40), breaks: [40, 80, 120], id: "big")
        let first = [Self.at(1_000, .route(try Self.route("a"))), Self.at(2_000, .routeCleared(RouteClearedSample(reason: .cancelled, routeID: "a")))]
        let second = [Self.at(3_000, .route(RouteSample(reason: .offRoute, route: big, origin: RouteOrigin(latitude: -45, longitude: -120))))]
        let (bytes, starts) = try RecordingBytes.gzip([first, second])

        let url = scratch.file("routes.jsonl.gz")
        try bytes.write(to: url)
        let whole = try WriterFixtures.read(url)
        #expect(whole.events == first + second)
        #expect(!whole.report.truncatedTail)

        let lastStart = try #require(starts.last)
        for cut in stride(from: lastStart + 1, to: bytes.count, by: max(1, (bytes.count - lastStart) / 17)) {
            try bytes.prefix(cut).write(to: url)
            let read = try WriterFixtures.read(url)
            #expect(read.events == first, "cut at \(cut)")
            #expect(read.report.truncatedTail, "cut at \(cut)")
        }
    }

    // MARK: Size

    /// A 30 km route as one row. The R1 spike's MapKit routes had 150–430
    /// vertices per 30 km outside short residential trips (up to about 850
    /// per 30 km there) and 4–20 steps. Measured here: a spike-like route
    /// (400 points at 75 m, 12 steps, English instructions of about 32
    /// characters) is 5 945 bytes; a dense one (600 points at 50 m, 20 steps,
    /// Ukrainian instructions of 39 characters, mostly two bytes each in
    /// UTF-8) is 9 813 bytes. Both with a UUID id, a label and an origin.
    @Test("A 30 km route row is one line of 5–7 KB (spike-like) and at most 10 KiB (dense)")
    func thirtyKilometreRow() throws {
        let codec = LogCodec()
        let origin = RouteOrigin(latitude: -45.0001234, longitude: -120.0004321)

        let typical = try F.route(F.wandering(count: 400, spacingM: 75, turnEvery: 33),
                                  breaks: Array(stride(from: 33, to: 400, by: 33).prefix(10)),
                                  id: "6F1C2B9A-0D4E-4C55-9A61-3B8E2F7D1C04", label: "Destination") {
            "Turn right onto Example Avenue \($0)"
        }
        #expect(typical.steps.count == 12)
        #expect((29_000...31_000).contains(try RoutePolyline(typical.polyline).lengthM))
        let typicalLine = try codec.line(for: Self.at(1, .route(RouteSample(reason: .user, route: typical, origin: origin))))
        #expect((5_000...7_000).contains(typicalLine.count), "\(typicalLine.count) bytes")

        let dense = try F.route(F.wandering(count: 600, spacingM: 50, turnEvery: 30),
                                breaks: Array(stride(from: 30, to: 600, by: 30).prefix(18)),
                                id: "6F1C2B9A-0D4E-4C55-9A61-3B8E2F7D1C05", label: "Destination") { _ in
            "Поверніть праворуч на вулицю Приклад 12" // 39 characters, as a uk-locale step reads
        }
        #expect(dense.steps.count == 20)
        #expect((29_000...31_000).contains(try RoutePolyline(dense.polyline).lengthM))
        let denseLine = try codec.line(for: Self.at(1, .route(RouteSample(reason: .offRoute, route: dense, origin: origin))))
        #expect(denseLine.count <= 10_240, "\(denseLine.count) bytes")
        #expect(denseLine.filter { $0 == UInt8(ascii: "\n") }.count == 1, "one line")
        #expect(try codec.event(from: denseLine.dropLast()).payload == .route(RouteSample(reason: .offRoute, route: dense, origin: origin)))
    }

    // MARK: inspect_log

    @Test("The v7 fixture's summary: one route line with counts, total and reasons; healthy; no coordinates")
    func fixtureSummary() throws {
        let document = try LogCodec().document(from: Data(V7.version7Recording.utf8))
        var analyzer = RecordingAnalyzer(header: document.header)
        for event in document.events { analyzer.observe(event) }
        let summary = analyzer.summary(report: Self.clean)
        #expect(summary.routes.count == 6)
        #expect(summary.routeClears.count == 4)
        #expect(summary.healthWarnings.isEmpty, "\(summary.healthWarnings)")

        let text = summary.render()
        #expect(text.contains("\nRoutes        6 set (user 2, offRoute 1, alternative 1, restored 1, detour 1), 1.34 km in total; cleared 4 (arrived 1, cancelled 1, failed 1, superseded 1)\n"), "\(text)")
        // The kind column widens to the longest name (`routeProgress`, 13),
        // so `routeCleared` is not cut; with short names it stays 10 wide.
        #expect(text.contains("\n  kind           count     rate Hz  max gap ms"), "\(text)")
        #expect(text.contains("\n  routeCleared       4 "), "\(text)")
        #expect(Self.analyze([Self.at(0, .lifecycle(LifecycleSample(.start)))]).render()
            .contains("\n  kind        count     rate Hz  max gap ms  gaps>50ms  gap total ms  out-of-order\n  lifecycle       1 "))
        // Today's summary prints no position for these rows; the route line
        // adds none (not even the route's label or ids).
        for needle in ["-45", "-120", "-119", "Harbour", "r1", "Tournez"] {
            #expect(!text.contains(needle), "\(needle) in the summary")
        }
    }

    @Test("No route rows: a v7 recording says none, an older one says nothing")
    func noRoutes() {
        #expect(Self.analyze([]).render().contains("Routes        none\n"))
        #expect(!Self.analyze([], version: .v6).render().contains("Routes"))
    }

    @Test("Route rows in an older-labelled file are still summarised; only clears, or only routes, read sensibly")
    func partialLines() throws {
        let onlyRoutes = Self.analyze([Self.at(1, .route(try Self.route("a", distanceM: 30_250))),
                                       Self.at(2, .route(try Self.route("b", .offRoute, distanceM: 28_000)))], version: .v6)
        #expect(onlyRoutes.routeLine == "2 set (user 1, offRoute 1), 58.25 km in total; cleared 0")
        let onlyClear = Self.analyze([Self.at(1, .routeCleared(RouteClearedSample(reason: .failed, routeID: "x")))])
        #expect(onlyClear.routeLine == "0 set, 0.00 km in total; cleared 1 (failed 1)")
    }

    @Test("A clear that names a route other than the active one, or with none active, warns")
    func clearMismatch() throws {
        let summary = Self.analyze([
            Self.at(1_000, .route(try Self.route("a"))),
            Self.at(2_000, .route(try Self.route("b", .offRoute))),
            Self.at(3_000, .routeCleared(RouteClearedSample(reason: .arrived, routeID: "a"))),
            Self.at(4_000, .routeCleared(RouteClearedSample(reason: .cancelled, routeID: "b"))),
            Self.at(5_000, .route(try Self.route("c"))),
            Self.at(6_000, .routeCleared(RouteClearedSample(reason: .cancelled, routeID: "c"))),
        ])
        #expect(summary.routeClears.map(\.activeRouteID) == ["b", nil, "c"])
        #expect(summary.healthWarnings == [
            #"routeCleared at 3.000 s ends route "a", but route "b" was active"#,
            #"routeCleared at 4.000 s ends route "b", but no route was active"#,
        ])
    }

    // MARK: CSV

    @Test("route.csv: one row per route row with its scalars, sizes, origin and the route's own JSON; routeCleared.csv: t, reason, routeID")
    func csv() throws {
        #expect(RecordingCSV.columns(for: "route") == [
            "t", "reason", "routeID", "source", "label", "distanceM", "expectedTravelTimeS", "points", "steps",
            "originLatitude", "originLongitude", "route",
        ])
        #expect(RecordingCSV.columns(for: "routeCleared") == ["t", "reason", "routeID"])

        let small = try RouteCodingTests.small()
        let withOrigin = Self.at(1_500, .route(RouteSample(reason: .user, route: small, origin: RouteOrigin(latitude: -45.00012, longitude: -120.00003))))
        #expect(RecordingCSV.values(for: withOrigin) == [
            "1500000000", "user", "r1", "synthetic", "Home", "99.5", "20.0", "3", "3", "-45.00012", "-120.00003",
            RouteCodingTests.smallJSON,
        ])
        let bare = Self.at(0, .route(RouteSample(reason: .unknown("detour"), route: try RouteCodingTests.small(label: nil))))
        let values = RecordingCSV.values(for: bare)
        #expect(values[1] == "detour" && values[4] == "" && values[9] == "" && values[10] == "")
        // The JSON cell is quoted RFC 4180-style and decodes back to the route.
        #expect(RecordingCSV.line(values).contains(#","{""distanceM"":99.5,"#))
        #expect(try JSONDecoder().decode(Route.self, from: Data(values[11].utf8)) == (try RouteCodingTests.small(label: nil)))

        let cleared = Self.at(8_000, .routeCleared(RouteClearedSample(reason: .unknown("expired"), routeID: "r5")))
        #expect(RecordingCSV.values(for: cleared) == ["8000000000", "expired", "r5"])
        #expect(RecordingCSV.fileName(for: "route") == "route.csv")
        #expect(RecordingCSV.fileName(for: "routeCleared") == "routeCleared.csv")
    }
}
