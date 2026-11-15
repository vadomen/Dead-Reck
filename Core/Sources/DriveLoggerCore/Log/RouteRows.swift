import Foundation

/// `route` (format v7): a route was set or replaced (docs/ROUTING_PLAN.md,
/// prompt 51 item D). The row embeds the whole `Route` in its own JSON
/// (`Route`'s doc: `polylineE7` fixed-point deltas, the provider's steps,
/// length and time), so a replay sees exactly the route the driver followed
/// from `t` on, without asking the provider again.
///
/// `t` is when the route took effect, on the session clock (`clock.now()`:
/// a route has no uptime of its own). A later `route` row replaces the
/// route without a `routeCleared` row in between; `routeCleared` ends it.
///
/// ```json
/// {"data":{"origin":{"latitude":-45.00012,"longitude":-120.00003,"source":"fix"},"reason":"user","route":{…}},"kind":"route","t":1500000000}
/// ```
///
/// A route is guidance, not a measurement: neither the polyline nor
/// `origin` is a sensor reading, a reference fix or an engine input.
///
/// An on-disk type: every stored property name is a JSON key and part of
/// the format. `reason` is an open vocabulary: a string this build does not
/// know decodes to `.unknown` and is written back verbatim.
public struct RouteSample: Hashable, Sendable, Codable {
    /// Why the route was set.
    public var reason: Reason
    /// The route, in `Route`'s own JSON (key `route`).
    public var route: Route
    /// Where the route request started (the position the app gave the
    /// provider as the start of the trip, and where it took it from);
    /// absent when there was no request
    /// (a route restored from storage) or the app did not record it.
    public var origin: RouteOrigin?

    public init(reason: Reason, route: Route, origin: RouteOrigin? = nil) {
        self.reason = reason
        self.route = route
        self.origin = origin
    }

    /// `reason` vocabulary. The raw strings are on disk: never change one.
    /// Equality and hashing go by `rawValue`, so `.unknown("user")` equals
    /// `.user`; build values with `init(rawValue:)` to get the canonical case.
    public enum Reason: Sendable, CustomStringConvertible {
        /// The driver chose a destination and the route was built.
        case user
        /// The car left the route and the route was rebuilt from where it is.
        case offRoute
        /// The driver switched to an alternative the provider offered.
        case alternative
        /// A route the app had before (a relaunch, a restored session) was
        /// put back without a new request.
        case restored
        /// A reason this build does not know; the string is kept.
        case unknown(String)

        /// Every reason this build writes, in format order.
        public static let known: [Reason] = [.user, .offRoute, .alternative, .restored]

        public init(rawValue: String) {
            switch rawValue {
            case "user": self = .user
            case "offRoute": self = .offRoute
            case "alternative": self = .alternative
            case "restored": self = .restored
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .user: "user"
            case .offRoute: "offRoute"
            case .alternative: "alternative"
            case .restored: "restored"
            case .unknown(let value): value
            }
        }

        public var description: String { rawValue }
    }
}

/// `routeCleared` (format v7): the route ended and no route replaced it.
/// `t` is when it ended, on the session clock (`clock.now()`).
///
/// ```json
/// {"data":{"reason":"arrived","routeID":"r1"},"kind":"routeCleared","t":8000000000}
/// ```
///
/// `routeID` is the `id` of the route that ended: the one set by the latest
/// `route` row, so a recording with several rebuilds shows which one ended.
///
/// An on-disk type: every stored property name is a JSON key and part of
/// the format. `reason` is an open vocabulary, as for `RouteSample`.
public struct RouteClearedSample: Hashable, Sendable, Codable {
    /// Why the route ended.
    public var reason: Reason
    /// `Route.id` of the route that ended.
    public var routeID: String

    public init(reason: Reason, routeID: String) {
        self.reason = reason
        self.routeID = routeID
    }

    /// `reason` vocabulary. The raw strings are on disk: never change one.
    /// Equality and hashing go by `rawValue`, as for `RouteSample.Reason`.
    public enum Reason: Sendable, CustomStringConvertible {
        /// The car reached the destination.
        case arrived
        /// The driver ended the route.
        case cancelled
        /// The route could not be kept (a rebuild failed, the provider
        /// refused); the app dropped it.
        case failed
        /// A reason this build does not know; the string is kept.
        case unknown(String)

        /// Every reason this build writes, in format order.
        public static let known: [Reason] = [.arrived, .cancelled, .failed]

        public init(rawValue: String) {
            switch rawValue {
            case "arrived": self = .arrived
            case "cancelled": self = .cancelled
            case "failed": self = .failed
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .arrived: "arrived"
            case .cancelled: "cancelled"
            case .failed: "failed"
            case .unknown(let value): value
            }
        }

        public var description: String { rawValue }
    }
}

/// The start of a route request, degrees WGS 84, under the same keys as
/// every other position in the log (`manualFix`, `navPrior`, `location`):
/// `latitude`, `longitude`, plus `source`, where the app took the position
/// from. Not a fix and not an engine input: only what the app asked the
/// provider to route from, even when `source` is `fix`.
///
/// ```json
/// {"latitude":-45.00012,"longitude":-120.00003,"source":"fix"}
/// ```
public struct RouteOrigin: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double
    /// Where the position came from; omitted when the app does not know.
    public var source: Source?

    public init(latitude: Double, longitude: Double, source: Source? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
    }

    /// `source` vocabulary. The raw strings are on disk: never change one.
    /// Equality and hashing go by `rawValue`, as for `RouteSample.Reason`.
    public enum Source: Sendable, CustomStringConvertible {
        /// A location fix (the reference GNSS stream's latest `location`).
        case fix
        /// The navigator's estimate.
        case estimate
        /// A position the driver marked on the map (a manual fix).
        case pin
        /// A source this build does not know; the string is kept.
        case unknown(String)

        /// Every source this build writes, in format order.
        public static let known: [Source] = [.fix, .estimate, .pin]

        public init(rawValue: String) {
            switch rawValue {
            case "fix": self = .fix
            case "estimate": self = .estimate
            case "pin": self = .pin
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .fix: "fix"
            case .estimate: "estimate"
            case .pin: "pin"
            case .unknown(let value): value
            }
        }

        public var description: String { rawValue }
    }

    /// Finite and within ±90° / ±180°. Decoding does not check it (the row
    /// decodes as written, like every other sample); `inspect_log` warns.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

// MARK: - Coding of the open vocabularies

extension RouteSample.Reason: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

extension RouteSample.Reason: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RouteOrigin.Source: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

extension RouteOrigin.Source: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RouteClearedSample.Reason: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

extension RouteClearedSample.Reason: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
