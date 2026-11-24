import Foundation

/// The destination of a route request (`route` row, key `destination`),
/// degrees WGS 84, in the same shape as `RouteOrigin`: `latitude`,
/// `longitude`, plus `source`, how the app got the place. The place as the
/// driver named it, never snapped; the route's own end may be elsewhere
/// (the provider routes to the nearest road). Optional in the row: absent
/// means unknown, and a row without it encodes byte for byte as before.
///
/// ```json
/// {"latitude":-45.0031,"longitude":-120.0007,"source":"coordinates"}
/// ```
public struct RouteDestination: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double
    /// How the place was chosen; omitted when the app does not know.
    public var source: Source?

    public init(latitude: Double, longitude: Double, source: Source? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
    }

    /// `source` vocabulary (open set). The raw strings are on disk: never
    /// change one. Equality and hashing go by `rawValue`.
    public enum Source: Sendable, CustomStringConvertible {
        /// A search result (a completion the driver picked).
        case search
        /// A long press on the map (a dropped pin).
        case pin
        /// Typed or pasted coordinates (including a `geo:` URI).
        case coordinates
        /// A pasted map link.
        case link
        /// Home or Work.
        case saved
        /// A recent destination.
        case recent
        /// A source this build does not know; the string is kept.
        case unknown(String)

        /// Every source this build writes, in format order.
        public static let known: [Source] = [.search, .pin, .coordinates, .link, .saved, .recent]

        public init(rawValue: String) {
            switch rawValue {
            case "search": self = .search
            case "pin": self = .pin
            case "coordinates": self = .coordinates
            case "link": self = .link
            case "saved": self = .saved
            case "recent": self = .recent
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .search: "search"
            case .pin: "pin"
            case .coordinates: "coordinates"
            case .link: "link"
            case .saved: "saved"
            case .recent: "recent"
            case .unknown(let value): value
            }
        }

        public var description: String { rawValue }
    }

    /// Finite and within ±90° / ±180°. Decoding does not check it, as for
    /// `RouteOrigin` (the row decodes as written); `inspect_log` warns.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

extension RouteDestination.Source: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

extension RouteDestination.Source: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
