/// Discriminator written into every event line's `kind` field.
///
/// Raw values are part of the on-disk format: rename the case if you like, never
/// the string.
public enum LogEventKind: String, Hashable, Sendable, Codable, CaseIterable {
    // v1
    case motion
    case location
    case obd
    case marker
    // v2
    case accelerometer = "accel"
    case gyroscope = "gyro"
    case magnetometer = "mag"
    case barometer = "baro"
    case elm
    case adapter
    case link
    case lifecycle
    case stats
    // v3
    case manualFix
}

/// One timestamped record in a recording.
///
/// Serialised as a single JSON object per line:
/// `{"data":{...},"kind":"motion","t":1500000}`.
public struct LogEvent: Hashable, Sendable, Codable {
    /// Offset from the session clock's reference instant. Same time base for
    /// every stream — see `SessionClock`.
    public var timestamp: MonotonicTimestamp
    public var payload: Payload

    public init(timestamp: MonotonicTimestamp, payload: Payload) {
        self.timestamp = timestamp
        self.payload = payload
    }

    public enum Payload: Hashable, Sendable {
        case motion(MotionSample)
        case location(LocationSample)
        case obd(OBDSample)
        /// Operator-inserted marker, e.g. "entered tunnel", "GPS lost".
        case marker(String)
        /// Raw accelerometer (gravity included), in g.
        case accelerometer(Vector3)
        /// Raw gyroscope (not bias-corrected), in rad/s.
        case gyroscope(Vector3)
        /// Raw uncalibrated magnetometer, in microtesla.
        case magnetometer(Vector3)
        case barometer(BarometerSample)
        case elm(ELMTrafficSample)
        case adapter(AdapterEventSample)
        case link(LinkSample)
        case lifecycle(LifecycleSample)
        case stats(StatsSample)
        /// A position the driver confirmed on the map (v3). `t` is the
        /// confirm time.
        case manualFix(ManualFixSample)

        /// A record whose `kind` this build doesn't know, with its payload kept
        /// verbatim so a round-trip through an older reader doesn't destroy
        /// data a newer writer produced.
        case unrecognized(kind: String, data: JSONValue?)

        public var kind: String {
            switch self {
            case .motion: LogEventKind.motion.rawValue
            case .location: LogEventKind.location.rawValue
            case .obd: LogEventKind.obd.rawValue
            case .marker: LogEventKind.marker.rawValue
            case .accelerometer: LogEventKind.accelerometer.rawValue
            case .gyroscope: LogEventKind.gyroscope.rawValue
            case .magnetometer: LogEventKind.magnetometer.rawValue
            case .barometer: LogEventKind.barometer.rawValue
            case .elm: LogEventKind.elm.rawValue
            case .adapter: LogEventKind.adapter.rawValue
            case .link: LogEventKind.link.rawValue
            case .lifecycle: LogEventKind.lifecycle.rawValue
            case .stats: LogEventKind.stats.rawValue
            case .manualFix: LogEventKind.manualFix.rawValue
            case .unrecognized(let kind, _): kind
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case kind
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(MonotonicTimestamp.self, forKey: .timestamp)
        let kind = try container.decode(String.self, forKey: .kind)

        switch LogEventKind(rawValue: kind) {
        case .motion:
            payload = .motion(try container.decode(MotionSample.self, forKey: .data))
        case .location:
            payload = .location(try container.decode(LocationSample.self, forKey: .data))
        case .obd:
            payload = .obd(try container.decode(OBDSample.self, forKey: .data))
        case .marker:
            payload = .marker(try container.decode(String.self, forKey: .data))
        case .accelerometer:
            payload = .accelerometer(try container.decode(Vector3.self, forKey: .data))
        case .gyroscope:
            payload = .gyroscope(try container.decode(Vector3.self, forKey: .data))
        case .magnetometer:
            payload = .magnetometer(try container.decode(Vector3.self, forKey: .data))
        case .barometer:
            payload = .barometer(try container.decode(BarometerSample.self, forKey: .data))
        case .elm:
            payload = .elm(try container.decode(ELMTrafficSample.self, forKey: .data))
        case .adapter:
            payload = .adapter(try container.decode(AdapterEventSample.self, forKey: .data))
        case .link:
            payload = .link(try container.decode(LinkSample.self, forKey: .data))
        case .lifecycle:
            payload = .lifecycle(try container.decode(LifecycleSample.self, forKey: .data))
        case .stats:
            payload = .stats(try container.decode(StatsSample.self, forKey: .data))
        case .manualFix:
            payload = .manualFix(try container.decode(ManualFixSample.self, forKey: .data))
        case nil:
            payload = .unrecognized(
                kind: kind,
                data: try container.decodeIfPresent(JSONValue.self, forKey: .data)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(payload.kind, forKey: .kind)

        switch payload {
        case .motion(let sample):
            try container.encode(sample, forKey: .data)
        case .location(let sample):
            try container.encode(sample, forKey: .data)
        case .obd(let sample):
            try container.encode(sample, forKey: .data)
        case .marker(let text):
            try container.encode(text, forKey: .data)
        case .accelerometer(let vector), .gyroscope(let vector), .magnetometer(let vector):
            try container.encode(vector, forKey: .data)
        case .barometer(let sample):
            try container.encode(sample, forKey: .data)
        case .elm(let sample):
            try container.encode(sample, forKey: .data)
        case .adapter(let sample):
            try container.encode(sample, forKey: .data)
        case .link(let sample):
            try container.encode(sample, forKey: .data)
        case .lifecycle(let sample):
            try container.encode(sample, forKey: .data)
        case .stats(let sample):
            try container.encode(sample, forKey: .data)
        case .manualFix(let sample):
            try container.encode(sample, forKey: .data)
        case .unrecognized(_, let data):
            try container.encodeIfPresent(data, forKey: .data)
        }
    }
}

extension LogEvent {
    public static func motion(_ sample: MotionSample, at timestamp: MonotonicTimestamp) -> LogEvent {
        LogEvent(timestamp: timestamp, payload: .motion(sample))
    }

    public static func location(_ sample: LocationSample, at timestamp: MonotonicTimestamp) -> LogEvent {
        LogEvent(timestamp: timestamp, payload: .location(sample))
    }

    public static func obd(_ sample: OBDSample, at timestamp: MonotonicTimestamp) -> LogEvent {
        LogEvent(timestamp: timestamp, payload: .obd(sample))
    }

    public static func marker(_ text: String, at timestamp: MonotonicTimestamp) -> LogEvent {
        LogEvent(timestamp: timestamp, payload: .marker(text))
    }
}
