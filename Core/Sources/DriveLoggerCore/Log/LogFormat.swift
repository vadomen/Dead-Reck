import Foundation

/// Version of the on-disk log format.
///
/// A recording is research data with an indefinite shelf life, so every version
/// ever written must stay decodable. Adding a version means adding a case here,
/// bumping `current`, and teaching `LogCodec` how to read the old one — never
/// repurposing or removing an existing field.
public enum LogFormatVersion: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case v1 = 1

    /// The version new recordings are written in.
    public static let current: LogFormatVersion = .v1

    public static func < (lhs: LogFormatVersion, rhs: LogFormatVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which build produced a recording.
public struct AppIdentity: Hashable, Sendable, Codable {
    public var name: String
    public var version: String
    public var build: String

    public init(name: String, version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }
}

/// Which hardware produced a recording. Sensor noise characteristics are
/// model-specific, so this is needed to compare drives.
public struct DeviceIdentity: Hashable, Sendable, Codable {
    public var model: String
    public var systemName: String
    public var systemVersion: String

    public init(model: String, systemName: String, systemVersion: String) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
    }
}

/// First line of every log file.
///
/// Everything a reader needs to interpret the rest of the file lives here, so a
/// recording is self-describing with no sidecar metadata to lose.
public struct LogHeader: Hashable, Sendable, Codable {
    public var formatVersion: LogFormatVersion
    public var sessionID: UUID

    /// Wall clock at session start — the only wall-clock value in the file.
    public var startedAt: Date

    /// The session clock's reference uptime. Event timestamps are nanosecond
    /// offsets from this, letting a recording be re-aligned against other
    /// uptime-stamped data captured on the same device.
    public var referenceUptimeSeconds: Double

    public var app: AppIdentity
    public var device: DeviceIdentity

    /// Free-text note about the drive (route, mounting position, weather).
    public var notes: String?

    public init(
        formatVersion: LogFormatVersion = .current,
        sessionID: UUID,
        startedAt: Date,
        referenceUptimeSeconds: Double,
        app: AppIdentity,
        device: DeviceIdentity,
        notes: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.referenceUptimeSeconds = referenceUptimeSeconds
        self.app = app
        self.device = device
        self.notes = notes
    }

    /// Builds a header for a session about to start.
    public init(
        sessionID: UUID = UUID(),
        clock: SessionClock,
        app: AppIdentity,
        device: DeviceIdentity,
        notes: String? = nil
    ) {
        self.init(
            formatVersion: .current,
            sessionID: sessionID,
            startedAt: clock.wallClockStart,
            referenceUptimeSeconds: clock.referenceUptimeSeconds,
            app: app,
            device: device,
            notes: notes
        )
    }
}
