import Foundation
import Testing

@testable import DriveLoggerCore

/// The optional `destination` of a v7 `route` row (prompt 53a item 3; no
/// version bump): same shape and checks as `origin`. Invented coordinates in
/// open ocean only. The frozen v7 fixture is untouched: these rows are new.
@Suite("Route row destination (v7, optional)")
struct RouteDestinationTests {
    static let line = #"{"data":{"destination":{"latitude":-45.0031,"longitude":-120.0007,"source":"coordinates"},"#
        + #""origin":{"latitude":-45.00012,"longitude":-120.00003,"source":"fix"},"reason":"user","route":"#
        + RouteCodingTests.smallJSON + #"},"kind":"route","t":1500000000}"#

    static func sample(destination: RouteDestination?, origin: RouteOrigin? = nil) throws -> RouteSample {
        RouteSample(reason: .user, route: try RouteCodingTests.small(), origin: origin, destination: destination)
    }

    static func event(_ sample: RouteSample) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(nanoseconds: 1_500_000_000), payload: .route(sample))
    }

    @Test("A row with a destination round-trips and its bytes are sorted-key stable")
    func roundTrip() throws {
        let sample = try Self.sample(
            destination: RouteDestination(latitude: -45.0031, longitude: -120.0007, source: .coordinates),
            origin: RouteOrigin(latitude: -45.00012, longitude: -120.00003, source: .fix))
        let codec = LogCodec()
        let bytes = try codec.line(for: Self.event(sample))
        #expect(String(decoding: bytes.dropLast(), as: UTF8.self) == Self.line)
        let decoded = try codec.event(from: Data(Self.line.utf8))
        #expect(decoded.payload == .route(sample))
        #expect(try codec.line(for: decoded) == bytes)
    }

    @Test("A row without a destination encodes byte-identically to before: no destination key at all")
    func absentIsByteIdentical() throws {
        let codec = LogCodec()
        let plain = try codec.line(for: Self.event(Self.sample(destination: nil, origin: RouteOrigin(latitude: -45.00012, longitude: -120.00003, source: .fix))))
        let text = String(decoding: plain, as: UTF8.self)
        #expect(!text.contains("destination"))
        #expect(text == #"{"data":{"origin":{"latitude":-45.00012,"longitude":-120.00003,"source":"fix"},"reason":"user","route":"#
            + RouteCodingTests.smallJSON + #"},"kind":"route","t":1500000000}"# + "\n")
        // A destination without a source omits the source key.
        let bare = try codec.line(for: Self.event(Self.sample(destination: RouteDestination(latitude: 1, longitude: 2))))
        #expect(String(decoding: bare, as: UTF8.self).contains(#""destination":{"latitude":1,"longitude":2}"#))
        // An old row (no key) decodes to nil.
        let old = #"{"data":{"reason":"user","route":"# + RouteCodingTests.smallJSON + #"},"kind":"route","t":0}"#
        guard case .route(let s) = try codec.event(from: Data(old.utf8)).payload else { Issue.record("not a route"); return }
        #expect(s.destination == nil)
    }

    @Test("An unknown source is kept verbatim; the known ones are not unknown")
    func openSource() throws {
        let json = Self.line.replacingOccurrences(of: #""source":"coordinates""#, with: #""source":"voice""#)
        let codec = LogCodec()
        guard case .route(let s) = try codec.event(from: Data(json.utf8)).payload else { Issue.record("not a route"); return }
        #expect(s.destination?.source == .unknown("voice"))
        #expect(String(decoding: try codec.line(for: Self.event(s)), as: UTF8.self).contains(#""source":"voice""#))
        for source in RouteDestination.Source.known {
            if case .unknown = RouteDestination.Source(rawValue: source.rawValue) { Issue.record("\(source) parsed as unknown") }
        }
        #expect(RouteDestination.Source.known.map(\.rawValue) == ["search", "pin", "coordinates", "link", "saved", "recent"])
    }

    @Test("An out-of-range destination is checked like the origin: it decodes as written, isValid is false and inspect_log warns")
    func rangeLikeOrigin() throws {
        #expect(RouteDestination(latitude: 90, longitude: -180).isValid)
        #expect(!RouteDestination(latitude: 91, longitude: 0).isValid)
        #expect(!RouteDestination(latitude: 0, longitude: 180.5).isValid)
        #expect(!RouteDestination(latitude: .nan, longitude: 0).isValid)
        let json = Self.line.replacingOccurrences(of: #""latitude":-45.0031"#, with: #""latitude":-95.5"#)
        let event = try LogCodec().event(from: Data(json.utf8))
        guard case .route(let s) = event.payload else { Issue.record("not a route"); return }
        #expect(s.destination?.latitude == -95.5)
        #expect(RouteRowTests.analyze([event]).healthWarnings == ["1 route row(s) with a destination out of range"])
        #expect(RouteRowTests.analyze([Self.event(try Self.sample(destination: RouteDestination(latitude: -45, longitude: -120)))]).healthWarnings.isEmpty)
    }

    @Test("A malformed destination (a string for a number, a missing key) fails the row like a malformed origin")
    func malformed() {
        for bad in [#""latitude":"x""#, #""latitude":-45.0031,"longitude":null"#] {
            let json = Self.line.replacingOccurrences(of: #""latitude":-45.0031,"longitude":-120.0007"#, with: bad)
            #expect(throws: (any Error).self) { try LogCodec().event(from: Data(json.utf8)) }
        }
    }

    @Test("route.csv appends destinationLatitude, destinationLongitude, destinationSource at the end")
    func csv() throws {
        let with = Self.event(try Self.sample(destination: RouteDestination(latitude: -45.0031, longitude: -120.0007, source: .link)))
        let values = RecordingCSV.values(for: with)
        #expect(values.suffix(3) == ["-45.0031", "-120.0007", "link"])
        #expect(values[12] == RouteCodingTests.smallJSON)
        #expect(RecordingCSV.values(for: Self.event(try Self.sample(destination: nil))).suffix(3) == ["", "", ""])
        #expect(RecordingCSV.columns(for: "route").suffix(3) == ["destinationLatitude", "destinationLongitude", "destinationSource"])
    }
}
